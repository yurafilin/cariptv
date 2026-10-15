import CarPlay
import Observation

/// What the connected car allows. Video is shown only when every check passes.
@MainActor @Observable
final class CarState {
    static let shared = CarState()

    enum VideoAvailability: Equatable {
        case allowed
        case notConnected
        /// CarPlay connected the scene without a window of our own: nothing to draw video into.
        case noCarWindow
        /// The head unit reports `supportsVideoPlayback == false`.
        case unsupportedCar
        /// `supportsVideoPlayback` is missing: iOS before 26.4.
        case needsNewerIOS
        /// CarPlay limits the interface, which it does while the car is moving.
        case whileDriving
    }

    private(set) var isConnected = false
    private(set) var hasWindow = false
    private(set) var supportsVideoPlayback: Bool?
    private(set) var limitedInterfaces: CPLimitableUserInterface = []

    private init() {}

    var videoAvailability: VideoAvailability {
        guard isConnected else { return .notConnected }
        guard hasWindow else { return .noCarWindow }
        #if targetEnvironment(simulator)
        // The Simulator's CarPlay display is not a car: there is no parked state to respect.
        return .allowed
        #else
        switch supportsVideoPlayback {
        case nil: return .needsNewerIOS
        case false?: return .unsupportedCar
        case true?: break
        }
        guard limitedInterfaces.isEmpty else { return .whileDriving }
        return .allowed
        #endif
    }

    func connect(hasWindow: Bool, supportsVideoPlayback: Bool?, limitedInterfaces: CPLimitableUserInterface) {
        isConnected = true
        self.hasWindow = hasWindow
        self.supportsVideoPlayback = supportsVideoPlayback
        self.limitedInterfaces = limitedInterfaces
    }

    func update(limitedInterfaces: CPLimitableUserInterface) {
        self.limitedInterfaces = limitedInterfaces
    }

    func disconnect() {
        isConnected = false
        hasWindow = false
        supportsVideoPlayback = nil
        limitedInterfaces = []
    }

    /// `CPSessionConfiguration.supportsVideoPlayback` ships in iOS 26.4. The SDK of Xcode 26.3 (iOS 26.2)
    /// does not declare it, so it is read through the Objective-C runtime; switch to the property
    /// once the project builds with the iOS 26.4+ SDK.
    nonisolated static func supportsVideoPlayback(_ configuration: CPSessionConfiguration) -> Bool? {
        let key = "supportsVideoPlayback"
        guard configuration.responds(to: NSSelectorFromString(key)) else { return nil }
        return configuration.value(forKey: key) as? Bool
    }
}

extension CarState.VideoAvailability {
    var message: String {
        switch self {
        case .allowed:
            String(localized: "Video is available")
        case .notConnected:
            String(localized: "Connect your iPhone to CarPlay")
        case .noCarWindow, .unsupportedCar:
            String(localized: "This car doesn't support video in CarPlay")
        case .needsNewerIOS:
            String(localized: "Video in CarPlay needs iOS 26.4 or later")
        case .whileDriving:
            String(localized: "Video is available only when parked")
        }
    }
}
