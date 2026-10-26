import SwiftUI

/// Every favorite channel; Home shows the first few.
struct FavoritesListView: View {
    var body: some View {
        let store = LibraryStore.shared
        Group {
            if store.favorites.isEmpty {
                EmptyStateView(
                    systemImage: "heart",
                    title: "Nothing saved yet",
                    message: "Touch and hold any channel to keep it here. Favorites also appear on the car display."
                )
            } else {
                List(store.favorites) { item in
                    ChannelRow(item: item, queue: { store.favorites })
                }
            }
        }
        .navigationTitle("Favorites")
        .miniPlayerInset()
    }
}
