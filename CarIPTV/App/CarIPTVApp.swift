import SwiftUI

@main
struct CarIPTVApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        MirrorReceiver.shared.start()
        #if DEBUG
        DebugSources.addIfRequested()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                MirrorReceiver.shared.start()
            }
        }
    }
}
