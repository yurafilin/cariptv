import CarPlay
import UIKit

/// CarPlay scene. When CarPlay hands the app a window of its own, the mirrored screen is drawn
/// there by `CarMirrorViewController`; the list template carries the status either way.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?
    private var window: CPWindow?
    private var sessionConfiguration: CPSessionConfiguration?
    private var observer: StateObserver?
    private let statusItem = CPListItem(text: String(localized: "Screen mirroring"), detailText: nil)

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
            window.rootViewController = CarMirrorViewController()
            self.window = window
        }
        CarState.shared.connect(hasWindow: window != nil, supportsVideoPlayback: supportsVideo, limitedInterfaces: limited)

        let template = CPListTemplate(title: "CarIPTV", sections: [CPListSection(items: [statusItem])])
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        observer = StateObserver { [weak self] in
            self?.updateStatusItem()
        }
        MirrorReceiver.shared.start()
    }

    private func disconnect() {
        Log.carplay.info("car: disconnected")
        observer?.cancel()
        observer = nil
        window?.rootViewController = nil
        window = nil
        interfaceController = nil
        sessionConfiguration = nil
        CarState.shared.disconnect()
    }

    private func updateStatusItem() {
        let availability = CarState.shared.videoAvailability
        let mirror = MirrorStatus.shared
        let detail: String
        if availability != .allowed {
            detail = availability.message
        } else if mirror.state == .streaming {
            detail = String(localized: "On · \(mirror.framesPerSecond) fps")
        } else {
            detail = String(localized: "Start mirroring on your iPhone")
        }
        statusItem.setDetailText(detail)
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
