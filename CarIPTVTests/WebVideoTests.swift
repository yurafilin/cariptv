import AVFoundation
import Foundation
import Testing
import WebKit
@testable import CarIPTV

struct WebVideoTests {
    @Test func readsAReportFromThePage() throws {
        let video = try #require(WebVideo(message: [
            "src": "https://cdn.example.com/v.mp4", "kind": "file", "title": "Cats - YouTube",
            "page": "https://m.youtube.com/watch?v=1", "poster": "https://cdn.example.com/p.jpg",
            "currentTime": 12.5, "duration": 60.0, "userAgent": "UA",
        ]))
        #expect(video.title == "Cats")
        #expect(video.canPlay)
        #expect(!video.isLive)
        #expect(video.currentTime == 12.5)
        #expect(video.userAgent == "UA")
    }

    @Test func protectedVideoIsShownButCannotPlay() throws {
        let video = try #require(WebVideo(message: ["src": NSNull(), "kind": "protected", "title": "Film | Example", "page": "https://example.com/f"]))
        #expect(!video.canPlay)
        #expect(video.url == nil)
        #expect(video.title == "Film")
    }

    @Test func unknownDurationMeansLive() throws {
        let video = try #require(WebVideo(message: ["src": "https://cdn.example.com/live.m3u8", "kind": "stream", "title": "", "page": "https://tv.example.com/"]))
        #expect(video.isLive)
        #expect(video.title == "tv.example.com")
    }

    @Test func titleKeepsDashesThatAreNotTheSiteName() {
        #expect(WebVideo.cleanTitle("Tom - Jerry", page: URL(string: "https://example.com/")) == "Tom - Jerry")
        #expect(WebVideo.cleanTitle("Tom - Jerry - Example", page: URL(string: "https://www.example.com/")) == "Tom - Jerry")
    }

    @Test func cookiesGoOnlyToTheirSite() throws {
        let url = URL(string: "https://rr1.cdn.example.com/video.mp4")!
        func cookie(_ domain: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [.domain: domain, .path: "/", .name: "n", .value: "v"]))
        }
        #expect(BrowserModel.cookie(try cookie(".example.com"), appliesTo: url))
        #expect(BrowserModel.cookie(try cookie("rr1.cdn.example.com"), appliesTo: url))
        #expect(!BrowserModel.cookie(try cookie("other.com"), appliesTo: url))
        #expect(!BrowserModel.cookie(try cookie("ample.com"), appliesTo: url))
    }

    @Test func requestCarriesUserAgentAndCookies() throws {
        let cookie = try #require(HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: "n", .value: "v"]))
        let options = WebRequest(userAgent: "UA", cookies: [cookie]).assetOptions
        #expect(options[AVURLAssetHTTPUserAgentKey] as? String == "UA")
        #expect((options[AVURLAssetHTTPCookiesKey] as? [HTTPCookie])?.count == 1)
        #expect(WebRequest(userAgent: nil).assetOptions.isEmpty)
    }
}

/// The page script itself, in a real web view. One page at a time: parallel web views starve each other.
@MainActor
@Suite(.serialized)
struct WebVideoScriptTests {
    /// `isLoading` is still false right after `loadHTMLString`; only the delegate knows the page is there.
    private final class Loader: NSObject, WKNavigationDelegate {
        var isFinished = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isFinished = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            isFinished = true
        }
    }

    private final class Recorder: NSObject, WKScriptMessageHandler {
        var reports: [WebVideo] = []

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            if let video = WebVideo(message: message.body) {
                reports.append(video)
            }
        }
    }

    private func page(_ body: String) async throws -> (WKWebView, Recorder, Loader) {
        let recorder = Recorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addUserScript(
            WKUserScript(source: WebVideo.script, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        )
        configuration.userContentController.add(recorder, name: WebVideo.messageName)
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480), configuration: configuration)
        let loader = Loader()
        webView.navigationDelegate = loader
        // Nothing on these pages loads from the network: the Simulator's DNS may hang behind a VPN.
        let head = "<title>Clip | Example</title><meta property='og:image' content='https://cdn.example.com/p.jpg'>"
        webView.loadHTMLString("<html><head>\(head)</head><body>\(body)</body></html>",
                               baseURL: URL(string: "https://example.com/watch"))
        try await waitUntil { loader.isFinished }
        return (webView, recorder, loader)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("timed out")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func play(_ webView: WKWebView, _ script: String = "") async throws {
        _ = try await webView.callAsyncJavaScript(
            script + "document.querySelector('video').dispatchEvent(new Event('playing'));",
            arguments: [:], in: nil, contentWorld: .page
        )
    }

    @Test func reportsAFileVideo() async throws {
        let (webView, recorder, _) = try await page("<video preload='none' src='https://cdn.example.com/clip.mp4'></video>")
        try await play(webView)
        try await waitUntil { !recorder.reports.isEmpty }
        let video = try #require(recorder.reports.first)
        #expect(video.kind == .file)
        #expect(video.url?.absoluteString == "https://cdn.example.com/clip.mp4")
        #expect(video.poster?.absoluteString == "https://cdn.example.com/p.jpg")
        #expect(video.title == "Clip")
        #expect(video.page?.absoluteString == "https://example.com/watch")
    }

    @Test func blobVideoUsesThePlaylistThePageFetched() async throws {
        let (webView, recorder, _) = try await page("<video></video>")
        try await play(webView, """
        fetch('https://cdn.example.com/live/index.m3u8?token=1').catch(() => {});
        document.querySelector('video').src = URL.createObjectURL(new Blob(['x']));
        """)
        try await waitUntil { !recorder.reports.isEmpty }
        let video = try #require(recorder.reports.first)
        #expect(video.kind == .stream)
        #expect(video.url?.absoluteString == "https://cdn.example.com/live/index.m3u8?token=1")
    }

    /// Sites see no MediaSource and fall back to addresses our player can open.
    @Test func pageSeesNoMediaSource() async throws {
        let (webView, _, _) = try await page("<video></video>")
        let visible = try await webView.callAsyncJavaScript(
            "return ['MediaSource', 'ManagedMediaSource'].filter((name) => name in window && window[name]).length;",
            arguments: [:], in: nil, contentWorld: .page
        )
        #expect(visible as? Int == 0)
    }

    @Test func blobVideoWithoutPlaylistIsProtected() async throws {
        let (webView, recorder, _) = try await page("<video></video>")
        try await play(webView, "document.querySelector('video').src = URL.createObjectURL(new Blob(['x']));")
        try await waitUntil { !recorder.reports.isEmpty }
        let video = try #require(recorder.reports.first)
        #expect(video.kind == .protected)
        #expect(!video.canPlay)
    }
}
