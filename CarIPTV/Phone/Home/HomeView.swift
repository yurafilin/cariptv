import SwiftUI

/// Everything to start watching from: the browser and screen mirroring, recents, favorites and sources.
/// No title bar: the tab says where you are. The browser and mirroring work without any source, so
/// they stay on top. Channels are searched inside their source.
struct HomeView: View {
    enum Route: Hashable {
        case browser
        case mirror
        case favorites
    }

    @State private var path = NavigationPath()

    var body: some View {
        let store = LibraryStore.shared
        NavigationStack(path: $path) {
            library(store)
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .browser: BrowserView()
                    case .mirror: CastToScreenView()
                    case .favorites: FavoritesListView()
                    }
                }
                .miniPlayerInset()
        }
    }

    private func library(_ store: LibraryStore) -> some View {
        List {
            Section {
                shortcuts
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if !store.recent.isEmpty {
                Section("Recently played") {
                    ForEach(store.recent.prefix(5)) { item in
                        ChannelRow(item: item, queue: { store.recent })
                    }
                }
            }
            if !store.favorites.isEmpty {
                Section("Favorites") {
                    ForEach(store.favorites.prefix(Self.favoritesShown)) { item in
                        ChannelRow(item: item, queue: { store.favorites })
                    }
                    if store.favorites.count > Self.favoritesShown {
                        NavigationLink(value: Route.favorites) {
                            Text("All Favorites · \(store.favorites.count)")
                        }
                    }
                }
            }
            if store.sources.isEmpty {
                Section {
                    addSourceCard
                }
            } else {
                sources(store)
            }
        }
    }

    private static let favoritesShown = 5

    /// Ways to watch that need no source: the browser (YouTube and other sites) and the mirrored screen.
    private var shortcuts: some View {
        HStack(spacing: 10) {
            ShortcutTile(systemImage: "safari", title: "Browser") { path.append(Route.browser) }
            ShortcutTile(systemImage: "rectangle.on.rectangle", title: "Mirror Screen") { path.append(Route.mirror) }
        }
    }

    /// No source yet. The text must keep saying the app has no content of its own (App Review).
    private var addSourceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Add your channels", systemImage: "tray")
                .font(.headline)
            Text("Add an M3U playlist, or connect Xtream, Jellyfin, Emby or Plex to see your content here. CarIPTV doesn't include any channels.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button {
                AppRouter.shared.isAddSourcePresented = true
            } label: {
                Text("Add a Source")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.vertical, 8)
    }

    private func sources(_ store: LibraryStore) -> some View {
        Section("Sources") {
            ForEach(store.sources) { source in
                NavigationLink {
                    if source.hasMediaLibraries {
                        MediaSourceView(source: source)
                    } else {
                        SourceChannelsView(source: source)
                    }
                } label: {
                    SourceRow(source: source)
                }
            }
            Button {
                AppRouter.shared.isAddSourcePresented = true
            } label: {
                Label("Add a Source", systemImage: "plus")
            }
        }
    }
}

/// A large square entry on top of Home; the whole tile is the button.
private struct ShortcutTile: View {
    let systemImage: String
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                Text(title)
                    .font(.footnote.weight(.medium))
                    // The button would tint the label too: only the icon carries the accent.
                    .foregroundStyle(Color(.label))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, minHeight: 84)
            .padding(.horizontal, 6)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        // Three buttons in one list row: without this the row would fire all of them.
        .buttonStyle(.borderless)
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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        source.channelCount > 0
            ? "\(source.kindTitle) · \(Source.channelCountText(source.channelCount))"
            : source.kindTitle
    }

    private var icon: String {
        switch source.kind {
        case .m3uURL: "link"
        case .m3uFile: "doc.text"
        case .xtream: "antenna.radiowaves.left.and.right"
        case .mediaServer, .plex: "server.rack"
        }
    }
}
