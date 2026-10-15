#if DEBUG
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Debug frame source: pushes a moving pattern through the same encoder and loopback link as the
/// broadcast extension, so the pipeline can be checked in the Simulator, where ReplayKit does not run.
final class TestPatternSource {
    private static let width = 1280
    private static let height = 720
    private static let frameRate = 30

    private let queue = DispatchQueue(label: "weappico.cariptv.testpattern")
    private var streamer: ScreenStreamer?
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0

    func start() {
        queue.async { [self] in
            guard streamer == nil else { return }
            let streamer = ScreenStreamer(frameRate: Self.frameRate)
            streamer.start { [weak self] failure in
                Log.relay.error("test pattern: link failed \(String(describing: failure))")
                self?.stop()
            }
            self.streamer = streamer
            frameIndex = 0

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1000 / Self.frameRate))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            streamer?.stop()
            streamer = nil
        }
    }

    private func tick() {
        guard let streamer, let pixelBuffer = Self.makeFrame(frameIndex) else { return }
        let pts = CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(Self.frameRate))
        streamer.submit(pixelBuffer, pts: pts, orientation: 1)
        frameIndex += 1
    }

    /// Colour bars with a white block sliding along the bottom: motion makes stalls visible.
    private static func makeFrame(_ index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any]()] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        let w = CGFloat(width)
        let h = CGFloat(height)
        context.setFillColor(CGColor(gray: 0.08, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))

        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0), (1, 0, 1), (1, 0, 0), (0, 0, 1), (0.2, 0.2, 0.2),
        ]
        let barWidth = w / CGFloat(bars.count)
        for (offset, color) in bars.enumerated() {
            context.setFillColor(CGColor(red: color.0, green: color.1, blue: color.2, alpha: 1))
            context.fill(CGRect(x: CGFloat(offset) * barWidth, y: h * 0.3, width: barWidth, height: h * 0.6))
        }

        let blockSize: CGFloat = 120
        let travel = w - blockSize
        let x = CGFloat(index * 10).truncatingRemainder(dividingBy: travel * 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: x < travel ? x : travel * 2 - x, y: h * 0.05, width: blockSize, height: blockSize))
        return buffer
    }
}
#endif
