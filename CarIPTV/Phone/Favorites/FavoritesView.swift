import SwiftUI

/// Favorite channels and videos imported from Files or Photos.
struct FavoritesView: View {
    enum Segment: Hashable {
        case favorites
        case local
    }

    @State private var segment: Segment = .favorites

    var body: some View {
        let store = LibraryStore.shared
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $segment) {
                    Text("Favorites").tag(Segment.favorites)
                    Text("Local · \(store.localVideos.count)").tag(Segment.local)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                switch segment {
                case .favorites:
                    favorites(store)
                case .local:
                    LocalVideosList()
                }
            }
            .navigationTitle("Favorites")
            .miniPlayerInset()
        }
    }

    @ViewBuilder
    private func favorites(_ store: LibraryStore) -> some View {
        if store.favorites.isEmpty {
            EmptyStateView(
                systemImage: "heart",
                title: "Nothing saved yet",
                message: "Touch and hold any channel to keep it here. Favorites also appear on the car display.",
                actionTitle: "Go to Home",
                action: { AppRouter.shared.tab = .home }
            )
        } else {
            List(store.favorites) { item in
                ChannelRow(item: item, queue: { store.favorites })
            }
        }
    }
}

/// Imported videos plus the import actions.
struct LocalVideosList: View {
    var body: some View {
        let store = LibraryStore.shared
        List {
            Section {
                LocalVideoImportRows()
            } footer: {
                if store.localVideos.isEmpty {
                    Text("Videos you add are copied into CarIPTV and play on the car display like channels.")
                }
            }
            if !store.localVideos.isEmpty {
                Section("Videos") {
                    ForEach(store.localVideos) { video in
                        Button {
                            AppRouter.shared.play(PlayableMedia(title: video.title, url: store.url(for: video), isLive: false))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "film")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                                    .frame(width: 32)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(video.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(video.addedAt, format: .dateTime.day().month().year())
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) {
                                store.delete(video)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }
}
