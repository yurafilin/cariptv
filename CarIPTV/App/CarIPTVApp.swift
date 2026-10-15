import SwiftUI

@main
struct CarIPTVApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MirrorReceiver.shared.start()
    }

    var body: some Scene {
        WindowGroup {
            HomeView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                MirrorReceiver.shared.start()
            }
        }
    }
}
