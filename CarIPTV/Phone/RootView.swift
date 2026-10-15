import SwiftUI

struct RootView: View {
    @Bindable private var router = AppRouter.shared

    var body: some View {
        TabView(selection: $router.tab) {
            Tab("Home", systemImage: "house", value: AppRouter.Tab.home) {
                HomeView()
            }
            Tab("Favorites", systemImage: "heart", value: AppRouter.Tab.favorites) {
                FavoritesView()
            }
            Tab("Discover", systemImage: "safari", value: AppRouter.Tab.discover) {
                DiscoverView()
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
