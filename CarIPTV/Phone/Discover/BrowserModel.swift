import Foundation
import Observation
import WebKit

struct Bookmark: Codable, Hashable, Identifiable {
    var title: String
    var url: URL

    var id: URL { url }
}

/// One web view kept for the session, its navigation state, the video playing on the page and
/// the user's saved sites.
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
    /// The video that started playing on the current page; offered for the car display.
    private(set) var video: WebVideo?

    @ObservationIgnored private var videoFrame: WKFrameInfo?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private static let bookmarksKey = "browser.bookmarks"

    private init() {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: WebVideo.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        controller.add(WebVideoMessageHandler(), name: WebVideo.messageName)
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true

        bookmarks = UserDefaults.standard.data(forKey: Self.bookmarksKey)
            .flatMap { try? JSONDecoder().decode([Bookmark].self, from: $0) } ?? []

        observations = [
            webView.observe(\.url) { webView, _ in
                let value = webView.url
                Task { @MainActor in BrowserModel.shared.pageChanged(to: value) }
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

    // MARK: - Video

    private func pageChanged(to url: URL?) {
        if url != self.url {
            video = nil
            videoFrame = nil
        }
        self.url = url
    }

    func found(_ video: WebVideo, in frame: WKFrameInfo) {
        Log.playback.info("browser: \(video.kind.rawValue, privacy: .public) video on \(video.page?.host() ?? "?", privacy: .public)")
        // A protected video in an ad or preview must not hide a playable one found earlier.
        if !video.canPlay, self.video?.canPlay == true { return }
        self.video = video
        videoFrame = frame
    }

    /// Hands the page's video to our player: the page pauses, the player continues from the same
    /// moment, and the car shows it like any channel.
    func playVideo() async {
        guard let video, video.canPlay, let url = video.url else { return }
        _ = try? await webView.callAsyncJavaScript(
            "if (window.__cariptvPauseVideos) window.__cariptvPauseVideos();",
            arguments: [:], in: videoFrame, contentWorld: .page
        )
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let media = PlayableMedia(
            title: video.title,
            subtitle: video.page?.host(),
            url: url,
            artwork: video.poster,
            isLive: video.isLive,
            startTime: video.isLive ? nil : video.currentTime,
            web: WebRequest(userAgent: video.userAgent, cookies: cookies.filter { Self.cookie($0, appliesTo: url) })
        )
        AppRouter.shared.play(media)
    }

    nonisolated static func cookie(_ cookie: HTTPCookie, appliesTo url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        let domain = cookie.domain.lowercased().trimmingPrefix(".")
        return host == domain || host.hasSuffix("." + domain)
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

    /// A site the user typed in: named after its domain unless they gave a name.
    func addBookmark(url: URL, title: String) {
        // Already on the start page, suggested or added before.
        guard !(bookmarks + Self.suggestedSites).contains(where: { $0.url == url }) else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(Bookmark(title: name.isEmpty ? Self.siteName(url) : name, url: url))
        saveBookmarks()
    }

    /// "www.example.com" → "example.com".
    nonisolated static func siteName(_ url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
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

    /// A website address only — `url(from:)` would turn anything else into a search.
    nonisolated static func siteURL(from input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        let candidate = text.contains("://") ? text : "https://\(text)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(), host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        return url
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
