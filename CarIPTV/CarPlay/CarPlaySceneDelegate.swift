import CarPlay
import UIKit

/// CarPlay scene: tabs with favorites, recent channels and the screen status.
/// When CarPlay hands the app a window of its own, video is drawn there by `CarScreenViewController`.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private var sessionConfiguration: CPSessionConfiguration?
    private var observers: [StateObserver] = []

    private let favoritesTemplate = CPListTemplate(title: String(localized: "Favorites"), sections: [])
    private let recentTemplate = CPListTemplate(title: String(localized: "Recent"), sections: [])
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
        screenTemplate.tabTitle = String(localized: "Screen")
        screenTemplate.tabImage = UIImage(systemName: "rectangle.on.rectangle")
        screenTemplate.updateSections([CPListSection(items: [playingItem, mirroringItem])])

        let tabs = CPTabBarTemplate(templates: [favoritesTemplate, recentTemplate, screenTemplate])
        interfaceController.setRootTemplate(tabs, animated: false, completion: nil)

        observers = [
            StateObserver { [weak self] in self?.updateList(self?.favoritesTemplate, LibraryStore.shared.favorites) },
            StateObserver { [weak self] in self?.updateList(self?.recentTemplate, LibraryStore.shared.recent) },
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
        let limit = min(items.count, CPListTemplate.maximumItemCount)
        let rows = items.prefix(limit).map { item -> CPListItem in
            let row = CPListItem(text: item.channel.name, detailText: item.channel.group, image: UIImage(systemName: "tv"))
            row.handler = { [weak self] _, completion in
                PlaybackController.shared.play(item, queue: items)
                self?.showNowPlaying()
                completion()
            }
            return row
        }
        template.updateSections([CPListSection(items: Array(rows))])
    }

    private func updateScreenItems() {
        let availability = CarState.shared.videoAvailability
        let mirror = MirrorStatus.shared
        let playback = PlaybackController.shared

        playingItem.setText(playback.media?.title ?? String(localized: "Nothing playing"))
        playingItem.setDetailText(playback.isActive ? playback.state.message : nil)

        let detail: String
        if availability != .allowed {
            detail = availability.message
        } else if mirror.state == .streaming {
            detail = String(localized: "On · \(mirror.framesPerSecond) fps")
        } else {
            detail = String(localized: "Start mirroring on your iPhone")
        }
        mirroringItem.setDetailText(detail)
    }

    private func showNowPlaying() {
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
