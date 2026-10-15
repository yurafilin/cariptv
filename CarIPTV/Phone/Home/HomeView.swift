import SwiftUI

/// Sources and their channels, recents, and search across everything.
struct HomeView: View {
    @State private var query = ""

    var body: some View {
        let store = LibraryStore.shared
        NavigationStack {
            Group {
                if !query.isEmpty {
                    searchResults(store.search(query))
                } else if store.sources.isEmpty {
                    EmptyStateView(
                        systemImage: "tray",
                        title: "Your library is empty",
                        message: "Add an M3U playlist or an Xtream account to see your channels here. CarIPTV doesn't include any channels.",
                        actionTitle: "Add a Source",
                        action: { AppRouter.shared.isAddSourcePresented = true }
                    )
                } else {
                    library(store)
                }
            }
            .navigationTitle("Home")
            .searchable(text: $query, prompt: "Search channels")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        AppRouter.shared.isAddSourcePresented = true
                    } label: {
                        Label("Add a Source", systemImage: "plus")
                    }
                }
            }
            .miniPlayerInset()
        }
    }

    private func library(_ store: LibraryStore) -> some View {
        List {
            if !store.recent.isEmpty {
                Section("Recently played") {
                    ForEach(store.recent.prefix(5)) { item in
                        ChannelRow(item: item)
                    }
                }
            }
            Section("Sources") {
                ForEach(store.sources) { source in
                    NavigationLink {
                        SourceChannelsView(source: source)
                    } label: {
                        SourceRow(source: source)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func searchResults(_ results: [LibraryItem]) -> some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            List(results) { item in
                ChannelRow(item: item)
            }
        }
    }
}

struct SourceRow: View {
    let source: Source

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                    .lineLimit(1)
                Text("\(source.kindTitle) · \(source.channelCount) channels")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var icon: String {
        switch source.kind {
        case .m3uURL: "link"
        case .m3uFile: "doc.text"
        case .xtream: "antenna.radiowaves.left.and.right"
        }
    }
}
