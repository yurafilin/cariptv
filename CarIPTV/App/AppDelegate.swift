import CarPlay
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        // The car screen has its own orientation; only the phone is locked.
        if window is CPWindow {
            return .all
        }
        return OrientationLock.mask
    }
}

/// The phone UI is portrait; the player unlocks landscape for full-screen video.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func allowLandscape(_ allowed: Bool) {
        mask = allowed ? .allButUpsideDown : .portrait
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene, windowScene.session.role == .windowApplication else { continue }
            windowScene.windows.first { $0.isKeyWindow }?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            if !allowed {
                windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
            #if DEBUG
            // `-CarIPTVDebugLandscape YES`: turn the Simulator sideways when the player opens.
            if allowed, UserDefaults.standard.bool(forKey: "CarIPTVDebugLandscape") {
                // The unlocked orientations reach the scene a moment later; asking right away fails.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    windowScene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { error in
                        Log.playback.error("debug landscape: \(error.localizedDescription)")
                    }
                }
            }
            #endif
        }
    }
}
