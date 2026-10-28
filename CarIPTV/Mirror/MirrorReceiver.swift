import CoreGraphics
import Foundation
import ImageIO
import Network

/// App side of the loopback link: accepts the ScreenRelay extension, feeds `renderer` (the phone's
/// preview, a CarPlay window if the car gives one) and `MirrorStream` (live HLS that our player
/// takes to the car). All networking runs on `queue`; status goes to `MirrorStatus` on the main actor.
final class MirrorReceiver {
    static let shared = MirrorReceiver()

    let renderer = MirrorRenderer()

    private let queue = DispatchQueue(label: "weappico.cariptv.mirror.receiver")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var parser = MirrorPacketParser()
    private var fpsTimer: DispatchSourceTimer?
    private var framesThisSecond = 0
    private var lastOrientation: UInt8 = 0
    private var retryScheduled = false
    private var stream: MirrorStream?

    private init() {
        renderer.onNeedsKeyframe = { [weak self] in
            self?.requestKeyframe()
        }
    }

    /// Idempotent. Call on launch, on foreground and on CarPlay connect: the system tears
    /// the listener down while the app is suspended.
    func start() {
        queue.async { [self] in startListener() }
    }

    func requestKeyframe() {
        queue.async { [self] in
            connection?.send(content: MirrorProtocol.packet(.keyframeRequest), completion: .idempotent)
        }
    }

    // MARK: - Listener

    private func startListener() {
        guard listener == nil else { return }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        // Bound to 127.0.0.1 itself, so nothing off the device can connect. Filtering with
        // `requiredInterfaceType = .loopback` instead makes the listener reset every incoming
        // connection in the Simulator (checked 2026-10-15, Xcode 26.3, iOS 26.3).
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(MirrorProtocol.host),
            port: NWEndpoint.Port(rawValue: MirrorProtocol.port)!
        )
        parameters.allowLocalEndpointReuse = true
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListener(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            Log.mirror.error("receiver: listener create failed \(error.localizedDescription)")
            retryLater()
        }
    }

    private func handleListener(_ state: NWListener.State) {
        switch state {
        case .ready:
            Log.mirror.info("receiver: listening on \(MirrorProtocol.port)")
            if connection == nil {
                MirrorStatus.publish { $0.set(state: .listening) }
            }
        case .failed(let error):
            Log.mirror.error("receiver: listener failed \(error.localizedDescription)")
            listener?.cancel()
            listener = nil
            if connection == nil {
                MirrorStatus.publish { $0.set(state: .stopped) }
            }
            retryLater()
        default:
            break
        }
    }

    private func retryLater() {
        guard !retryScheduled else { return }
        retryScheduled = true
        queue.asyncAfter(deadline: .now() + 1) { [self] in
            retryScheduled = false
            startListener()
        }
    }

    // MARK: - Connection

    private func accept(_ newConnection: NWConnection) {
        // One sender at a time: a new broadcast replaces the previous one.
        if let connection {
            Log.mirror.info("receiver: replacing sender")
            connection.cancel()
        }
        connection = newConnection
        parser = MirrorPacketParser()
        lastOrientation = 0
        renderer.reset()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                Log.mirror.info("receiver: sender connected")
                receive(on: newConnection)
            case .failed(let error):
                Log.mirror.error("receiver: sender failed \(error.localizedDescription)")
                ended(newConnection)
            case .cancelled:
                ended(newConnection)
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] content, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            if let content, !content.isEmpty {
                guard let packets = parser.append(content) else {
                    Log.mirror.error("receiver: corrupt stream, dropping sender")
                    connection.cancel()
                    return
                }
                for (type, payload) in packets {
                    handle(type, payload)
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive(on: connection)
        }
    }

    private func handle(_ type: MirrorProtocol.MessageType, _ payload: Data) {
        switch type {
        case .hello:
            let version = payload.first ?? 0
            Log.mirror.info("receiver: hello v\(version)")
            startStream()
            startFPSTimer()
            MirrorStatus.publish { $0.set(state: .streaming) }
        case .parameterSets:
            guard let sets = MirrorProtocol.parseParameterSets(payload),
                  let dimensions = renderer.setParameterSets(sets) else {
                Log.mirror.error("receiver: bad parameter sets")
                return
            }
            let size = CGSize(width: Int(dimensions.width), height: Int(dimensions.height))
            MirrorStatus.publish { $0.set(videoSize: size) }
        case .frame:
            guard let frame = MirrorProtocol.parseFrame(payload) else { return }
            renderer.render(frame)
            if let format = renderer.format {
                stream?.append(frame, format: format)
            }
            framesThisSecond += 1
            if frame.orientation != lastOrientation {
                lastOrientation = frame.orientation
                let orientation = CGImagePropertyOrientation(rawValue: UInt32(frame.orientation)) ?? .up
                MirrorStatus.publish { $0.set(orientation: orientation) }
            }
        case .bye:
            Log.mirror.info("receiver: sender stopped")
            connection?.cancel()
        case .keyframeRequest:
            break
        }
    }

    private func ended(_ endedConnection: NWConnection) {
        guard endedConnection === connection else { return }
        connection = nil
        stopFPSTimer()
        endStream()
        renderer.reset()
        let state: MirrorStatus.State = listener == nil ? .stopped : .listening
        MirrorStatus.publish {
            $0.set(state: state)
            $0.set(framesPerSecond: 0)
        }
    }

    // MARK: - Stream for the car

    private func startStream() {
        endStream()
        let stream = MirrorStream()
        stream.onNeedsKeyframe = { [weak self] in
            self?.requestKeyframe()
        }
        stream.onReady = { [weak stream] in
            guard let stream else { return }
            Task { @MainActor in ScreenPlayback.ready(stream) }
        }
        self.stream = stream
    }

    private func endStream() {
        guard let stream else { return }
        stream.finish()
        self.stream = nil
        Task { @MainActor in ScreenPlayback.ended(stream) }
    }

    // MARK: - FPS

    private func startFPSTimer() {
        stopFPSTimer()
        framesThisSecond = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let fps = framesThisSecond
            framesThisSecond = 0
            MirrorStatus.publish { $0.set(framesPerSecond: fps) }
        }
        timer.resume()
        fpsTimer = timer
    }

    private func stopFPSTimer() {
        fpsTimer?.cancel()
        fpsTimer = nil
    }
}
