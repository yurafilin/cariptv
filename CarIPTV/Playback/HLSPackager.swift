import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Repackages a plain video file — local, or on the web (MP4, MOV, M4V; YouTube's files) — into HLS
/// on the phone, because CarPlay shows only HLS from our player (`-11870` for anything else).
///
/// Nothing is re-encoded: `AVAssetReader` hands over the compressed samples and `AVAssetWriter`
/// (profile `mpeg4AppleHLS`) cuts them into fMP4 segments. A writer cannot pass video and audio
/// through together while segmenting (-11875), so each track gets its own writer and the master
/// playlist joins them (video + an audio rendition), as streaming services do. Segments go to a
/// temporary folder and are served by `LocalHLSServer` while the rest is still being cut, as EVENT
/// playlists that become complete (`#EXT-X-ENDLIST`) at the end.
///
/// `AVAssetReader` reads only local files, so a web file is downloaded (`SourceFile`) and cut while
/// it arrives: each pass reads up to a key frame safely behind the downloaded part, the next pass
/// resumes from that key frame. A file whose index (`moov`) is at the end can only start once it
/// is all here.
final class HLSPackager: @unchecked Sendable {
    enum PackagerError: LocalizedError {
        case noVideo
        case cannotRead(String)
        case downloadFailed

        var errorDescription: String? {
            switch self {
            case .noVideo: String(localized: "This file has no video.")
            case .cannotRead(let reason): reason
            case .downloadFailed: String(localized: "The video could not be downloaded.")
            }
        }

        static let unreadable = PackagerError.cannotRead(String(localized: "This video can't be read."))
        static let unwritable = PackagerError.cannotRead(String(localized: "This video can't be prepared for the car display."))
    }

    let id = UUID()
    let directory: URL

    private let source: URL?
    private let options: [String: Any]?
    private let lock = NSLock()
    // Guarded by `lock`.
    private var file: SourceFile?
    private var renditions: [Rendition] = []
    private var tasks: [Task<Void, Never>] = []
    private var bandwidth = 5_000_000
    private var failure: Error?
    private var isCancelled = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    /// Download progress of a web file, 0…1, from any thread.
    var onProgress: (@Sendable (Double) -> Void)?

    /// Segment length asked of the writer; video segments end at the next key frame after it.
    static let segmentInterval = 4.0

    init(source: URL, options: [String: Any]? = nil) {
        self.source = source
        self.options = options
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-\(id.uuidString)", isDirectory: true)
    }

    /// Packages a file someone else fills (tests feed it piece by piece).
    init(file: SourceFile) {
        source = nil
        options = nil
        self.file = file
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hls-\(id.uuidString)", isDirectory: true)
    }

    /// Plain files go through the packager; HLS, live streams and containers AVFoundation cannot read
    /// (MKV, TS, WebM) are played as they are.
    static func needsPackaging(_ url: URL, isLive: Bool) -> Bool {
        let fileTypes: Set = ["mp4", "m4v", "mov"]
        let unreadable: Set = ["m3u8", "m3u", "mkv", "avi", "ts", "webm", "flv", "mpd"]
        let ext = url.pathExtension.lowercased()
        if fileTypes.contains(ext) { return true }
        if unreadable.contains(ext) || isLive { return false }
        // Web files without an extension (googlevideo.com/videoplayback?…&mime=video/mp4).
        return url.scheme?.hasPrefix("http") == true
    }

    // MARK: - Running

    /// Starts cutting and returns once every track has its first segment (or is done, if shorter).
    func start() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = try lock.withLock { () -> SourceFile in
            if let file { return file }
            let made = try makeSource()
            file = made
            return made
        }
        file.onProgress = { [weak self] fraction in self?.onProgress?(fraction) }

        let asset = try await openAsset(file)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { throw PackagerError.noVideo }
        var made = [try await Rendition(kind: .video, track: video, directory: directory)]
        if let audio = tracks.first(where: { $0.mediaType == .audio }) {
            made.append(try await Rendition(kind: .audio, track: audio, directory: directory))
        }
        let duration = try await asset.load(.duration).seconds
        let expected = file.isComplete ? (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) : nil
        let bytes = expected ?? Int64(Double(file.receivedBytes) / max(file.fraction, 0.01))
        let estimate = duration > 0 && bytes > 0 ? Int(Double(bytes) * 8 / duration * 1.2) : 5_000_000

        let tasks = made.map { rendition in
            rendition.onChange = { [weak self] in self?.resumeWaitersIfReady() }
            return Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    try await self?.cut(rendition, from: file, duration: duration)
                    Log.playback.info("hls: \(rendition.kind.rawValue, privacy: .public) done, \(rendition.segmentCount) segments")
                    self?.resumeWaitersIfReady()
                } catch {
                    self?.finish(with: error)
                }
            }
        }
        lock.withLock {
            renditions = made
            bandwidth = estimate
            self.tasks = tasks
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            defer { lock.unlock() }
            if let failure {
                continuation.resume(throwing: failure)
            } else if renditions.allSatisfy(\.hasStarted) {
                continuation.resume()
            } else {
                waiters.append(continuation)
            }
        }
    }

    func cancel() {
        let (file, tasks) = lock.withLock { () -> (SourceFile?, [Task<Void, Never>]) in
            isCancelled = true
            return (self.file, self.tasks)
        }
        file?.cancel()
        tasks.forEach { $0.cancel() }
        finish(with: CancellationError())
        LocalHLSServer.shared.remove(self)
        // The writers stop at their next sample; give them a moment before the folder goes.
        let directory = directory
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var wasCancelled: Bool { lock.withLock { isCancelled } }

    /// A local file as it is; a web file downloads into the packager's folder with the page's
    /// user agent and cookies.
    private func makeSource() throws -> SourceFile {
        guard let source else { throw PackagerError.unreadable }
        if source.isFileURL { return SourceFile(local: source) }
        var request = URLRequest(url: source, timeoutInterval: 60)
        if let agent = options?[AVURLAssetHTTPUserAgentKey] as? String {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let cookies = options?[AVURLAssetHTTPCookiesKey] as? [HTTPCookie] {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        // The extension tells AVFoundation the container; web files without one are MP4.
        let ext = ["mov", "m4v"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "mp4"
        return try SourceFile.download(request, to: directory.appendingPathComponent("source.\(ext)"))
    }

    /// The asset once its index has arrived: at the start of most web files, at the end of some.
    private func openAsset(_ file: SourceFile) async throws -> AVURLAsset {
        var triedAt: Int64?
        while true {
            if wasCancelled { throw CancellationError() }
            if let error = file.error { throw error }
            let complete = file.isComplete
            let received = file.receivedBytes
            // Try at once, then again only after a useful amount of new data.
            if complete || triedAt.map({ received - $0 >= 128 * 1024 }) ?? (received > 0) {
                triedAt = received
                let asset = AVURLAsset(url: file.url)
                if (try? await asset.load(.tracks).isEmpty) == false, (try? await asset.load(.duration).seconds).map({ $0 > 0 }) == true {
                    return asset
                }
                if complete {
                    throw PackagerError.unreadable
                }
            }
            await file.waitForChange()
        }
    }

    /// How far behind the download edge a pass stops: the last bytes may be a half-written sample.
    private static func margin(for duration: Double) -> Double {
        max(6, duration * 0.03)
    }

    /// Copies one track into its segmented writer. The writer pulls samples on the track's own
    /// queue (`requestMediaDataWhenReady`); pushing them from a task made it fail mid-segment (-11876).
    private func cut(_ rendition: Rendition, from file: SourceFile, duration: Double) async throws {
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentInterval, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = rendition
        // nil settings: compressed samples are copied, not decoded.
        let input = AVAssetWriterInput(mediaType: rendition.kind.mediaType, outputSettings: nil, sourceFormatHint: rendition.format)
        input.expectsMediaDataInRealTime = false
        input.transform = rendition.transform
        guard writer.canAdd(input) else { throw PackagerError.unwritable }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PackagerError.unwritable }
        writer.startSession(atSourceTime: .zero)

        let feeder = SampleFeeder(trackID: rendition.trackID, file: file, duration: duration,
                                  margin: Self.margin(for: duration)) { [weak self] in self?.wasCancelled ?? true }
        let queue = DispatchQueue(label: "weappico.cariptv.hls.\(rendition.kind.rawValue)")
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                input.requestMediaDataWhenReady(on: queue) {
                    while input.isReadyForMoreMediaData {
                        switch feeder.next() {
                        case .sample(let sample):
                            if !input.append(sample) {
                                input.markAsFinished()
                                feeder.stop()
                                continuation.resume(throwing: writer.error ?? PackagerError.unwritable)
                                return
                            }
                        case .end:
                            input.markAsFinished()
                            continuation.resume()
                            return
                        case .failure(let error):
                            input.markAsFinished()
                            continuation.resume(throwing: error)
                            return
                        }
                    }
                }
            }
        } catch {
            writer.cancelWriting()
            throw error
        }
        await writer.finishWriting()
        if writer.status == .failed { throw writer.error ?? PackagerError.unwritable }
        rendition.markFinished()
    }

    private func finish(with error: Error) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            if failure == nil { failure = error }
            defer { waiters = [] }
            return waiters
        }
        if !(error is CancellationError) {
            Log.playback.error("hls: \(String(describing: error), privacy: .public)")
        }
        pending.forEach { $0.resume(throwing: error) }
    }

    private func resumeWaitersIfReady() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard failure == nil, !renditions.isEmpty, renditions.allSatisfy(\.hasStarted) else { return [] }
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    // MARK: - Serving

    private var video: Rendition? { lock.withLock { renditions.first } }

    var segmentCount: Int { video?.segmentCount ?? 0 }
    var totalDuration: Double { video?.totalDuration ?? 0 }
    /// Why packaging stopped, unless it was cancelled.
    var error: Error? {
        lock.withLock { failure is CancellationError ? nil : failure }
    }

    /// Every track is cut to the end.
    var isComplete: Bool { lock.withLock { !renditions.isEmpty && renditions.allSatisfy(\.isFinished) } }

    /// `index.m3u8` joins the video and audio playlists; without audio it is the video playlist itself.
    func playlist(named name: String) -> String? {
        let (renditions, bandwidth) = lock.withLock { (renditions, bandwidth) }
        if name == "index.m3u8" {
            guard renditions.count > 1 else { return renditions.first?.playlist() }
            return [
                "#EXTM3U",
                "#EXT-X-VERSION:7",
                "#EXT-X-INDEPENDENT-SEGMENTS",
                "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"audio.m3u8\"",
                "#EXT-X-STREAM-INF:BANDWIDTH=\(bandwidth),AUDIO=\"audio\"",
                "video.m3u8",
                "",
            ].joined(separator: "\n")
        }
        return renditions.first { $0.playlistName == name }?.playlist()
    }

    /// An init or media segment, once written.
    func file(named name: String) -> Data? {
        let renditions = lock.withLock { renditions }
        return renditions.lazy.compactMap { $0.file(named: name) }.first
    }
}

/// Hands one track's samples to its writer, pass by pass as the file arrives. Runs on the track's
/// queue and blocks it while waiting for more of the download.
///
/// Each pass reads up to a key frame safely behind the downloaded part (the last bytes may be a
/// half-written sample); the next pass resumes from that key frame. A pass that runs into missing
/// bytes resumes from the last key frame it wrote and skips the samples already written after it.
/// Skipping goes by position in decode order, not by timestamps: B-frames may carry no decode time.
private final class SampleFeeder: @unchecked Sendable {
    enum Outcome {
        case sample(CMSampleBuffer)
        case end
        case failure(Error)
    }

    private let trackID: CMPersistentTrackID
    private let file: SourceFile
    private let duration: Double
    private let margin: Double
    private let isCancelled: () -> Bool

    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var passIsFinal = false
    private var edge = Double.infinity
    private var start = CMTime.zero
    /// The key frame the next pass picks up at, and how many samples from it on are already written.
    private var resumeAt: CMTime?
    private var resumeSkip = 0
    private var pendingSkip = 0
    private var lastKeyFrame: CMTime?
    /// Samples written from the last key frame on, including it.
    private var sinceKeyFrame = 0

    init(trackID: CMPersistentTrackID, file: SourceFile, duration: Double, margin: Double, isCancelled: @escaping () -> Bool) {
        self.trackID = trackID
        self.file = file
        self.duration = duration
        self.margin = margin
        self.isCancelled = isCancelled
    }

    func stop() {
        reader?.cancelReading()
        reader = nil
        output = nil
    }

    func next() -> Outcome {
        while true {
            if isCancelled() {
                stop()
                return .failure(CancellationError())
            }
            if let error = file.error {
                stop()
                return .failure(error)
            }
            guard let output else {
                switch openPass() {
                case .ready: continue
                case .wait: waitForMore()
                case .failed(let error): return .failure(error)
                }
                continue
            }
            guard let sample = output.copyNextSampleBuffer() else {
                let status = reader?.status
                stop()
                if passIsFinal {
                    if status == .completed { return .end }
                    return .failure(reader?.error ?? HLSPackager.PackagerError.unreadable)
                }
                // Ran into bytes not here yet: resume from the last key frame once more arrives.
                // Nothing written yet: simply start over.
                if let lastKeyFrame {
                    resume(at: lastKeyFrame, skipping: sinceKeyFrame)
                }
                waitForMore()
                continue
            }
            let presentation = sample.presentationTimeStamp
            let isKeyFrame = sample.isSyncSample
            if let target = resumeAt {
                // A pass reads from a second early: wait for the key frame it resumes at.
                guard isKeyFrame, presentation == target else { continue }
                resumeAt = nil
                pendingSkip = resumeSkip
            }
            if !passIsFinal, isKeyFrame, presentation.seconds > edge, pendingSkip == 0 {
                // The next pass starts exactly at this key frame.
                resume(at: presentation, skipping: 0)
                stop()
                continue
            }
            if pendingSkip > 0 {
                pendingSkip -= 1
                continue
            }
            if isKeyFrame {
                lastKeyFrame = presentation
                sinceKeyFrame = 1
            } else {
                sinceKeyFrame += 1
            }
            return .sample(sample)
        }
    }

    private func resume(at keyFrame: CMTime, skipping count: Int) {
        start = keyFrame
        resumeAt = keyFrame
        resumeSkip = count
    }

    private enum Pass {
        case ready
        case wait
        case failed(Error)
    }

    private func openPass() -> Pass {
        let complete = file.isComplete
        edge = complete ? .infinity : file.fraction * duration - margin
        if !complete, edge < start.seconds + HLSPackager.segmentInterval * 2 { return .wait }
        let asset = AVURLAsset(url: file.url)
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var track: AVAssetTrack?
        Task {
            track = try? await asset.loadTrack(withTrackID: trackID)
            semaphore.signal()
        }
        semaphore.wait()
        guard let track else { return complete ? .failed(HLSPackager.PackagerError.unreadable) : .wait }
        do {
            let reader = try AVAssetReader(asset: asset)
            // A range starting right at a key frame can drop that frame (it did at 0): read from a
            // second earlier and let the decode-time check skip what is already written.
            if start > .zero {
                let from = CMTimeMaximum(.zero, start - CMTime(seconds: 1, preferredTimescale: 600))
                reader.timeRange = CMTimeRange(start: from, duration: .positiveInfinity)
            }
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return .failed(HLSPackager.PackagerError.unreadable) }
            reader.add(output)
            guard reader.startReading() else {
                return complete ? .failed(reader.error ?? HLSPackager.PackagerError.unreadable) : .wait
            }
            self.reader = reader
            self.output = output
            passIsFinal = complete
            return .ready
        } catch {
            return complete ? .failed(error) : .wait
        }
    }

    /// Blocks the track's queue until the download moves on.
    private func waitForMore() {
        let semaphore = DispatchSemaphore(value: 0)
        let file = file
        Task {
            await file.waitForChange()
            semaphore.signal()
        }
        semaphore.wait()
    }
}

private extension CMSampleBuffer {
    /// Video samples carry `NotSync` unless they are key frames; audio samples are all sync.
    var isSyncSample: Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false) as? [[CFString: Any]],
              let first = attachments.first else { return true }
        return !(first[kCMSampleAttachmentKey_NotSync] as? Bool ?? false)
    }
}

/// One track of the packaged file: its writer's segments on disk and its media playlist.
private final class Rendition: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    enum Kind: String {
        case video
        case audio

        var mediaType: AVMediaType { self == .video ? .video : .audio }
    }

    let kind: Kind
    /// The track is looked up by id in every pass: each pass opens the grown file anew.
    let trackID: CMPersistentTrackID
    let format: CMFormatDescription?
    let transform: CGAffineTransform
    let directory: URL
    var onChange: (() -> Void)?

    private let lock = NSLock()
    private var hasInit = false
    private var durations: [Double] = []
    private var finished = false
    /// The playlist type the player saw first. HLS forbids changing it mid-stream: the car kept
    /// showing only the part it had seen when EVENT turned into VOD.
    private var playlistType: String?

    init(kind: Kind, track: AVAssetTrack, directory: URL) async throws {
        self.kind = kind
        trackID = track.trackID
        format = try await track.load(.formatDescriptions).first
        transform = kind == .video ? try await track.load(.preferredTransform) : .identity
        self.directory = directory
    }

    var playlistName: String { "\(kind.rawValue).m3u8" }
    private var prefix: String { kind == .video ? "v" : "a" }
    private var initName: String { "\(prefix)init.mp4" }

    var segmentCount: Int { lock.withLock { durations.count } }
    var totalDuration: Double { lock.withLock { durations.reduce(0, +) } }
    var isFinished: Bool { lock.withLock { finished } }
    /// The player can begin: the first segment exists, or the track is shorter than one.
    var hasStarted: Bool { lock.withLock { !durations.isEmpty || finished } }

    func markFinished() {
        lock.withLock { finished = true }
    }

    func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data,
                     segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
        switch segmentType {
        case .initialization:
            try? segmentData.write(to: directory.appendingPathComponent(initName))
            lock.withLock { hasInit = true }
        case .separable:
            let index = lock.withLock { durations.count }
            try? segmentData.write(to: directory.appendingPathComponent("\(prefix)\(index).m4s"))
            let duration = segmentReport?.trackReports.first?.duration.seconds ?? HLSPackager.segmentInterval
            lock.withLock { durations.append(duration.isFinite ? duration : HLSPackager.segmentInterval) }
            onChange?()
        @unknown default:
            break
        }
    }

    /// The media playlist as far as it is cut. VOD if it was complete when first asked for;
    /// otherwise EVENT for good, ending with `#EXT-X-ENDLIST` — the player keeps reloading it.
    func playlist() -> String {
        let (durations, finished, type) = lock.withLock { () -> ([Double], Bool, String) in
            let type = playlistType ?? (finished ? "VOD" : "EVENT")
            playlistType = type
            return (durations, finished, type)
        }
        // Fixed while the playlist grows (HLS forbids changing it); segments rarely run past it.
        let target = max(10, Int((durations.max() ?? 0).rounded(.up)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(type)",
            "#EXT-X-INDEPENDENT-SEGMENTS",
            // An EVENT playlist would otherwise start near its end, like live TV.
            "#EXT-X-START:TIME-OFFSET=0,PRECISE=YES",
            "#EXT-X-MAP:URI=\"\(initName)\"",
        ]
        for (index, duration) in durations.enumerated() {
            lines.append(String(format: "#EXTINF:%.3f,", duration))
            lines.append("\(prefix)\(index).m4s")
        }
        if finished {
            lines.append("#EXT-X-ENDLIST")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func file(named name: String) -> Data? {
        let ready = lock.withLock { () -> Bool in
            if name == initName { return hasInit }
            guard name.hasPrefix(prefix), name.hasSuffix(".m4s"),
                  let index = Int(name.dropFirst(prefix.count).dropLast(4)) else { return false }
            return index < durations.count
        }
        guard ready else { return nil }
        return try? Data(contentsOf: directory.appendingPathComponent(name))
    }
}


/// What `LocalHLSServer` hands to our player: a repackaged file or the mirrored screen.
protocol HLSSource: AnyObject, Sendable {
    var id: UUID { get }
    /// `index.m3u8` and the playlists it names; `nil` for an unknown name.
    func playlist(named name: String) -> String?
    /// An init or media segment, once written.
    func file(named name: String) -> Data?
}

extension HLSPackager: HLSSource {}

/// Serves HLS to our own player on `127.0.0.1`: `/hls/<source id>/index.m3u8` and the playlists
/// and segments it names. A source stays until it is cancelled or ends.
final class LocalHLSServer: @unchecked Sendable {
    static let shared = LocalHLSServer()

    private let lock = NSLock()
    private var sources: [UUID: any HLSSource] = [:]
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private lazy var server: HTTPServer = {
        let server = HTTPServer { [weak self] request, respond in
            respond(self?.response(to: request) ?? .empty(404))
        }
        server.onReady = { [weak self] port in self?.ready(port) }
        server.onFailure = { [weak self] message in self?.failed(message) }
        return server
    }()

    /// The playlist address for `source`; starts the server on first use.
    func url(for source: any HLSSource) async throws -> URL {
        lock.withLock { sources[source.id] = source }
        let port = try await serverPort()
        return URL(string: "http://127.0.0.1:\(port)/hls/\(source.id.uuidString)/index.m3u8")!
    }

    func remove(_ source: any HLSSource) {
        lock.withLock { sources[source.id] = nil }
    }

    private func serverPort() async throws -> UInt16 {
        if let port = lock.withLock({ port }) { return port }
        return try await withCheckedThrowingContinuation { continuation in
            let isFirst = lock.withLock { () -> Bool in
                waiters.append(continuation)
                return waiters.count == 1
            }
            if isFirst {
                server.start()
            }
        }
    }

    private func ready(_ port: UInt16) {
        let pending = lock.withLock { () -> [CheckedContinuation<UInt16, Error>] in
            self.port = port
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: port) }
    }

    private func failed(_ message: String) {
        Log.playback.error("hls server: \(message, privacy: .public)")
        let pending = lock.withLock { () -> [CheckedContinuation<UInt16, Error>] in
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(throwing: HLSPackager.PackagerError.cannotRead(message)) }
    }

    private func response(to request: HTTPServer.Request) -> HTTPServer.Response {
        let parts = request.path.split(separator: "/")
        guard parts.count == 3, parts[0] == "hls", let id = UUID(uuidString: String(parts[1])),
              let source = lock.withLock({ sources[id] }) else { return .empty(404) }
        let name = String(parts[2])
        let response: HTTPServer.Response
        if name.hasSuffix(".m3u8") {
            if let playlist = source.playlist(named: name) {
                response = HTTPServer.Response(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-cache"],
                                               body: Data(playlist.utf8))
            } else {
                response = .empty(404)
            }
        } else if let data = source.file(named: name) {
            let type = name.hasSuffix(".mp4") ? "video/mp4" : "video/iso.segment"
            response = HTTPServer.Response(status: 200, headers: ["Content-Type": type], body: data)
        } else {
            response = .empty(404)
        }
        Log.playback.info("hls server: \(request.method, privacy: .public) \(name, privacy: .public) \(response.status) \(response.body.count) B from \(request.remote ?? "?", privacy: .public)")
        return response
    }
}
