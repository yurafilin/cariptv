import AVFoundation
import MediaPlayer
import Observation

/// The one player of the app. The phone and the car display attach their own layers to `player`;
/// the car attaches only while the car allows video, so otherwise the stream plays as audio.
@MainActor @Observable
final class PlaybackController {
    static let shared = PlaybackController()

    enum State: Equatable {
        case idle
        case loading
        /// A web file is downloading before it is repackaged for the car (percent).
        case preparing(Int)
        case playing
        case paused
        case failed(String)
    }

    let player = AVPlayer()
    private(set) var media: PlayableMedia?
    private(set) var state: State = .idle
    /// The list the current item was started from: next and previous step through it.
    private(set) var queue: [LibraryItem] = []

    @ObservationIgnored private var itemObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeControlObservation: NSKeyValueObservation?
    /// `PlayableMedia.startTime`, applied once the item can seek.
    @ObservationIgnored private var pendingStart: Double?
    /// Repackages the current file into HLS for the car display.
    @ObservationIgnored private var packager: HLSPackager?

    private init() {
        // CarPlay video apps must support AirPlay video: in cars that show video the system
        // routes the stream to the car display.
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in PlaybackController.shared.timeControlChanged(status) }
        }
        setUpRemoteCommands()
    }

    var isActive: Bool { media != nil }

    var canStep: Bool { queue.count > 1 && media?.libraryItem != nil }

    /// Plays `media`; `queue` is the list it came from (channels of a group, favorites, episodes).
    func play(_ media: PlayableMedia, queue: [LibraryItem] = []) {
        activateAudioSession()
        self.queue = queue.count > 1 ? queue : []
        updateStepCommands()
        self.media = media
        state = .loading
        Log.playback.info("play \(media.url.absoluteString, privacy: .private)")

        pendingStart = media.startTime.flatMap { $0 > 1 ? $0 : nil }
        packager?.cancel()
        packager = nil

        // Server posters carry internal URLs; the stream URL with credentials is built only now.
        let source = LibraryStore.shared.resolvedURL(media.url)
        // The car shows only HLS from our player (-11870 for plain files): files are repackaged on the phone.
        let toCar = CarState.shared.videoAvailability == .allowed
        if toCar, HLSPackager.needsPackaging(source, isLive: media.isLive) {
            // The phone reads the file, so the page's user agent and cookies still apply.
            playPackaged(source, options: media.web?.assetOptions)
        } else {
            // A stream going to the car is not given them: external playback may refuse such an asset.
            startItem(AVURLAsset(url: source, options: toCar ? nil : media.web?.assetOptions))
        }

        if let libraryItem = media.libraryItem {
            LibraryStore.shared.markPlayed(libraryItem)
        }
        updateNowPlaying()
    }

    /// Repackages `source` into HLS, then plays the local playlist.
    private func playPackaged(_ source: URL, options: [String: Any]?) {
        let packager = HLSPackager(source: source, options: options)
        packager.onProgress = { fraction in
            let percent = Int(fraction * 100)
            Task { @MainActor in
                let controller = PlaybackController.shared
                guard controller.packager === packager, controller.state != .preparing(percent),
                      controller.player.currentItem == nil else { return }
                controller.state = .preparing(percent)
                controller.updateNowPlaying()
            }
        }
        self.packager = packager
        player.replaceCurrentItem(with: nil)
        Task {
            do {
                try await packager.start()
                let url = try await LocalHLSServer.shared.url(for: packager)
                guard self.packager === packager else { return }
                Log.playback.info("hls: playing \(packager.segmentCount) segments so far")
                startItem(AVURLAsset(url: url))
            } catch {
                guard self.packager === packager, !(error is CancellationError) else { return }
                Log.playback.error("hls: \(String(describing: error), privacy: .public)")
                state = .failed(Self.describe(error) ?? String(localized: "This video can't be played. Its format may not be supported."))
                updateNowPlaying()
            }
        }
    }

    private func startItem(_ asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        itemObservation = item.observe(\.status, options: [.new]) { item, _ in
            let status = item.status
            if let error = item.error {
                Log.playback.error("item error: \(String(describing: error))")
            }
            let message = Self.describe(item.error)
            Task { @MainActor in PlaybackController.shared.itemStatusChanged(status, message: message) }
        }
        player.replaceCurrentItem(with: item)
        player.play()
    }

    func play(_ item: LibraryItem, queue: [LibraryItem] = []) {
        play(PlayableMedia(item), queue: queue)
    }

    /// Next (+1) or previous (-1) item of the queue, wrapping around.
    func step(_ offset: Int) {
        guard canStep, let current = media?.libraryItem,
              let index = Self.index(of: current.id, in: queue.map(\.id), offset: offset) else { return }
        play(PlayableMedia(queue[index]), queue: queue)
    }

    nonisolated static func index(of id: String, in ids: [String], offset: Int) -> Int? {
        guard !ids.isEmpty, let current = ids.firstIndex(of: id) else { return nil }
        let count = ids.count
        return ((current + offset) % count + count) % count
    }

    func resume() {
        guard media != nil else { return }
        player.play()
    }

    func pause() {
        player.pause()
    }

    func togglePause() {
        player.timeControlStatus == .paused ? resume() : pause()
    }

    func stop() {
        packager?.cancel()
        packager = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        itemObservation = nil
        media = nil
        state = .idle
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func seek(to seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
    }

    /// Position and duration in seconds; duration is `nil` for live streams.
    var position: (elapsed: Double, duration: Double?) {
        let elapsed = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds
        return (elapsed.isFinite ? elapsed : 0, duration.flatMap { $0.isFinite ? $0 : nil })
    }

    // MARK: - Observation

    /// Network errors read well as they are; media errors ("CoreMediaErrorDomain -16172") do not.
    nonisolated static func describe(_ error: Error?) -> String? {
        if let error = error as? HLSPackager.PackagerError {
            return error.errorDescription
        }
        guard let error = error as NSError? else { return nil }
        if error.domain == NSURLErrorDomain {
            return error.localizedDescription
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSURLErrorDomain {
            return underlying.localizedDescription
        }
        return String(localized: "This video can't be played. Its format may not be supported.")
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?) {
        switch status {
        case .failed:
            state = .failed(message ?? String(localized: "This video can't be played. Its format may not be supported."))
        case .readyToPlay:
            if let start = pendingStart {
                pendingStart = nil
                seek(to: start)
            }
            if state == .loading, player.timeControlStatus == .playing {
                state = .playing
            }
        default:
            break
        }
        updateNowPlaying()
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        // While a file is being prepared for the car there is no item yet: nothing has paused.
        guard media != nil, player.currentItem != nil else { return }
        if case .failed = state { return }
        switch status {
        case .playing: state = .playing
        case .paused: state = .paused
        case .waitingToPlayAtSpecifiedRate: state = .loading
        @unknown default: break
        }
        updateNowPlaying()
    }

    // MARK: - System integration

    private func activateAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            Log.playback.error("audio session: \(error.localizedDescription)")
        }
    }

    private func updateNowPlaying() {
        guard let media else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPNowPlayingInfoPropertyIsLiveStream: media.isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0,
        ]
        if let subtitle = media.subtitle {
            info[MPMediaItemPropertyArtist] = subtitle
        }
        let position = position
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position.elapsed
        if let duration = position.duration {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.resume() }
            return .success
        }
        center.pauseCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.togglePause() }
            return .success
        }
        center.stopCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.stop() }
            return .success
        }
        // Steering-wheel and lock-screen next/previous switch channels.
        center.nextTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.step(1) }
            return .success
        }
        center.previousTrackCommand.addTarget { _ in
            MainActor.assumeIsolated { PlaybackController.shared.step(-1) }
            return .success
        }
        updateStepCommands()
    }

    private func updateStepCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.nextTrackCommand.isEnabled = queue.count > 1
        center.previousTrackCommand.isEnabled = queue.count > 1
    }
}

extension PlaybackController.State {
    var message: String {
        switch self {
        case .idle: String(localized: "Not playing")
        case .loading: String(localized: "Loading…")
        case .preparing(let percent): String(localized: "Preparing for the car… \(percent)%")
        case .playing: String(localized: "Playing")
        case .paused: String(localized: "Paused")
        case .failed(let message): message
        }
    }
}
