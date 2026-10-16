import SwiftUI

/// Libraries of a media server source; for Xtream also the live channel list.
struct MediaSourceView: View {
    let source: Source

    @Environment(\.dismiss) private var dismiss
    @State private var libraries: [MediaLibrary] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    var body: some View {
        let store = LibraryStore.shared
        let current = store.sources.first { $0.id == source.id } ?? source
        List {
            if case .xtream = current.kind {
                Section {
                    NavigationLink {
                        SourceChannelsView(source: current)
                    } label: {
                        Label("Live TV · \(Source.channelCountText(current.channelCount))", systemImage: "dot.radiowaves.left.and.right")
                    }
                }
            }
            if !libraries.isEmpty {
                Section("Libraries") {
                    ForEach(libraries) { library in
                        NavigationLink {
                            MediaItemsView(source: current, title: library.name, content: .library(library))
                        } label: {
                            Label(library.name, systemImage: Self.icon(library.kind))
                        }
                    }
                }
            }
        }
        .overlay {
            if isLoading, libraries.isEmpty {
                ProgressView()
            } else if let errorMessage, libraries.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load the server", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            }
        }
        .navigationTitle(current.name)
        .task { await load() }
        .refreshable { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Remove Source", systemImage: "trash")
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
            }
        }
        .confirmationDialog("Remove \(current.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                LibraryStore.shared.delete(current)
                dismiss()
            }
        } message: {
            Text("Its items also leave Favorites and Recent.")
        }
        .miniPlayerInset()
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let store = LibraryStore.shared
        await store.preparePlex(source)
        guard let server = store.mediaServer(for: source) else {
            errorMessage = String(localized: "The sign-in for this source is missing. Remove it and add it again.")
            return
        }
        do {
            libraries = try await server.libraries()
            errorMessage = libraries.isEmpty ? String(localized: "This server has no movie or TV libraries.") : nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static func icon(_ kind: MediaLibrary.Kind) -> String {
        switch kind {
        case .movies: "film"
        case .shows: "tv"
        case .mixed: "folder"
        }
    }
}

/// Posters of a library, or the episodes and items inside a series or folder.
struct MediaItemsView: View {
    enum Content: Hashable {
        case library(MediaLibrary)
        case children(MediaItem)
    }

    let source: Source
    let title: String
    let content: Content

    @State private var items: [MediaItem] = []
    @State private var groups: [String] = []
    @State private var group: String?
    @State private var query = ""
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        let filtered = items.filter { item in
            (group == nil || item.group == group) && (query.isEmpty || item.name.localizedStandardContains(query))
        }
        Group {
            if case .children = content {
                episodeList(filtered)
            } else {
                posterGrid(filtered)
            }
        }
        .overlay {
            if isLoading, items.isEmpty {
                ProgressView()
            } else if let errorMessage, items.isEmpty {
                ContentUnavailableView {
                    Label("Couldn't load", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                }
            } else if !isLoading, items.isEmpty {
                ContentUnavailableView("Nothing here", systemImage: "film")
            } else if filtered.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(title)
        .searchable(text: $query, prompt: "Search")
        .task { await load() }
        .miniPlayerInset()
    }

    private func posterGrid(_ items: [MediaItem]) -> some View {
        ScrollView {
            if groups.count > 1 {
                GroupChips(groups: groups, selection: $group)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12, alignment: .top)], spacing: 16) {
                ForEach(items) { item in
                    cell(for: item) {
                        PosterCell(item: item, isFavorite: isFavorite(item))
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func episodeList(_ items: [MediaItem]) -> some View {
        List(items) { item in
            cell(for: item) {
                EpisodeRow(item: item, isFavorite: isFavorite(item))
            }
        }
    }

    /// Plays playable items; opens series and folders.
    @ViewBuilder
    private func cell<CellLabel: View>(for item: MediaItem, @ViewBuilder label: () -> CellLabel) -> some View {
        if item.isPlayable {
            Button {
                AppRouter.shared.play(PlayableMedia(item, sourceID: source.id, group: groupName(for: item)), queue: episodeQueue)
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .contextMenu {
                let libraryItem = LibraryItem(item, sourceID: source.id, group: groupName(for: item))
                let isFavorite = LibraryStore.shared.isFavorite(libraryItem)
                Button {
                    LibraryStore.shared.toggleFavorite(libraryItem)
                } label: {
                    Label(isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: isFavorite ? "heart.slash" : "heart")
                }
            }
        } else {
            NavigationLink {
                MediaItemsView(source: source, title: item.name, content: .children(item))
            } label: {
                label()
            }
            .buttonStyle(.plain)
        }
    }

    /// Episodes step to the next episode; movies in a library stand alone.
    private var episodeQueue: [LibraryItem] {
        guard case .children = content else { return [] }
        return items.filter(\.isPlayable).map { LibraryItem($0, sourceID: source.id, group: groupName(for: $0)) }
    }

    /// Episodes are grouped under their series name; movies under their category.
    private func groupName(for item: MediaItem) -> String? {
        switch content {
        case .children(let parent): parent.name
        case .library: item.group
        }
    }

    private func isFavorite(_ item: MediaItem) -> Bool {
        item.isPlayable && LibraryStore.shared.isFavorite(LibraryItem(item, sourceID: source.id, group: groupName(for: item)))
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        let store = LibraryStore.shared
        await store.preparePlex(source)
        guard let server = store.mediaServer(for: source) else { return }
        do {
            switch content {
            case .library(let library):
                items = try await server.items(in: library)
            case .children(let parent):
                items = try await server.children(of: parent)
            }
            var seen = Set<String>()
            groups = items.compactMap(\.group).filter { seen.insert($0).inserted }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct PosterCell: View {
    let item: MediaItem
    let isFavorite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    AsyncImage(url: item.imageURL.map(LibraryStore.shared.resolvedURL)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: item.kind == .series ? "tv" : "film")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topTrailing) {
                    if isFavorite {
                        Image(systemName: "heart.fill")
                            .foregroundStyle(.tint)
                            .padding(6)
                            .background(.ultraThinMaterial, in: Circle())
                            .padding(6)
                    }
                }
            Text(item.name)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            if let subtitle = item.subtitle {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

private struct EpisodeRow: View {
    let item: MediaItem
    let isFavorite: Bool

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .frame(width: 112, height: 63)
                .overlay {
                    AsyncImage(url: item.imageURL.map(LibraryStore.shared.resolvedURL)) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: item.isPlayable ? "play.rectangle" : "folder")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if isFavorite {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Horizontal capsule filter: "All" plus one chip per group.
struct GroupChips: View {
    let groups: [String]
    @Binding var selection: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(String(localized: "All"), value: nil)
                ForEach(groups, id: \.self) { name in
                    chip(name, value: name)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }

    private func chip(_ title: String, value: String?) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(isSelected ? Color.black : Color.primary)
                .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
