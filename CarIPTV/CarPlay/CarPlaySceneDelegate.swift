import CarPlay
import CoreMedia
import UIKit

/// CarPlay scene: tabs with favorites, recent channels, the videos imported on the phone and the screen status.
/// Selecting a channel starts our player; on iOS 26.4+ the system then shows its video on the car
/// screen (`CPPlaybackConfiguration`, AirPlay from the same `AVPlayer`) while the car is parked.
/// If CarPlay also hands the app a window of its own, mirroring is drawn there by `CarScreenViewController`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private var sessionConfiguration: CPSessionConfiguration?
    private var observers: [StateObserver] = []

    private let favoritesTemplate = CPListTemplate(title: String(localized: "Favorites"), sections: [])
    private let recentTemplate = CPListTemplate(title: String(localized: "Recent"), sections: [])
    private let videosTemplate = CPListTemplate(title: String(localized: "Videos"), sections: [])
    private let screenTemplate = CPListTemplate(title: String(localized: "Screen"), sections: [])
    private let mirroringItem = CPListItem(text: String(localized: "Screen mirroring"), detailText: nil)
    private let playingItem = CPListItem(text: String(localized: "Now playing"), detailText: nil)

    // MARK: - Connection

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        connect(interfaceController, window: nil)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        connect(interfaceController, window: window)
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        disconnect()
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController,
        from window: CPWindow
    ) {
        disconnect()
    }

    private func connect(_ interfaceController: CPInterfaceController, window: CPWindow?) {
        self.interfaceController = interfaceController
        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration

        let supportsVideo = CarState.supportsVideoPlayback(configuration)
        let limited = configuration.limitedUserInterfaces
        Log.carplay.info("car: connected window=\(window != nil) supportsVideoPlayback=\(String(describing: supportsVideo)) limited=\(limited.rawValue)")

        if let window {
            window.rootViewController = CarScreenViewController()
            self.window = window
        }
        CarState.shared.connect(hasWindow: window != nil, supportsVideoPlayback: supportsVideo, limitedInterfaces: limited)

        favoritesTemplate.tabTitle = String(localized: "Favorites")
        favoritesTemplate.tabImage = UIImage(systemName: "heart")
        favoritesTemplate.emptyViewTitleVariants = [String(localized: "No favorites yet")]
        favoritesTemplate.emptyViewSubtitleVariants = [String(localized: "Touch and hold a channel on your iPhone to add it.")]
        recentTemplate.tabTitle = String(localized: "Recent")
        recentTemplate.tabImage = UIImage(systemName: "clock")
        recentTemplate.emptyViewTitleVariants = [String(localized: "Nothing played yet")]
        videosTemplate.tabTitle = String(localized: "Videos")
        videosTemplate.tabImage = UIImage(systemName: "film")
        videosTemplate.emptyViewTitleVariants = [String(localized: "No videos yet")]
        videosTemplate.emptyViewSubtitleVariants = [String(localized: "Add videos on your iPhone in Downloads.")]
        screenTemplate.tabTitle = String(localized: "Screen")
        screenTemplate.tabImage = UIImage(systemName: "rectangle.on.rectangle")
        screenTemplate.updateSections([CPListSection(items: [playingItem, mirroringItem])])

        let tabs = CPTabBarTemplate(templates: [favoritesTemplate, recentTemplate, videosTemplate, screenTemplate])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        observers = [
            StateObserver { [weak self] in self?.updateList(self?.favoritesTemplate, LibraryStore.shared.favorites) },
            StateObserver { [weak self] in self?.updateList(self?.recentTemplate, LibraryStore.shared.recent) },
            StateObserver { [weak self] in self?.updateVideos() },
            StateObserver { [weak self] in self?.updateScreenItems() },
        ]
        MirrorReceiver.shared.start()
        CastReceiver.shared.setActive(true, for: .carPlay)
    }

    private func disconnect() {
        Log.carplay.info("car: disconnected")
        observers.forEach { $0.cancel() }
        observers = []
        window?.rootViewController = nil
        window = nil
        interfaceController = nil
        sessionConfiguration = nil
        CarState.shared.disconnect()
        CastReceiver.shared.setActive(false, for: .carPlay)
    }

    // MARK: - Content

    private func updateList(_ template: CPListTemplate?, _ items: [LibraryItem]) {
        guard let template else { return }
        let playback = PlaybackController.shared
        let currentID = playback.media?.libraryItem?.id
        let limit = min(items.count, CPListTemplate.maximumItemCount)
        let rows = items.prefix(limit).map { item -> CPListItem in
            let row = CPListItem(text: item.channel.name, detailText: item.channel.group, image: UIImage(systemName: "tv"))
            let isCurrent = item.id == currentID
            let pauses = isCurrent && playback.state == .playing
            if #available(iOS 26.4, *) {
                row.playbackConfiguration = Self.playbackConfiguration(isCurrent: isCurrent, pauses: pauses)
            }
            row.isPlaying = isCurrent && playback.isActive
            row.handler = { [weak self] _, completion in
                if pauses {
                    playback.pause()
                } else if isCurrent, playback.state == .paused {
                    playback.resume()
                } else {
                    playback.play(item, queue: items)
                }
                self?.showNowPlaying()
                completion()
            }
            return row
        }
        template.updateSections([CPListSection(items: Array(rows))])
    }

    /// Videos imported on the phone. They play like films: the player repackages them for the car.
    private func updateVideos() {
        let store = LibraryStore.shared
        let playback = PlaybackController.shared
        let videos = store.localVideos.prefix(CPListTemplate.maximumItemCount)
        let rows = videos.map { video -> CPListItem in
            let url = store.url(for: video)
            let row = CPListItem(
                text: video.title,
                detailText: video.addedAt.formatted(date: .abbreviated, time: .omitted),
                image: UIImage(systemName: "film")
            )
            let isCurrent = playback.media?.url == url
            let pauses = isCurrent && playback.state == .playing
            if #available(iOS 26.4, *) {
                row.playbackConfiguration = Self.playbackConfiguration(isCurrent: isCurrent, pauses: pauses)
            }
            row.isPlaying = isCurrent && playback.isActive
            row.handler = { [weak self] _, completion in
                if pauses {
                    playback.pause()
                } else if isCurrent, playback.state == .paused {
                    playback.resume()
                } else {
                    playback.play(PlayableMedia(title: video.title, url: url, isLive: false))
                }
                self?.showNowPlaying()
                completion()
            }
            return row
        }
        videosTemplate.updateSections([CPListSection(items: Array(rows))])
    }

    /// The system shows the video itself (or "Now Playing" in cars without video) after the
    /// row is selected; the row also carries the play or pause glyph and the progress.
    @available(iOS 26.4, *)
    private static func playbackConfiguration(isCurrent: Bool, pauses: Bool) -> CPPlaybackConfiguration {
        var elapsed = CMTime.zero
        var duration = CMTime.zero
        if isCurrent {
            let position = PlaybackController.shared.position
            elapsed = CMTime(seconds: position.elapsed, preferredTimescale: 600)
            // Live channels have no duration; CarPlay expects zero for them.
            if let total = position.duration {
                duration = CMTime(seconds: total, preferredTimescale: 600)
            }
        }
        return CPPlaybackConfiguration(
            preferredPresentation: .video,
            playbackAction: pauses ? .pause : .play,
            elapsedTime: elapsed,
            duration: duration
        )
    }

    private func updateScreenItems() {
        let car = CarState.shared
        let mirror = MirrorStatus.shared
        let playback = PlaybackController.shared

        playingItem.setText(playback.media?.title ?? String(localized: "Nothing playing"))
        playingItem.setDetailText(playback.isActive ? playback.state.message : nil)

        let detail: String
        if !car.mirroringAvailable {
            detail = car.mirroringMessage
        } else if mirror.state == .streaming {
            detail = String(localized: "On · \(mirror.framesPerSecond) fps")
        } else {
            detail = String(localized: "Start mirroring on your iPhone")
        }
        mirroringItem.setDetailText(detail)
    }

    /// Before iOS 26.4 the rows carry no playback configuration, so "Now Playing" is opened by hand.
    private func showNowPlaying() {
        if #available(iOS 26.4, *) { return }
        guard let interfaceController, interfaceController.topTemplate !== CPNowPlayingTemplate.shared else { return }
        interfaceController.pushTemplate(CPNowPlayingTemplate.shared, animated: true) { _, error in
            if let error {
                Log.carplay.error("car: now playing push failed \(error.localizedDescription)")
            }
        }
    }
}

extension CarPlaySceneDelegate: CPSessionConfigurationDelegate {
    nonisolated func sessionConfiguration(
        _ sessionConfiguration: CPSessionConfiguration,
        limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface
    ) {
        Log.carplay.info("car: limited interfaces \(limitedUserInterfaces.rawValue)")
        MainActor.assumeIsolated {
            CarState.shared.update(limitedInterfaces: limitedUserInterfaces)
        }
    }
}
