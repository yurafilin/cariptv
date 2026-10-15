import CoreMedia
import CoreVideo
import Foundation

/// Encoder + loopback link: takes raw frames, delivers H.264 to the app.
/// Used by the broadcast extension and by the debug test pattern in the app.
final class ScreenStreamer {
    private let client = RelayClient()
    private let encoder: VideoEncoder
    private let minFrameInterval: Double
    private var lastFrameSeconds = -Double.infinity

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
    }

    /// Call from one serial context. Frames above the target frame rate are skipped.
    func submit(_ pixelBuffer: CVPixelBuffer, pts: CMTime, orientation: UInt8) {
        guard client.isReady else { return }
        let seconds = CMTimeGetSeconds(pts)
        if seconds.isFinite, seconds - lastFrameSeconds < minFrameInterval {
            return
        }
        lastFrameSeconds = seconds
        encoder.encode(pixelBuffer, pts: pts, orientation: orientation)
    }

    func stop() {
        client.close(sendingBye: true)
        encoder.invalidate()
    }
}
