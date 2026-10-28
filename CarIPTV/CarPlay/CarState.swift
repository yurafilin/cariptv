import CarPlay
import Observation

/// What the connected car allows. Video is shown only when every check passes.
/// Channels, films and the mirrored screen reach the car through the system's video presentation
/// of our player (iOS 26.4+).
@MainActor @Observable
final class CarState {
    static let shared = CarState()

    enum VideoAvailability: Equatable {
        case allowed
        case notConnected
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
        switch supportsVideoPlayback {
        case nil: return .needsNewerIOS
        case false?: return .unsupportedCar
        case true?: break
        }
        guard limitedInterfaces.isEmpty else { return .whileDriving }
        return .allowed
    }

    /// The mirrored screen plays as a live stream in our player (`ScreenPlayback`), like a channel:
    /// a video app gets no CarPlay window to draw it in (`window=false`, 2026-10-27).
    var mirroringAvailable: Bool {
        videoAvailability == .allowed
    }

    var mirroringMessage: String {
        mirroringAvailable ? String(localized: "Available") : videoAvailability.message
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

    /// Whether the connected head unit can show video at all (iOS 26.4+); `nil` on older iOS.
    static func supportsVideoPlayback(_ configuration: CPSessionConfiguration) -> Bool? {
        if #available(iOS 26.4, *) {
            return configuration.supportsVideoPlayback
        }
        return nil
    }
}

extension CarState.VideoAvailability {
    var message: String {
        switch self {
        case .allowed:
            String(localized: "Video is available")
        case .notConnected:
            String(localized: "Connect your iPhone to CarPlay")
        case .unsupportedCar:
            String(localized: "This car doesn't support video in CarPlay")
        case .needsNewerIOS:
            String(localized: "Video in CarPlay needs iOS 26.4 or later")
        case .whileDriving:
            String(localized: "Video is available only when parked")
        }
    }
}
