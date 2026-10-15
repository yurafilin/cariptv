import Observation

/// App-wide navigation state the tabs share: selected tab, the player and the add-source sheet.
@MainActor @Observable
final class AppRouter {
    static let shared = AppRouter()

    enum Tab: Hashable {
        case home
        case favorites
        case discover
        case settings
    }

    var tab: Tab = .home
    var isPlayerPresented = false
    var isAddSourcePresented = false

    private init() {}

    func play(_ media: PlayableMedia) {
        PlaybackController.shared.play(media)
        isPlayerPresented = true
    }

    func play(_ item: LibraryItem) {
        play(PlayableMedia(item))
    }
}
