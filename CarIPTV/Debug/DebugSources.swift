#if DEBUG
import Foundation

/// Debug-only: `-CarIPTVDebugSources http://127.0.0.1:8766` at launch adds an Xtream and a Jellyfin
/// source from that server (username `1`, password `2`) through the same calls the forms use.
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
                Log.playback.info("debug sources added from \(base)")
            } catch {
                Log.playback.error("debug sources failed: \(error.localizedDescription)")
            }
        }
    }
}
#endif
