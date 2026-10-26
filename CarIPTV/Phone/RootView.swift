import SwiftUI

struct RootView: View {
    @Bindable private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: AppRouter.Tab.home) {
                HomeView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppRouter.Tab.downloads) {
                DownloadsView()
            }
            Tab("Settings", systemImage: "gearshape", value: AppRouter.Tab.settings) {
                SettingsView()
            }
        }
        .fullScreenCover(isPresented: $router.isPlayerPresented) {
            PlayerView()
        }
        .sheet(isPresented: $router.isAddSourcePresented) {
            AddSourceView()
        }
    }
}

#Preview {
    RootView()
}
