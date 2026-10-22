#if DEBUG
import Foundation

/// Debug-only: `-CarIPTVDebugSources http://127.0.0.1:8766` at launch adds an Xtream and a Jellyfin
/// source from that server (username `1`, password `2`) and its `/playlist.m3u` (with an XMLTV guide)
/// through the same calls the forms use. With no favorites yet, the M3U and Xtream channels become
/// favorites, so the CarPlay screen has something to play right away.
/// For checking against local mock servers in the Simulator, where typing Latin text is unreliable.
enum DebugSources {
    @MainActor
    static func addIfRequested() {
        guard let base = UserDefaults.standard.string(forKey: "CarIPTVDebugSources") else { return }
        let store = LibraryStore.shared
        Task {
            do {
                if !store.sources.contains(where: { if case .xtream = $0.kind { true } else { false } }) {
                    try await store.addXtream(server: base, username: "1", password: "2", name: "Mock Xtream")
                }
                if !store.sources.contains(where: { if case .mediaServer = $0.kind { true } else { false } }) {
                    try await store.addMediaServer(flavor: .jellyfin, server: base, username: "1", password: "2", name: nil)
                }
                if !store.sources.contains(where: { if case .m3uURL = $0.kind { true } else { false } }),
                   let playlist = URL(string: base + "/playlist.m3u") {
                    try await store.addM3U(url: playlist, name: "Mock M3U")
                }
                if store.favorites.isEmpty {
                    // Jellyfin has no channels of its own; M3U and Xtream live channels do.
                    for source in store.sources {
                        for channel in store.channels(in: source) {
                            store.toggleFavorite(LibraryItem(sourceID: source.id, channel: channel))
                        }
                    }
                }
                Log.playback.info("debug sources added from \(base)")
            } catch {
                Log.playback.error("debug sources failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
