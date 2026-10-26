import AVFoundation
import Foundation
import Testing
@testable import CarIPTV

struct HLSPackagerRulesTests {
    @Test func plainFilesArePackaged() {
        #expect(HLSPackager.needsPackaging(URL(string: "http://x/movie/1/2/101.mp4")!, isLive: false))
        #expect(HLSPackager.needsPackaging(URL(fileURLWithPath: "/tmp/clip.MOV"), isLive: false))
        // M3U channels count as live, but an .mp4 address is still a file.
        #expect(HLSPackager.needsPackaging(URL(string: "http://x/media/test.mp4")!, isLive: true))
        #expect(HLSPackager.needsPackaging(URL(string: "https://rr1.googlevideo.com/videoplayback?itag=18&mime=video%2Fmp4")!, isLive: false))
    }

    @Test func streamsAndUnreadableContainersAreNot() {
        #expect(!HLSPackager.needsPackaging(URL(string: "http://x/live/1/2/1.m3u8")!, isLive: true))
        #expect(!HLSPackager.needsPackaging(URL(string: "http://x/Videos/1/master.m3u8")!, isLive: false))
        #expect(!HLSPackager.needsPackaging(URL(string: "http://x/movie/1/2/102.mkv")!, isLive: false))
        #expect(!HLSPackager.needsPackaging(URL(string: "http://x/live/1/2/7.ts")!, isLive: true))
        #expect(!HLSPackager.needsPackaging(URL(string: "http://x/stream")!, isLive: true))
    }
}

/// A real clip through the real packager and server, then AVFoundation reads the result.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct HLSPackagerTests {
    @Test func packagesAFileIntoPlayableHLS() async throws {
        let clip = try await TestClip.make(seconds: 10)
        defer { try? FileManager.default.removeItem(at: clip) }

        let packager = HLSPackager(source: clip)
        defer { packager.cancel() }
        try await packager.start()
        #expect(packager.segmentCount >= 1)
        try await waitUntil { packager.isComplete }

        let master = try #require(packager.playlist(named: "index.m3u8"))
        #expect(master.contains("#EXT-X-MEDIA:TYPE=AUDIO"))
        #expect(master.contains("video.m3u8"))
        let video = try #require(packager.playlist(named: "video.m3u8"))
        #expect(video.contains("#EXT-X-PLAYLIST-TYPE:VOD"))
        #expect(video.contains("#EXT-X-ENDLIST"))
        #expect(video.contains("#EXT-X-MAP:URI=\"vinit.mp4\""))
        #expect(packager.playlist(named: "audio.m3u8")?.contains("#EXT-X-ENDLIST") == true)
        #expect(packager.segmentCount >= 2)
        #expect(abs(packager.totalDuration - 10) < 1)
        for name in ["vinit.mp4", "v0.m4s", "ainit.mp4", "a0.m4s"] {
            #expect(packager.file(named: name)?.isEmpty == false, "\(name)")
        }
        #expect(packager.file(named: "v999.m4s") == nil)

        let url = try await LocalHLSServer.shared.url(for: packager)
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == master)

        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 10) < 1)

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        try await waitUntil { item.status != .unknown }
        #expect(item.status == .readyToPlay, "\(String(describing: item.error))")
        _ = player
    }

    /// A web file with its index at the start plays before it has fully arrived.
    @Test func startsBeforeTheDownloadEnds() async throws {
        let clip = try await TestClip.make(seconds: 30)
        defer { try? FileManager.default.removeItem(at: clip) }
        let data = try Data(contentsOf: clip)
        let growing = FileManager.default.temporaryDirectory.appendingPathComponent("growing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: growing) }
        let file = try SourceFile(growing: growing, expectedLength: Int64(data.count))
        let cut = data.count * 7 / 10
        try file.append(data.prefix(cut))

        let packager = HLSPackager(file: file)
        defer { packager.cancel() }
        try await packager.start()
        #expect(!packager.isComplete)
        #expect(packager.segmentCount >= 1)
        #expect(packager.totalDuration < 25)

        try file.append(data.suffix(from: cut))
        file.finish()
        try await waitUntil { packager.isComplete }
        #expect(abs(packager.totalDuration - 30) < 1)

        // Passes join without gaps: the result plays as one 30 s video.
        let url = try await LocalHLSServer.shared.url(for: packager)
        let duration = try await AVURLAsset(url: url).load(.duration).seconds
        #expect(abs(duration - 30) < 1)
    }

    /// With the index at the end nothing can be read before the last byte.
    @Test func waitsForIndexAtTheEnd() async throws {
        let clip = try await TestClip.make(seconds: 10, fastStart: false)
        defer { try? FileManager.default.removeItem(at: clip) }
        let data = try Data(contentsOf: clip)
        let growing = FileManager.default.temporaryDirectory.appendingPathComponent("growing-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: growing) }
        let file = try SourceFile(growing: growing, expectedLength: Int64(data.count))
        let cut = data.count * 7 / 10
        try file.append(data.prefix(cut))

        let packager = HLSPackager(file: file)
        defer { packager.cancel() }
        let started = Task { try await packager.start() }
        try await Task.sleep(for: .seconds(1))
        #expect(packager.segmentCount == 0)

        try file.append(data.suffix(from: cut))
        file.finish()
        try await started.value
        try await waitUntil { packager.isComplete }
        #expect(abs(packager.totalDuration - 10) < 1)
    }

    @Test func fileWithoutVideoIsRefused() async throws {
        let clip = try await TestClip.make(seconds: 2, video: false)
        defer { try? FileManager.default.removeItem(at: clip) }
        await #expect(throws: HLSPackager.PackagerError.self) {
            try await HLSPackager(source: clip).start()
        }
    }

    @Test func cancelRemovesTheSegments() async throws {
        let clip = try await TestClip.make(seconds: 4)
        defer { try? FileManager.default.removeItem(at: clip) }
        let packager = HLSPackager(source: clip)
        try await packager.start()
        packager.cancel()
        try await waitUntil { !FileManager.default.fileExists(atPath: packager.directory.path) }
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
}

/// A short MP4 like one recorded on a phone: H.264 video with a key frame every second, AAC audio.
enum TestClip {
    /// `fastStart`: the index (`moov`) at the start, as web files have it; otherwise at the end.
    static func make(seconds: Int, video: Bool = true, fastStart: Bool = true) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clip-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = fastStart
        let fps: Int32 = 30
        let width = 320, height = 180

        var videoInput: AVAssetWriterInput?
        var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        if video {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: Int(fps)],
            ])
            input.expectsMediaDataInRealTime = false
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
            videoInput = input
        }
        let sampleRate = 44_100.0
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        audioInput.expectsMediaDataInRealTime = false
        writer.add(audioInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Silence, in buffers of a tenth of a second.
        var format: CMAudioFormatDescription?
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                                       magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        let chunk = Int(sampleRate) / 10
        func silence(at index: Int) throws -> CMSampleBuffer {
            var block: CMBlockBuffer?
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: chunk * 2, blockAllocator: nil,
                                               customBlockSource: nil, offsetToData: 0, dataLength: chunk * 2, flags: 0, blockBufferOut: &block)
            CMBlockBufferFillDataBytes(with: 0, blockBuffer: block!, offsetIntoDestination: 0, dataLength: chunk * 2)
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: chunk,
                presentationTimeStamp: CMTime(value: CMTimeValue(index * chunk), timescale: CMTimeScale(sampleRate)),
                packetDescriptions: nil, sampleBufferOut: &sample
            )
            return try #require(sample)
        }

        // The writer interleaves tracks and stops taking one that runs ahead: always feed the one behind.
        let totalFrames = video ? Int(fps) * seconds : 0
        let totalChunks = seconds * 10
        var frame = 0
        var tenth = 0
        while frame < totalFrames || tenth < totalChunks {
            if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            let videoTime = Double(frame) / Double(fps)
            let audioTime = Double(tenth) / 10
            if let videoInput, let adaptor, frame < totalFrames, videoTime <= audioTime || tenth == totalChunks,
               videoInput.isReadyForMoreMediaData {
                var buffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
                let pixels = try #require(buffer)
                CVPixelBufferLockBaseAddress(pixels, [])
                memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 7 % 255), CVPixelBufferGetDataSize(pixels))
                CVPixelBufferUnlockBaseAddress(pixels, [])
                adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
                frame += 1
                if frame == totalFrames { videoInput.markAsFinished() }
            } else if tenth < totalChunks, audioInput.isReadyForMoreMediaData {
                audioInput.append(try silence(at: tenth))
                tenth += 1
                // A track still open keeps the writer waiting for more of it before taking the other.
                if tenth == totalChunks { audioInput.markAsFinished() }
            } else {
                try await Task.sleep(for: .milliseconds(2))
            }
        }

        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }
}
