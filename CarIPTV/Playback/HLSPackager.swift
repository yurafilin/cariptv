import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Repackages a plain video file — local, or on the web (MP4, MOV, M4V; YouTube's files) — into HLS
/// on the phone, because CarPlay shows only HLS from our player (`-11870` for anything else).
///
/// Nothing is re-encoded: `AVAssetReader` hands over the compressed samples and `AVAssetWriter`
/// (profile `mpeg4AppleHLS`) cuts them into fMP4 segments. A writer cannot pass video and audio
/// through together while segmenting (-11875), so each track gets its own reader and writer and the
/// master playlist joins them (video + an audio rendition), as streaming services do.
/// Segments go to a temporary folder and are served by `LocalHLSServer` while the rest is still being
/// cut, as EVENT playlists that become complete (`#EXT-X-ENDLIST`) at the end.
///
/// `AVAssetReader` reads only local files, so a web file is downloaded first (`onProgress`).
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
    }

    let id = UUID()
    let directory: URL

    private let source: URL
    private let options: [String: Any]?
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "weappico.cariptv.hls")
    // Guarded by `lock`.
    private var renditions: [Rendition] = []
    private var bandwidth = 5_000_000
    private var failure: Error?
    private var isCancelled = false
    private var waiters: [CheckedContinuation<Void, Error>] = []
    private var download: URLSessionTask?

    /// Download progress of a web file, 0…1, called often and from any thread.
    var onProgress: (@Sendable (Double) -> Void)?

    /// Segment length asked of the writer; video segments end at the next key frame after it.
    static let segmentInterval = 4.0

    init(source: URL, options: [String: Any]? = nil) {
        self.source = source
        self.options = options
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
        let local = source.isFileURL ? source : try await downloadSource()
        let asset = AVURLAsset(url: local)
        let tracks = try await asset.load(.tracks)
        guard let video = tracks.first(where: { $0.mediaType == .video }) else { throw PackagerError.noVideo }
        var made = [Rendition(kind: .video, track: video, format: try await video.load(.formatDescriptions).first,
                              transform: try await video.load(.preferredTransform), directory: directory)]
        if let audio = tracks.first(where: { $0.mediaType == .audio }) {
            made.append(Rendition(kind: .audio, track: audio, format: try await audio.load(.formatDescriptions).first,
                                  transform: .identity, directory: directory))
        }
        let seconds = try await asset.load(.duration).seconds
        let bytes = (try? local.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let estimate = seconds > 0 && bytes > 0 ? Int(Double(bytes) * 8 / seconds * 1.2) : 5_000_000
        lock.withLock {
            renditions = made
            bandwidth = estimate
        }
        for rendition in made {
            rendition.onChange = { [weak self] in self?.resumeWaitersIfReady() }
            queue.async { [self] in
                do {
                    try run(rendition, asset: asset)
                } catch {
                    finish(with: error)
                }
            }
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

    private var wasCancelled: Bool { lock.withLock { isCancelled } }

    func cancel() {
        let (download, renditions) = lock.withLock { () -> (URLSessionTask?, [Rendition]) in
            isCancelled = true
            return (self.download, self.renditions)
        }
        download?.cancel()
        queue.async { [self] in
            for rendition in renditions {
                rendition.reader?.cancelReading()
                rendition.writer?.cancelWriting()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        finish(with: CancellationError())
    }

    /// Downloads a web file into the packager's folder, with the page's user agent and cookies.
    private func downloadSource() async throws -> URL {
        var request = URLRequest(url: source, timeoutInterval: 60)
        if let agent = options?[AVURLAssetHTTPUserAgentKey] as? String {
            request.setValue(agent, forHTTPHeaderField: "User-Agent")
        }
        if let cookies = options?[AVURLAssetHTTPCookiesKey] as? [HTTPCookie] {
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        }
        let delegate = DownloadDelegate(
            created: { [weak self] task in
                guard let self else { return }
                let cancelled = lock.withLock { () -> Bool in
                    self.download = task
                    return self.isCancelled
                }
                if cancelled { task.cancel() }
            },
            progress: { [weak self] fraction in self?.onProgress?(fraction) }
        )
        let (temporary, response) = try await URLSession.shared.download(for: request, delegate: delegate)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw PackagerError.downloadFailed
        }
        // The extension tells AVFoundation the container; web files without one are MP4.
        let ext = ["mov", "m4v"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "mp4"
        let file = directory.appendingPathComponent("source.\(ext)")
        try FileManager.default.moveItem(at: temporary, to: file)
        Log.playback.info("hls: downloaded \((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) bytes")
        return file
    }

    /// Copies one track into its own segmented writer.
    private func run(_ rendition: Rendition, asset: AVAsset) throws {
        let reader = try AVAssetReader(asset: asset)
        // nil settings: compressed samples are copied, not decoded.
        let output = AVAssetReaderTrackOutput(track: rendition.track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        let writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)
        writer.outputFileTypeProfile = .mpeg4AppleHLS
        writer.preferredOutputSegmentInterval = CMTime(seconds: Self.segmentInterval, preferredTimescale: 1)
        writer.initialSegmentStartTime = .zero
        writer.delegate = rendition
        let input = AVAssetWriterInput(mediaType: rendition.track.mediaType, outputSettings: nil, sourceFormatHint: rendition.format)
        input.expectsMediaDataInRealTime = false
        input.transform = rendition.transform
        guard reader.canAdd(output), writer.canAdd(input) else {
            throw PackagerError.cannotRead(String(localized: "This video can't be prepared for the car display."))
        }
        reader.add(output)
        writer.add(input)
        rendition.reader = reader
        rendition.writer = writer

        guard reader.startReading() else {
            throw reader.error ?? PackagerError.cannotRead(String(localized: "This video can't be read."))
        }
        guard writer.startWriting() else {
            throw writer.error ?? PackagerError.cannotRead(String(localized: "This video can't be prepared for the car display."))
        }
        writer.startSession(atSourceTime: .zero)

        input.requestMediaDataWhenReady(on: queue) { [weak self] in
            while input.isReadyForMoreMediaData {
                guard self?.wasCancelled == false, let sample = output.copyNextSampleBuffer(), input.append(sample) else {
                    input.markAsFinished()
                    self?.complete(rendition, reader: reader, writer: writer)
                    return
                }
            }
        }
    }

    private func complete(_ rendition: Rendition, reader: AVAssetReader, writer: AVAssetWriter) {
        guard !wasCancelled else { return }
        if reader.status == .failed {
            finish(with: reader.error ?? PackagerError.cannotRead(String(localized: "This video can't be read.")))
            return
        }
        writer.finishWriting { [self] in
            if writer.status == .failed {
                finish(with: writer.error ?? PackagerError.cannotRead(String(localized: "This video can't be prepared for the car display.")))
                return
            }
            rendition.markFinished()
            Log.playback.info("hls: \(rendition.kind.rawValue, privacy: .public) done, \(rendition.segmentCount) segments")
            resumeWaitersIfReady()
        }
    }

    private func finish(with error: Error) {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            if failure == nil { failure = error }
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(throwing: error) }
    }

    private func resumeWaitersIfReady() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Error>] in
            guard failure == nil, renditions.allSatisfy(\.hasStarted) else { return [] }
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume() }
    }

    // MARK: - Serving

    private var video: Rendition? { lock.withLock { renditions.first } }

    var segmentCount: Int { video?.segmentCount ?? 0 }
    var totalDuration: Double { video?.totalDuration ?? 0 }
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

/// One track of the packaged file: its writer's segments on disk and its media playlist.
private final class Rendition: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
    enum Kind: String {
        case video
        case audio
    }

    let kind: Kind
    let track: AVAssetTrack
    let format: CMFormatDescription?
    let transform: CGAffineTransform
    let directory: URL
    var onChange: (() -> Void)?
    // Used on the packager's queue.
    var reader: AVAssetReader?
    var writer: AVAssetWriter?

    private let lock = NSLock()
    private var hasInit = false
    private var durations: [Double] = []
    private var finished = false

    init(kind: Kind, track: AVAssetTrack, format: CMFormatDescription?, transform: CGAffineTransform, directory: URL) {
        self.kind = kind
        self.track = track
        self.format = format
        self.transform = transform
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

    /// The media playlist as far as it is cut. EVENT until the end: the player keeps reloading it.
    func playlist() -> String {
        let (durations, finished) = lock.withLock { (durations, self.finished) }
        // Fixed while the playlist grows (HLS forbids changing it); segments rarely run past it.
        let target = max(10, Int((durations.max() ?? 0).rounded(.up)))
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(target)",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:\(finished ? "VOD" : "EVENT")",
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

/// Reports the download task as soon as it exists (for cancelling) and its progress.
private final class DownloadDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let created: (URLSessionTask) -> Void
    private let progress: (Double) -> Void
    private var observation: NSKeyValueObservation?

    init(created: @escaping (URLSessionTask) -> Void, progress: @escaping (Double) -> Void) {
        self.created = created
        self.progress = progress
    }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        created(task)
        let progress = progress
        observation = task.progress.observe(\.fractionCompleted) { value, _ in
            progress(value.fractionCompleted)
        }
    }
}

/// Serves packaged HLS to our own player on `127.0.0.1`: `/hls/<packager id>/index.m3u8` and the
/// video and audio playlists and segments it names.
final class LocalHLSServer: @unchecked Sendable {
    static let shared = LocalHLSServer()

    private let lock = NSLock()
    private var packagers: [UUID: HLSPackager] = [:]
    private var port: UInt16?
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private lazy var server: HTTPServer = {
        let server = HTTPServer(loopbackOnly: true) { [weak self] request, respond in
            respond(self?.response(to: request) ?? .empty(404))
        }
        server.onReady = { [weak self] port in self?.ready(port) }
        server.onFailure = { [weak self] message in self?.failed(message) }
        return server
    }()

    /// The playlist address for `packager`; starts the server on first use.
    func url(for packager: HLSPackager) async throws -> URL {
        lock.withLock { packagers = [packager.id: packager] }
        let port = try await serverPort()
        return URL(string: "http://127.0.0.1:\(port)/hls/\(packager.id.uuidString)/index.m3u8")!
    }

    func remove(_ packager: HLSPackager) {
        lock.withLock { packagers[packager.id] = nil }
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
              let packager = lock.withLock({ packagers[id] }) else { return .empty(404) }
        let name = String(parts[2])
        if name.hasSuffix(".m3u8") {
            guard let playlist = packager.playlist(named: name) else { return .empty(404) }
            return HTTPServer.Response(status: 200, headers: ["Content-Type": "application/vnd.apple.mpegurl", "Cache-Control": "no-cache"],
                                       body: Data(playlist.utf8))
        }
        guard let data = packager.file(named: name) else { return .empty(404) }
        let type = name.hasSuffix(".mp4") ? "video/mp4" : "video/iso.segment"
        return HTTPServer.Response(status: 200, headers: ["Content-Type": type], body: data)
    }
}
