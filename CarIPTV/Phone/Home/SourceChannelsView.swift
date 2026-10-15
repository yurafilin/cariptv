import SwiftUI

/// Channels of one source, filtered by group and search.
struct SourceChannelsView: View {
    let source: Source

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var group: String?
    @State private var groups: [String] = []
    @State private var isRefreshing = false
    @State private var errorMessage: String?
    @State private var isConfirmingDelete = false

    var body: some View {
        let store = LibraryStore.shared
        // `source` is the value the list was opened with; a refresh replaces it in the store.
        let current = store.sources.first { $0.id == source.id } ?? source
        let channels = store.channels(in: source)
        let filtered = channels.filter { channel in
            (group == nil || channel.group == group) && (query.isEmpty || LibraryStore.matches(channel, query))
        }

        List {
            if groups.count > 1 {
                Section {
                    groupPicker
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
            }
            Section {
                ForEach(filtered) { channel in
                    ChannelRow(item: LibraryItem(sourceID: source.id, channel: channel))
                }
            }
        }
        .overlay {
            if store.channels[source.id] == nil {
                ProgressView()
            } else if filtered.isEmpty, !query.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .navigationTitle(current.name)
        .searchable(text: $query, prompt: "Search channels")
        // Channels arrive from disk after launch and change on refresh, possibly keeping their count.
        .task(id: "\(current.updatedAt.timeIntervalSince1970)/\(channels.count)") {
            groups = Self.groups(channels)
            if let group, !groups.contains(group) {
                self.group = nil
            }
        }
        .refreshable {
            await refresh()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if source.canRefresh {
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .disabled(isRefreshing)
                    }
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
        .confirmationDialog("Remove \(source.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                LibraryStore.shared.delete(source)
                dismiss()
            }
        } message: {
            Text("Its channels also leave Favorites and Recent.")
        }
        .alert("Couldn't refresh", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .miniPlayerInset()
    }

    private var groupPicker: some View {
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
        let isSelected = group == value
        return Button {
            group = value
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

    private func refresh() async {
        guard source.canRefresh, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            try await LibraryStore.shared.refresh(source)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Groups in playlist order.
    private static func groups(_ channels: [Channel]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for channel in channels {
            if let group = channel.group, seen.insert(group).inserted {
                ordered.append(group)
            }
        }
        return ordered
    }
}
