import Foundation
import Observation
import WebKit

struct Bookmark: Codable, Hashable, Identifiable {
    var title: String
    var url: URL

    var id: URL { url }
}

/// One web view kept for the session, its navigation state and the user's saved sites.
@MainActor @Observable
final class BrowserModel {
    static let shared = BrowserModel()

    static let suggestedSites: [Bookmark] = [
        ("Google", "https://www.google.com"),
        ("YouTube", "https://m.youtube.com"),
        ("Twitch", "https://m.twitch.tv"),
        ("Vimeo", "https://vimeo.com"),
        ("Dailymotion", "https://www.dailymotion.com"),
        ("TikTok", "https://www.tiktok.com"),
        ("Pluto TV", "https://pluto.tv"),
        ("Tubi", "https://tubitv.com"),
        ("Plex", "https://watch.plex.tv"),
        ("Crunchyroll", "https://www.crunchyroll.com"),
        ("Rakuten Viki", "https://www.viki.com"),
        ("Bilibili", "https://m.bilibili.com"),
    ].map { Bookmark(title: $0.0, url: URL(string: $0.1)!) }

    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title: String?
    private(set) var canGoBack = false
    private(set) var isLoading = false
    private(set) var progress = 0.0
    var isShowingHome = true
    private(set) var bookmarks: [Bookmark]

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private static let bookmarksKey = "browser.bookmarks"

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        bookmarks = UserDefaults.standard.data(forKey: Self.bookmarksKey)
            .flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []

        observations = [
            webView.observe(\.url) { webView, _ in
                let value = webView.url
                Task { @MainActor in BrowserModel.shared.url = value }
            },
            webView.observe(\.title) { webView, _ in
                let value = webView.title
                Task { @MainActor in BrowserModel.shared.title = value }
            },
            webView.observe(\.canGoBack) { webView, _ in
                let value = webView.canGoBack
                Task { @MainActor in BrowserModel.shared.canGoBack = value }
            },
            webView.observe(\.isLoading) { webView, _ in
                let value = webView.isLoading
                Task { @MainActor in BrowserModel.shared.isLoading = value }
            },
            webView.observe(\.estimatedProgress) { webView, _ in
                let value = webView.estimatedProgress
                Task { @MainActor in BrowserModel.shared.progress = value }
            },
        ]
    }

    /// A URL as typed, a bare domain, or a search query.
    func open(_ input: String) {
        guard let url = Self.url(from: input) else { return }
        open(url)
    }

    func open(_ url: URL) {
        isShowingHome = false
        webView.load(URLRequest(url: url))
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        } else {
            isShowingHome = true
        }
    }

    func reload() {
        webView.reload()
    }

    var isCurrentPageBookmarked: Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmark() {
        guard let url else { return }
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            bookmarks.append(Bookmark(title: title?.isEmpty == false ? title! : (url.host() ?? url.absoluteString), url: url))
        }
        saveBookmarks()
    }

    func remove(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
        }
    }

    nonisolated static func url(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.contains("://"), let url = URL(string: text), url.host() != nil {
            return url
        }
        if !text.contains(" "), text.contains("."), let url = URL(string: "https://\(text)"), url.host() != nil {
            return url
        }
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        return components.url
    }
}
