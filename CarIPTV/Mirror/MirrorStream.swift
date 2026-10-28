import AVFoundation
import CoreMedia
import QuartzCore
import UniformTypeIdentifiers

/// The mirrored iPhone screen as live HLS for our player, and through it for the car: a CarPlay
/// video app gets no window of its own, the car shows only what our player plays.
/// The H.264 frames from ScreenRelay go into half-second fMP4 segments as they are, without
/// re-encoding; the playlist keeps the last few seconds, like live TV. A new picture size (the phone
/// turned: the encoder sends turned frames upright) starts a new writer behind `#EXT-X-DISCONTINUITY`.
/// Frames arrive on the receiver queue; `LocalHLSServer` reads playlists and segments on its own.
final class MirrorStream: HLSSource, @unchecked Sendable {
    let id = UUID()
    /// A writer starts only on a keyframe: the sender should send one now.
    var onNeedsKeyframe: (() -> Void)?
    /// Once, when the playlist holds enough to start playing.
    var onReady: (() -> Void)?

    /// Segments are cut at the keyframes the encoder makes every half second.
    static let segmentInterval = VideoEncoder.keyframeInterval
    static let targetDuration = 1
    /// Seconds kept in the playlist: at least three target durations, as HLS requires of live playlists.
    static let window = 6.0
    static let segmentsToStart = 3
    /// Seconds behind the live edge the player starts (`EXT-X-START`), instead of three target
    /// durations: the car's player reads this from the playlist, not from our player's settings.
    static let startBehindLive = 1.5

    private struct Segment {
        let sequence: Int
        let generation: Int
        let duration: Double
        /// When its first frame was on the iPhone screen: the player reports how far it trails.
        let date: Date?
        let data: Data
    }

    // Receiver queue only.
    private var cutter: Cutter?
    private var keyframeRequested = false

    private let lock = NSLock()
    private var generation = 0
    private var inits: [Int: Data] = [:]
    private var segments: [Segment] = []
    private var nextSequence = 0
    /// `#EXT-X-DISCONTINUITY` tags that slid out of the playlist with their segments.
    private var discontinuitySequence = 0
    private var isFinished = false
    private var isReady = false

    // MARK: - Input (receiver queue)

    func append(_ frame: MirrorProtocol.Frame, format: CMVideoFormatDescription) {
        if frame.isKeyframe {
            keyframeRequested = false
        }
        if let cutter, !cutter.fits(format) {
            cutter.cancel()
            self.cutter = nil
        }
        if cutter == nil {
            guard frame.isKeyframe else {
                requestKeyframe()
                return
            }
            cutter = startCutter(format: format, at: frame.time)
        }
        guard let cutter else { return }

        if cutter.waitingForKeyframe, !frame.isKeyframe {
            requestKeyframe()
            return
        }
        // Writers need rising timestamps.
        guard frame.time > cutter.lastTime,
              let sample = MirrorRenderer.makeSampleBuffer(frame, format: format, displayImmediately: false) else { return }
        guard cutter.input.isReadyForMoreMediaData else {
            // The frames after this one would refer to it: skip to the next keyframe.
            cutter.waitingForKeyframe = true
            requestKeyframe()
            return
        }
        if cutter.input.append(sample) {
            cutter.waitingForKeyframe = false
            cutter.lastTime = frame.time
        } else {
            Log.mirror.error("stream: append failed \(String(describing: cutter.writer.error), privacy: .public)")
            cutter.cancel()
            self.cutter = nil
            requestKeyframe()
        }
    }

    /// The broadcast stopped: the playlist ends, the player stops at its end.
    func finish() {
        cutter?.cancel()
        cutter = nil
        lock.withLock { isFinished = true }
    }

    private func startCutter(format: CMVideoFormatDescription, at time: CMTime) -> Cutter? {
        let generation = lock.withLock { () -> Int in
            generation += 1
            return generation
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        Log.mirror.info("stream: part \(generation) \(size.width)x\(size.height)")
        let cutter = Cutter(generation: generation, format: format, start: time)
        cutter?.stream = self
        if cutter == nil {
            Log.mirror.error("stream: writer did not start")
        }
        return cutter
    }

    private func requestKeyframe() {
        guard !keyframeRequested else { return }
        keyframeRequested = true
        onNeedsKeyframe?()
    }

    // MARK: - Segments (writer callbacks)

    /// `start`: the first frame's timestamp, on the host clock like ReplayKit's.
    fileprivate func add(_ data: Data, type: AVAssetSegmentType, duration: Double?, start: CMTime?, generation: Int) {
        let date = start.map { Date(timeIntervalSinceNow: $0.seconds - CACurrentMediaTime()) }
        let becameReady = lock.withLock { () -> Bool in
            // Writers hand segments over asynchronously: a replaced writer's segments may come
            // after the next part has begun. They still fit until the new part has a segment.
            guard generation >= (segments.last?.generation ?? 0), !isFinished else { return false }
            switch type {
            case .initialization:
                inits[generation] = data
            case .separable:
                segments.append(Segment(sequence: nextSequence, generation: generation,
                                        duration: duration ?? Self.segmentInterval, date: date, data: data))
                nextSequence += 1
                trim()
            @unknown default:
                break
            }
            guard !isReady, segments.count >= Self.segmentsToStart else { return false }
            isReady = true
            return true
        }
        if becameReady {
            onReady?()
        }
    }

    /// Keeps `window` seconds. Under `lock`.
    private func trim() {
        while segments.count > 1, segments.dropFirst().reduce(0, { $0 + $1.duration }) >= Self.window {
            let dropped = segments.removeFirst()
            if let first = segments.first, first.generation != dropped.generation {
                discontinuitySequence += 1
            }
        }
        let oldest = segments.first?.generation ?? generation
        inits = inits.filter { $0.key >= oldest }
    }

    // MARK: - HLSSource

    func playlist(named name: String) -> String? {
        guard name == "index.m3u8" else { return nil }
        let (segments, discontinuities, finished) = lock.withLock { (segments, discontinuitySequence, isFinished) }
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Self.targetDuration)",
            "#EXT-X-MEDIA-SEQUENCE:\(segments.first?.sequence ?? 0)",
            "#EXT-X-DISCONTINUITY-SEQUENCE:\(discontinuities)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            "#EXT-X-START:TIME-OFFSET=-\(Self.startBehindLive)",
        ]
        var generation: Int?
        for segment in segments {
            if segment.generation != generation {
                if generation != nil {
                    lines.append("#EXT-X-DISCONTINUITY")
                }
                lines.append("#EXT-X-MAP:URI=\"init\(segment.generation).mp4\"")
                generation = segment.generation
            }
            if let date = segment.date {
                lines.append("#EXT-X-PROGRAM-DATE-TIME:\(date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: true)))")
            }
            lines.append(String(format: "#EXTINF:%.3f,", segment.duration))
            lines.append("s\(segment.sequence).m4s")
        }
        if finished {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func file(named name: String) -> Data? {
        lock.withLock {
            if name.hasPrefix("init"), name.hasSuffix(".mp4"), let generation = Int(name.dropFirst(4).dropLast(4)) {
                return inits[generation]
            }
            if name.hasPrefix("s"), name.hasSuffix(".m4s"), let sequence = Int(name.dropFirst().dropLast(4)) {
                return segments.first { $0.sequence == sequence }?.data
            }
            return nil
        }
    }
}

/// One writer for one picture format; its segments carry its part number.
private final class Cutter: NSObject, AVAssetWriterDelegate {
    let generation: Int
    let format: CMVideoFormatDescription
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    weak var stream: MirrorStream?
    var waitingForKeyframe = false
    var lastTime = CMTime.negativeInfinity

    init?(generation: Int, format: CMVideoFormatDescription, start: CMTime) {
        self.generation = generation
        self.format = format
        writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: MirrorStream.segmentInterval, preferredTimescale: 1000)
        writer.initialSegmentStartTime = start
        // nil settings: the encoded frames are copied, not decoded.
        input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
        input.expectsMediaDataInRealTime = true
        super.init()
        writer.delegate = self
        guard writer.canAdd(input) else { return nil }
        writer.add(input)
        guard writer.startWriting() else { return nil }
        writer.startSession(atSourceTime: start)
    }

    func fits(_ format: CMVideoFormatDescription) -> Bool {
        CMFormatDescriptionEqual(format, otherFormatDescription: self.format)
    }

    func cancel() {
        if writer.status == .writing {
            writer.cancelWriting()
        }
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        let report = segmentReport?.trackReports.first
        let duration = report?.duration.seconds
        stream?.add(segmentData, type: segmentType,
                    duration: duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil },
                    start: report.map(\.earliestPresentationTimeStamp).flatMap { $0.isNumeric ? $0 : nil },
                    generation: generation)
    }
}

extension MirrorProtocol.Frame {
    var time: CMTime { CMTime(value: ptsMicroseconds, timescale: 1_000_000) }
}
