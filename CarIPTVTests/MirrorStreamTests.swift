import AVFoundation
import CoreVideo
import Foundation
import Testing
@testable import CarIPTV

/// Real H.264 from the ScreenRelay encoder through the live stream our player takes to the car.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct MirrorStreamTests {
    @Test func cutsTheScreenIntoAPlayableLivePlaylist() async throws {
        let stream = MirrorStream()
        let ready = Flag()
        stream.onReady = { ready.set() }
        for frame in try await ScreenFeed.frames(seconds: 3) {
            stream.append(frame.frame, format: frame.format)
        }
        try await settle(stream)
        #expect(ready.isSet)

        let playlist = try #require(stream.playlist(named: "index.m3u8"))
        let durations = Self.durations(in: playlist)
        #expect(durations.count >= 4, "\(playlist)")
        // Every segment fits the one-second target duration; the last keyframe's segment is still open.
        #expect(durations.allSatisfy { $0 > 0.3 && $0 <= 1.0 }, "\(durations)")
        #expect(playlist.contains("#EXT-X-TARGETDURATION:1"))
        #expect(playlist.contains("#EXT-X-MAP:URI=\"init1.mp4\""))
        #expect(playlist.contains("#EXT-X-PROGRAM-DATE-TIME:"))
        #expect(playlist.contains("#EXT-X-START:TIME-OFFSET=-1.5"))
        #expect(!playlist.contains("#EXT-X-PLAYLIST-TYPE"))
        #expect(!playlist.contains("#EXT-X-ENDLIST"))
        #expect(stream.file(named: "init1.mp4")?.isEmpty == false)
        #expect(stream.file(named: "s0.m4s")?.isEmpty == false)
        #expect(stream.file(named: "s999.m4s") == nil)

        stream.finish()
        #expect(stream.playlist(named: "index.m3u8")?.contains("#EXT-X-ENDLIST") == true)

        let url = try await LocalHLSServer.shared.url(for: stream)
        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        try await waitUntil { item.status != .unknown }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        try await waitUntil { item.presentationSize != .zero }
        // The portrait test screen on the 16:9 picture of a car display.
        #expect(item.presentationSize == CGSize(width: 640, height: 360))
    }

    @Test func startsOnAKeyframeOnly() async throws {
        let frames = try await ScreenFeed.frames(seconds: 1)
        let stream = MirrorStream()
        var requests = 0
        stream.onNeedsKeyframe = { requests += 1 }
        for frame in frames.drop(while: \.frame.isKeyframe).prefix(5) {
            stream.append(frame.frame, format: frame.format)
        }
        // Asked once, not on every frame.
        #expect(requests == 1)
        stream.finish()
        #expect(Self.durations(in: stream.playlist(named: "index.m3u8") ?? "").isEmpty)
    }

    @Test func aTurnedPhoneKeepsThePicture() async throws {
        let stream = MirrorStream()
        let upright = try await ScreenFeed.frames(seconds: 1.6)
        for frame in upright {
            stream.append(frame.frame, format: frame.format)
        }
        // ReplayKit reports landscape as `.right` (6) and keeps the pixels in portrait; the car
        // shows pixels as they are, so the encoder turns them, onto the same 16:9 picture.
        let turned = try await ScreenFeed.frames(seconds: 1.6, from: 1.6, orientation: 6)
        let format = try #require(turned.first?.format)
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == 640 && size.height == 360)
        #expect(turned.allSatisfy { $0.frame.orientation == 1 })

        for frame in turned {
            stream.append(frame.frame, format: frame.format)
        }
        try await settle(stream)
        let playlist = try #require(stream.playlist(named: "index.m3u8"))
        // One part: the car's player goes on without a discontinuity.
        #expect(!playlist.contains("#EXT-X-DISCONTINUITY\n"), "\(playlist)")
        #expect(stream.file(named: "init2.mp4") == nil)
    }

    @Test func aNewPictureSizeStartsANewPart() async throws {
        let stream = MirrorStream()
        for frame in try await ScreenFeed.frames(seconds: 1.6, maxLongSide: 480) {
            stream.append(frame.frame, format: frame.format)
        }
        for frame in try await ScreenFeed.frames(seconds: 1.6, from: 1.6) {
            stream.append(frame.frame, format: frame.format)
        }
        try await settle(stream)
        let playlist = try #require(stream.playlist(named: "index.m3u8"))
        #expect(playlist.contains("#EXT-X-DISCONTINUITY\n#EXT-X-MAP:URI=\"init2.mp4\""), "\(playlist)")
        #expect(stream.file(named: "init2.mp4") != nil)
    }

    @Test func keepsOnlyTheLastSeconds() async throws {
        let stream = MirrorStream()
        for frame in try await ScreenFeed.frames(seconds: 1.2, maxLongSide: 480) {
            stream.append(frame.frame, format: frame.format)
        }
        for frame in try await ScreenFeed.frames(seconds: 9, from: 1.2) {
            stream.append(frame.frame, format: frame.format)
        }
        try await settle(stream)
        let playlist = try #require(stream.playlist(named: "index.m3u8"))
        let total = Self.durations(in: playlist).reduce(0, +)
        #expect(total >= MirrorStream.window - 1 && total <= MirrorStream.window + 1, "\(playlist)")
        #expect(!playlist.contains("#EXT-X-MEDIA-SEQUENCE:0\n"))
        // The smaller part slid out, and its discontinuity with it.
        #expect(playlist.contains("#EXT-X-DISCONTINUITY-SEQUENCE:1"), "\(playlist)")
        #expect(!playlist.contains("#EXT-X-DISCONTINUITY\n"))
        #expect(stream.file(named: "init1.mp4") == nil)
    }

    @Test func findsTheBlackBarsAroundAFilm() throws {
        // A 16:9 film on the wider iPhone screen: black bars left and right.
        let film = try #require(Self.picture(width: 780, height: 360, left: 70, right: 70))
        #expect(VideoEncoder.contentRect(of: film) == CGRect(x: 70, y: 0, width: 640, height: 360))
        let full = CGRect(x: 0, y: 0, width: 780, height: 360)
        #expect(VideoEncoder.contentRect(of: try #require(Self.picture(width: 780, height: 360, left: 0, right: 0))) == full)
        // Dark content at one edge is not a bar: cut evenly to the thinner side.
        #expect(VideoEncoder.contentRect(of: try #require(Self.picture(width: 780, height: 360, left: 70, right: 0))) == full)
        #expect(VideoEncoder.contentRect(of: try #require(Self.picture(width: 780, height: 360, left: 70, right: 30)))
            == CGRect(x: 30, y: 0, width: 720, height: 360))
        // An all-dark frame tells nothing.
        #expect(VideoEncoder.contentRect(of: try #require(Self.picture(width: 780, height: 360, left: 390, right: 390))) == nil)
    }

    @Test func aDarkSceneDoesNotShrinkThePicture() throws {
        let encoder = VideoEncoder(maxLongSide: 640, frameRate: 30)
        defer { encoder.invalidate() }
        func show(left: Int, at second: Double) throws {
            let picture = try #require(Self.picture(width: 780, height: 360, left: left, right: left))
            encoder.encode(picture, pts: CMTime(seconds: second, preferredTimescale: 600), orientation: 1)
        }
        try show(left: 70, at: 0)
        #expect(encoder.crop == CGRect(x: 70, y: 0, width: 640, height: 360))
        // Wider bars once: maybe a dark scene, kept as it was; twice: taken.
        try show(left: 150, at: 0.5)
        #expect(encoder.crop == CGRect(x: 70, y: 0, width: 640, height: 360))
        try show(left: 150, at: 1.0)
        #expect(encoder.crop == CGRect(x: 150, y: 0, width: 480, height: 360))
        // All dark: nothing changes.
        try show(left: 390, at: 1.5)
        #expect(encoder.crop == CGRect(x: 150, y: 0, width: 480, height: 360))
        // Content where the bars were is shown at once.
        try show(left: 0, at: 2.0)
        #expect(encoder.crop == nil)
    }

    @Test func theFilmFillsTheCarPicture() throws {
        let encoder = VideoEncoder(maxLongSide: 640, frameRate: 30)
        defer { encoder.invalidate() }
        let film = try #require(Self.picture(width: 780, height: 360, left: 70, right: 70))
        encoder.encode(film, pts: .zero, orientation: 1)
        let canvas = try #require(encoder.onCanvas(film))
        #expect(CVPixelBufferGetWidth(canvas) == 640 && CVPixelBufferGetHeight(canvas) == 360)
        // Grey reaches every edge: neither the film's bars nor new ones above and below.
        CVPixelBufferLockBaseAddress(canvas, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(canvas, .readOnly) }
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(canvas, 0)
        let luma = CVPixelBufferGetBaseAddressOfPlane(canvas, 0)!.assumingMemoryBound(to: UInt8.self)
        for (x, y) in [(2, 180), (637, 180), (320, 2), (320, 357)] {
            #expect(luma[y * rowBytes + x] > 100, "(\(x), \(y)) is \(luma[y * rowBytes + x])")
        }
    }

    /// A grey picture with black columns on the left and on the right.
    private static func picture(width: Int, height: Int, left: Int, right: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            let line = base + row * rowBytes
            memset(line, 0, rowBytes)
            if width - left - right > 0 {
                memset(line + left * 4, 150, (width - left - right) * 4)
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func durations(in playlist: String) -> [Double] {
        playlist.split(separator: "\n")
            .filter { $0.hasPrefix("#EXTINF:") }
            .compactMap { Double($0.dropFirst(8).dropLast()) }
    }
}

/// Encodes a changing 360×640 picture at 30 fps with the extension's encoder.
enum ScreenFeed {
    struct Encoded {
        let frame: MirrorProtocol.Frame
        let format: CMVideoFormatDescription
    }

    static func frames(seconds: Double, from start: Double = 0, orientation: UInt8 = 1, maxLongSide: Int = 640) async throws -> [Encoded] {
        let encoder = VideoEncoder(maxLongSide: maxLongSide, frameRate: 30)
        let collected = Collected()
        encoder.onOutput = { collected.add($0) }
        let count = Int(seconds * 30)
        for index in 0..<count {
            let buffer = try #require(pixelBuffer(shade: UInt8((index * 7) % 255)))
            let pts = CMTime(seconds: start + Double(index) / 30, preferredTimescale: 1_000_000)
            encoder.encode(buffer, pts: pts, orientation: orientation)
            // Real-time mode drops frames that come faster than it encodes.
            try await Task.sleep(for: .milliseconds(10))
        }
        // The real-time encoder may drop a frame: wait until the output stops growing.
        var seen = -1
        while collected.count != seen {
            seen = collected.count
            try await Task.sleep(for: .milliseconds(400))
        }
        encoder.invalidate()

        var format: CMVideoFormatDescription?
        return collected.outputs.compactMap { output in
            if let sets = output.parameterSets {
                format = MirrorRenderer.makeFormatDescription(sets)
            }
            return format.map { Encoded(frame: output.frame, format: $0) }
        }
    }

    private static func pixelBuffer(shade: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 360, 640, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<640 {
            // A moving band, so P-frames carry changes.
            memset(base + row * rowBytes, Int32((Int(shade) + row) % 255), rowBytes)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [VideoEncoder.Output] = []
        var count: Int { lock.withLock { items.count } }
        var outputs: [VideoEncoder.Output] { lock.withLock { items } }
        func add(_ output: VideoEncoder.Output) { lock.withLock { items.append(output) } }
    }
}

/// Writers hand segments over asynchronously: waits until the playlist stops changing.
private func settle(_ stream: MirrorStream) async throws {
    var last: String?
    while true {
        let now = stream.playlist(named: "index.m3u8")
        if now == last { return }
        last = now
        try await Task.sleep(for: .milliseconds(300))
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(20)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out")
            return
        }
        try await Task.sleep(for: .milliseconds(50))
    }
}
