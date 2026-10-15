import Foundation
import Network

/// Sender side of the loopback link: connects to the app's `MirrorReceiver`.
final class RelayClient {
    enum Failure: Error {
        /// Nothing listens on the port: the app is not running.
        case appUnavailable
        /// The link dropped after it was up.
        case disconnected
    }

    /// Called on the client queue.
    var onReady: (() -> Void)?
    var onFailure: ((Failure) -> Void)?
    var onKeyframeRequest: (() -> Void)?

    private static let maxPendingFrames = 3

    private let queue = DispatchQueue(label: "weappico.cariptv.relay.client")
    private var connection: NWConnection?
    private var parser = MirrorPacketParser()
    private var pendingSends = 0
    private var didReportFailure = false

    private let readyLock = NSLock()
    private var ready = false

    var isReady: Bool {
        readyLock.withLock { ready }
    }

    func connect() {
        queue.async { [self] in
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let parameters = NWParameters(tls: nil, tcp: tcp)
            let connection = NWConnection(
                host: NWEndpoint.Host(MirrorProtocol.host),
                port: NWEndpoint.Port(rawValue: MirrorProtocol.port)!,
                using: parameters
            )
            connection.stateUpdateHandler = { [weak self] state in
                self?.handle(state)
            }
            self.connection = connection
            connection.start(queue: queue)
        }
    }

    /// Droppable packets are skipped while the receiver lags; returns via `onDrop`
    /// so the caller can ask the encoder for a fresh keyframe.
    func send(_ packet: Data, droppable: Bool, onDrop: (() -> Void)? = nil) {
        queue.async { [self] in
            guard let connection, isReady else { return }
            if droppable, pendingSends >= Self.maxPendingFrames {
                onDrop?()
                return
            }
            pendingSends += 1
            connection.send(content: packet, completion: .contentProcessed { [weak self] _ in
                self?.pendingSends -= 1
            })
        }
    }

    func close(sendingBye: Bool) {
        queue.async { [self] in
            guard let connection else { return }
            setReady(false)
            didReportFailure = true
            if sendingBye {
                connection.send(content: MirrorProtocol.packet(.bye), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            } else {
                connection.cancel()
            }
            self.connection = nil
        }
    }

    // MARK: - Private

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            Log.relay.info("client: connected")
            setReady(true)
            connection?.send(content: MirrorProtocol.helloPacket(), completion: .idempotent)
            receive()
            onReady?()
        case .waiting(let error):
            // Loopback with no listener ends up here (connection refused): the app is not running.
            Log.relay.error("client: waiting \(error.localizedDescription)")
            fail(isReady ? .disconnected : .appUnavailable)
        case .failed(let error):
            Log.relay.error("client: failed \(error.localizedDescription)")
            fail(isReady ? .disconnected : .appUnavailable)
        case .cancelled:
            setReady(false)
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            if let content, !content.isEmpty {
                for (type, _) in parser.append(content) ?? [] where type == .keyframeRequest {
                    onKeyframeRequest?()
                }
            }
            if isComplete || error != nil {
                fail(.disconnected)
                return
            }
            receive()
        }
    }

    private func fail(_ failure: Failure) {
        setReady(false)
        connection?.cancel()
        connection = nil
        guard !didReportFailure else { return }
        didReportFailure = true
        onFailure?(failure)
    }

    private func setReady(_ value: Bool) {
        readyLock.withLock { ready = value }
    }
}
