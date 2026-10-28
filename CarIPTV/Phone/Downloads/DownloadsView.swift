import SwiftUI

/// What plays without a network: videos imported from Files or Photos (and, later, films downloaded
/// from the user's servers). The car shows the same list in its Videos tab.
struct DownloadsView: View {
    var body: some View {
        NavigationStack {
            // No title bar, as on Home: the tab says where you are.
            LocalVideosList()
                .navigationTitle("Downloads")
                .toolbar(.hidden, for: .navigationBar)
                .miniPlayerInset()
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
