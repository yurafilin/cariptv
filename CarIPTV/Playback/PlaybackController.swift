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
    @ObservationIgnored private var externalObservation: NSKeyValueObservation?
    /// `PlayableMedia.startTime`, applied once the item can seek.
    @ObservationIgnored private var pendingStart: Double?
    /// Repackages the current file into HLS for the car display.
    @ObservationIgnored private var packager: HLSPackager?
    /// The packager whose growing playlist the car already refused once.
    @ObservationIgnored private var retriedPackager: HLSPackager?

    private init() {
        // CarPlay video apps must support AirPlay video: in cars that show video the system
        // routes the stream to the car display.
        player.allowsExternalPlayback = true
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in PlaybackController.shared.timeControlChanged(status) }
        }
        externalObservation = player.observe(\.isExternalPlaybackActive, options: [.new]) { player, _ in
            let active = player.isExternalPlaybackActive
            Log.playback.info("car video: \(active ? "on" : "off", privacy: .public)")
            Task { @MainActor in PlaybackController.shared.carVideoChanged(active) }
        }
        setUpRemoteCommands()
    }

    var isActive: Bool { media != nil }

    var canStep: Bool { queue.count > 1 && media?.libraryItem != nil }

    /// Plays `media`; `queue` is the list it came from (channels of a group, favorites, episodes).
    func play(_ media: PlayableMedia, queue: [LibraryItem] = []) {
        activateAudioSession(mixing: media.isScreen)
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

    /// How long a packaged file may take to be cut completely before playback starts anyway.
    private static let completeWait: Duration = .seconds(20)

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
                // Most web videos are cut in seconds: wait a little and hand the car a complete
                // playlist, with the whole length to scrub. Longer ones start while still growing.
                let deadline = ContinuousClock.now + Self.completeWait
                while !packager.isComplete, packager.error == nil, ContinuousClock.now < deadline, self.packager === packager {
                    try await Task.sleep(for: .milliseconds(200))
                }
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

    /// Plays the packaged stream again once it is cut to the end (a VOD playlist), from where it was.
    private func replayWhenComplete(_ packager: HLSPackager) {
        let position = player.currentTime().seconds
        state = .loading
        Task {
            while !packager.isComplete {
                guard self.packager === packager, packager.error == nil else { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard self.packager === packager, let url = try? await LocalHLSServer.shared.url(for: packager) else { return }
            Log.playback.info("hls: car refused the growing playlist; playing it complete, \(packager.segmentCount) segments")
            if pendingStart == nil, position.isFinite, position > 1 {
                pendingStart = position
            }
            startItem(AVURLAsset(url: url))
        }
    }

    private func startItem(_ asset: AVURLAsset) {
        let item = AVPlayerItem(asset: asset)
        let isScreen = media?.isScreen == true
        if isScreen {
            // Where to start is in the stream itself (`MirrorStream`): the car's player does not see
            // this item's settings (a 1.5 s offset left the car 5–6 s behind, as the default did).
            item.automaticallyPreservesTimeOffsetFromLive = true
            watchDelay(of: item)
        }
        itemObservation = item.observe(\.status, options: [.new]) { item, _ in
            let status = item.status
            if let error = item.error {
                Log.playback.error("item error: \(String(describing: error))")
                for event in item.errorLog()?.events.suffix(5) ?? [] {
                    Log.playback.error("item log: \(event.errorStatusCode) \(event.errorDomain, privacy: .public) \(event.errorComment ?? "", privacy: .public) \(event.uri ?? "", privacy: .public)")
                }
            }
            let message = Self.describe(item.error)
            let code = (item.error as NSError?)?.code
            Task { @MainActor in PlaybackController.shared.itemStatusChanged(status, message: message, code: code) }
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
        if media?.isScreen == true {
            // A paused screen is out of date: go on from what the iPhone shows now.
            jumpToLive()
        }
        player.play()
    }

    /// The car took the video back (after the car app was left or the picture paused): the
    /// mirrored screen goes on from now.
    private func carVideoChanged(_ active: Bool) {
        guard active, media?.isScreen == true, player.timeControlStatus == .paused else { return }
        Log.playback.info("screen: car video back, playing from now")
        resume()
    }

    /// Seeks the mirrored screen to where its stream starts behind the live edge.
    private func jumpToLive() {
        guard let item = player.currentItem, let live = item.seekableTimeRanges.last?.timeRangeValue.end, live.isNumeric else { return }
        let offset = CMTime(seconds: MirrorStream.startBehindLive, preferredTimescale: 600)
        player.seek(to: CMTimeSubtract(live, offset))
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

    private func itemStatusChanged(_ status: AVPlayerItem.Status, message: String?, code: Int?) {
        switch status {
        case .failed:
            // The car refused the packaged stream (-11870): try once more with the playlist complete.
            if code == AVError.Code.externalPlaybackNotSupportedForAsset.rawValue, let packager, retriedPackager !== packager {
                retriedPackager = packager
                replayWhenComplete(packager)
                return
            }
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
        let waiting = player.reasonForWaitingToPlay?.rawValue ?? "-"
        Log.playback.info("player: \(Self.name(of: status), privacy: .public), waiting for \(waiting, privacy: .public), in car \(self.player.isExternalPlaybackActive)")
        switch status {
        case .playing: state = .playing
        case .paused: state = .paused
        case .waitingToPlayAtSpecifiedRate: state = .loading
        @unknown default: break
        }
        updateNowPlaying()
    }

    private static func name(of status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .playing: "playing"
        case .paused: "paused"
        case .waitingToPlayAtSpecifiedRate: "waiting"
        @unknown default: "unknown"
        }
    }

    // MARK: - System integration

    /// A playing screen this far behind the iPhone has stalled: it jumps back to the live edge.
    private static let screenMaxDelay = 8.0

    /// How far the mirrored screen's picture trails the iPhone screen in our player, every few
    /// seconds: the stream dates its segments. The car adds its own buffering on top.
    private func watchDelay(of item: AVPlayerItem) {
        Task {
            while player.currentItem === item {
                try? await Task.sleep(for: .seconds(3))
                guard player.currentItem === item, let date = item.currentDate() else { continue }
                let delay = Date().timeIntervalSince(date)
                Log.playback.info("screen: picture \(String(format: "%.1f", delay)) s behind, in car \(self.player.isExternalPlaybackActive)")
                if delay > Self.screenMaxDelay, player.timeControlStatus != .paused {
                    Log.playback.info("screen: too far behind, jumping to the live edge")
                    jumpToLive()
                }
            }
        }
    }

    /// `mixing`: the mirrored screen has no sound of its own; the source app keeps playing its sound
    /// through the car instead of being interrupted by ours.
    private func activateAudioSession(mixing: Bool) {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback, options: mixing ? [.mixWithOthers] : [])
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
