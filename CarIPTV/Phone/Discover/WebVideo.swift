import Foundation
import WebKit

/// A video playing on a web page, found by `WebVideo.script`.
struct WebVideo: Equatable {
    enum Kind: String {
        /// A file the page plays directly (MP4 and the like).
        case file
        /// An HLS playlist.
        case stream
        /// Played through MediaSource from data the page assembles itself: there is no address to hand over.
        case protected
    }

    var url: URL?
    var kind: Kind
    var title: String
    var poster: URL?
    var page: URL?
    var currentTime: Double
    var isLive: Bool
    var userAgent: String?

    var canPlay: Bool { url != nil && kind != .protected }

    /// Reads a message posted by `script`.
    init?(message body: Any) {
        guard let body = body as? [String: Any], let kind = (body["kind"] as? String).flatMap(Kind.init) else { return nil }
        self.kind = kind
        url = (body["src"] as? String).flatMap(URL.init(string:))
        page = (body["page"] as? String).flatMap(URL.init(string:))
        poster = (body["poster"] as? String).flatMap(URL.init(string:))
        title = Self.cleanTitle(body["title"] as? String ?? "", page: page)
        currentTime = body["currentTime"] as? Double ?? 0
        let duration = body["duration"] as? Double
        isLive = duration == nil || duration?.isInfinite == true
        userAgent = body["userAgent"] as? String
    }

    /// "Some video - YouTube" → "Some video".
    static func cleanTitle(_ title: String, page: URL?) -> String {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        for separator in [" - ", " | ", " — "] {
            if let range = title.range(of: separator, options: .backwards),
               let host = page?.host()?.lowercased(),
               host.contains(title[range.upperBound...].lowercased().filter { !$0.isWhitespace }) {
                title = String(title[..<range.lowerBound])
            }
        }
        if title.isEmpty {
            title = page?.host() ?? String(localized: "Web video")
        }
        return title
    }

    static let messageName = "cariptvVideo"

    /// Watches every `<video>` in every frame and reports the one that starts playing.
    ///
    /// MediaSource is hidden before the page's own scripts run: with it, sites assemble video from
    /// pieces (`blob:`) and there is no address to hand over; without it they fall back to a plain
    /// file or native HLS, as on iPhone Safari before iOS 17.1. Pages that still feed a `blob:`
    /// from an HLS playlist are caught by remembering the last `.m3u8` they fetched.
    static let script = """
    (() => {
      if (window.__cariptvVideo) return;
      window.__cariptvVideo = true;
      for (const name of ['MediaSource', 'ManagedMediaSource', 'WebKitMediaSource']) {
        try { delete window[name]; } catch (e) {}
        try { if (name in window) Object.defineProperty(window, name, { value: undefined, configurable: true }); } catch (e) {}
      }
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(messageName);
      if (!handler) return;

      let lastPlaylist = null;
      const note = (value) => {
        try {
          const text = String(value && value.url ? value.url : value);
          if (/\\.m3u8(\\?|#|$)/i.test(text)) lastPlaylist = new URL(text, location.href).href;
        } catch (e) {}
      };
      const originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input) { note(input); return originalFetch.apply(this, arguments); };
      }
      const originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) { note(url); return originalOpen.apply(this, arguments); };

      const meta = (name) => {
        const element = document.querySelector('meta[property="' + name + '"], meta[name="' + name + '"]');
        return element ? element.content : null;
      };
      const report = (video) => {
        let src = video.currentSrc || video.src || '';
        if (!src) {
          const source = video.querySelector('source[src]');
          if (source) src = source.src;
        }
        let kind = /\\.m3u8(\\?|#|$)/i.test(src) ? 'stream' : 'file';
        if (/^(blob|mediasource):/i.test(src)) {
          if (lastPlaylist) { src = lastPlaylist; kind = 'stream'; } else { src = null; kind = 'protected'; }
        } else if (!/^https?:/i.test(src)) {
          return;
        }
        handler.postMessage({
          src: src,
          kind: kind,
          title: document.title || meta('og:title') || '',
          poster: video.poster || meta('og:image') || null,
          page: location.href,
          duration: isFinite(video.duration) ? video.duration : null,
          currentTime: video.currentTime || 0,
          userAgent: navigator.userAgent
        });
      };
      // Media events do not bubble; the capture phase still sees them on the document.
      document.addEventListener('playing', (event) => {
        if (event.target instanceof HTMLVideoElement) report(event.target);
      }, true);
      window.__cariptvPauseVideos = () => document.querySelectorAll('video').forEach((video) => video.pause());
    })();
    """
}

/// Forwards the script's reports to `BrowserModel`; WebKit keeps message handlers strongly.
final class WebVideoMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let video = WebVideo(message: message.body) else { return }
        let frame = message.frameInfo
        MainActor.assumeIsolated {
            BrowserModel.shared.found(video, in: frame)
        }
    }
}
