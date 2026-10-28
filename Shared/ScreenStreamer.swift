import CoreMedia
import CoreVideo
import Foundation
import QuartzCore

/// Encoder + loopback link: takes raw frames, delivers H.264 to the app.
/// Used by the broadcast extension and by the debug test pattern in the app.
final class ScreenStreamer {
    private let client = RelayClient()
    private let encoder: VideoEncoder
    private let minFrameInterval: Double
    /// Guards the encoder: frames come from the caller, repeats from `idleTimer`.
    private let lock = NSLock()
    private var lastFrameSeconds = -Double.infinity
    /// Timestamp and host time of the last encoded frame, for repeats.
    private var lastPTS = CMTime.invalid
    private var lastFrameHostTime = 0.0
    private var idleTimer: DispatchSourceTimer?

    /// A still screen gets its last frame again this often: the car's live stream must keep growing.
    private static let repeatInterval = 0.25

    init(maxLongSide: Int = 1280, frameRate: Int = 30) {
        encoder = VideoEncoder(maxLongSide: maxLongSide, frameRate: frameRate)
        // Small tolerance so 30 fps sources are not cut to 15 by timestamp jitter.
        minFrameInterval = 1.0 / Double(frameRate) - 0.002
    }

    var isReady: Bool { client.isReady }

    func start(onFailure: @escaping (RelayClient.Failure) -> Void) {
        let client = client
        let encoder = encoder
        encoder.onOutput = { output in
            if let sets = output.parameterSets {
                client.send(MirrorProtocol.parameterSetsPacket(sets), droppable: false)
            }
            client.send(
                MirrorProtocol.framePacket(output.frame),
                droppable: !output.frame.isKeyframe,
                onDrop: { encoder.requestKeyframe() }
            )
        }
        client.onKeyframeRequest = { encoder.requestKeyframe() }
        client.onReady = { encoder.requestKeyframe() }
        client.onFailure = onFailure
        client.connect()
        startIdleTimer()
    }

    /// Call from one serial context. Frames above the target frame rate are skipped.
    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime, orientation: UInt8) {
        guard client.isReady else { return }
        let seconds = CMTimeGetSeconds(pts)
        lock.withLock {
            if seconds.isFinite, seconds - lastFrameSeconds < minFrameInterval {
                return
            }
            lastFrameSeconds = seconds
            lastPTS = pts
            lastFrameHostTime = CACurrentMediaTime()
            encoder.encode(pixelBuffer, pts: pts, orientation: orientation)
        }
    }

    func stop() {
        idleTimer?.cancel()
        idleTimer = nil
        client.close(sendingBye: true)
        lock.withLock { encoder.invalidate() }
    }

    /// Repeats the last frame while the screen stands still, timed as if it had just arrived.
    private func startIdleTimer() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "weappico.cariptv.screen.idle"))
        timer.schedule(deadline: .now() + Self.repeatInterval, repeating: Self.repeatInterval)
        timer.setEventHandler { [weak self] in
            self?.repeatIfIdle()
        }
        timer.resume()
        idleTimer = timer
    }

    private func repeatIfIdle() {
        guard client.isReady else { return }
        lock.lock()
        defer { lock.unlock() }
        let now = CACurrentMediaTime()
        let idle = now - lastFrameHostTime
        guard lastPTS.isValid, idle >= Self.repeatInterval else { return }
        let pts = CMTimeAdd(lastPTS, CMTime(seconds: idle, preferredTimescale: 1_000_000))
        lastPTS = pts
        lastFrameSeconds = CMTimeGetSeconds(pts)
        lastFrameHostTime = now
        encoder.repeatLastFrame(pts: pts)
    }
}
