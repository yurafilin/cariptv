// Makes a plain (progressive) MP4 test clip for mockservers.py: 20 s, 1280×720, 30 fps H.264,
// a colour that changes every second plus a moving bar, so a frozen picture is easy to spot.
//
//     swift Tools/MockServers/makevideo.swift Tools/MockServers/media/test.mp4
import AVFoundation
import CoreVideo

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "test.mp4")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

let width = 1280, height = 720, fps: Int32 = 30, seconds = 20
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
writer.shouldOptimizeForNetworkUse = true  // moov first: playable while downloading
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
])
let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let colors: [(UInt8, UInt8, UInt8)] = [(200, 60, 50), (40, 120, 200), (60, 170, 90), (220, 150, 40), (150, 80, 180)]
for frame in 0..<(Int(fps) * seconds) {
    while !input.isReadyForMoreMediaData { usleep(1000) }
    var buffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
    guard let buffer else { fatalError("no pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let (r, g, b) = colors[(frame / Int(fps)) % colors.count]
    let barX = frame * 8 % width
    for y in 0..<height {
        let row = base + y * stride
        for x in 0..<width {
            let isBar = x >= barX && x < barX + 40
            row[x * 4] = isBar ? 255 : b
            row[x * 4 + 1] = isBar ? 255 : g
            row[x * 4 + 2] = isBar ? 255 : r
            row[x * 4 + 3] = 255
        }
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
}
input.markAsFinished()
let done = DispatchSemaphore(value: 0)
writer.finishWriting { done.signal() }
done.wait()
print(writer.status == .completed ? "wrote \(output.path)" : "failed: \(String(describing: writer.error))")
