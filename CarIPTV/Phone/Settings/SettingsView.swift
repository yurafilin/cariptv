import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Media") {
                    NavigationLink {
                        ManageSourcesView()
                    } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Manage Sources")
                                Text(verbatim: "M3U · Xtream · Jellyfin · Emby · Plex")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.tint)
                        }
                    }
                }

                Section("Legal") {
                    Link(destination: Links.privacyPolicy) {
                        LinkRow(title: "Privacy Policy")
                    }
                    .tint(.primary)
                    Link(destination: Links.termsOfUse) {
                        LinkRow(title: "Terms of Use (EULA)")
                    }
                    .tint(.primary)
                }

                Section("About") {
                    NavigationLink("Help & FAQ") {
                        HelpView()
                    }
                    LabeledContent("Version", value: Self.version)
                }
            }
            .navigationTitle("Settings")
            .miniPlayerInset()
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

enum Links {
    // TODO(owner): publish the privacy policy at cariptv.com/privacy before release.
    static let privacyPolicy = URL(string: "https://cariptv.com/privacy")!
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
}

private struct LinkRow: View {
    let title: LocalizedStringKey

    var body: some View {
        HStack {
            Text(title)
                .foregroundStyle(.primary)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct ManageSourcesView: View {
    @State private var refreshing: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        let store = LibraryStore.shared
        List {
            if store.sources.isEmpty {
                Text("No sources yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.sources) { source in
                HStack {
                    SourceRow(source: source)
                    Spacer()
                    if refreshing.contains(source.id) {
                        ProgressView()
                    }
                }
                .swipeActions {
                    Button(role: .destructive) {
                        store.delete(source)
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    if source.canRefresh {
                        Button {
                            refresh(source)
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
            Section {
                Button {
                    AppRouter.shared.isAddSourcePresented = true
                } label: {
                    Label("Add a Source", systemImage: "plus")
                }
            } footer: {
                Text("Swipe a source to refresh or remove it.")
            }
        }
        .navigationTitle("Sources")
        .alert("Couldn't refresh", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh(_ source: Source) {
        refreshing.insert(source.id)
        Task {
            defer { refreshing.remove(source.id) }
            do {
                try await LibraryStore.shared.refresh(source)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

struct HelpView: View {
    private struct Entry: Identifiable {
        let question: LocalizedStringKey
        let answer: LocalizedStringKey
        var id: String { "\(question)" }
    }

    private let entries: [Entry] = [
        Entry(
            question: "How do I watch on the car display?",
            answer: "Connect your iPhone to CarPlay and open CarIPTV on the car screen. Then pick a channel or video on your iPhone. It plays on the car display while the car is parked."
        ),
        Entry(
            question: "Why do I only hear sound?",
            answer: "Video shows only while the car is parked, in cars that support video in CarPlay, with iOS 26.4 or later. Otherwise CarIPTV keeps playing the sound."
        ),
        Entry(
            question: "Where do channels come from?",
            answer: "CarIPTV is a player and doesn't include any channels. Add M3U playlists or Xtream Codes accounts you have access to in Home → +."
        ),
        Entry(
            question: "Some channels don't play",
            answer: "CarIPTV plays HLS (.m3u8) and MP4 streams. Streams in other formats, or ones your provider allows on a single device at a time, may fail."
        ),
        Entry(
            question: "How does screen mirroring work?",
            answer: "Open Home → Mirror Screen, tap Start Screen Mirroring, then open any app. The picture runs a few seconds behind the sound, so for videos from websites use Watch in Car in the browser. Apps with protected video, such as paid streaming services, show a black screen."
        ),
    ]

    var body: some View {
        List(entries) { entry in
            DisclosureGroup {
                Text(entry.answer)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } label: {
                Text(entry.question)
            }
        }
        .navigationTitle("Help & FAQ")
    }
}
