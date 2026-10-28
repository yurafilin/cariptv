import AVFoundation
import Foundation

/// One playable entry of a source: a live channel from an M3U playlist or an Xtream account.
struct Channel: Codable, Hashable, Identifiable, Sendable {
    /// Unique within its source; stable across refreshes while the stream URL stays the same.
    var id: String
    var name: String
    var url: URL
    var group: String?
    var logo: URL?
    /// `tvg-id` from the playlist: the channel's id in the XMLTV guide.
    var guideID: String? = nil
}

/// A channel together with its source: what favorites, recents and search results hold.
struct LibraryItem: Codable, Hashable, Identifiable, Sendable {
    var sourceID: UUID
    var channel: Channel

    var id: String { "\(sourceID.uuidString)/\(channel.id)" }
}

/// Where channels come from. The library never ships content of its own.
struct Source: Codable, Hashable, Identifiable, Sendable {
    enum Kind: Codable, Hashable, Sendable {
        case m3uURL(URL)
        /// Imported once; the original file is not kept.
        case m3uFile(fileName: String)
        /// Password lives in the Keychain under the source id.
        case xtream(server: URL, username: String)
        /// Jellyfin or Emby; the access token lives in the Keychain under the source id.
        case mediaServer(flavor: JellyfinClient.Flavor, server: URL, userID: String)
        /// Plex server; the server token lives in the Keychain under the source id.
        case plex(serverID: String, connections: [URL])
    }

    var id: UUID
    var name: String
    var kind: Kind
    var channelCount: Int
    var updatedAt: Date
    /// XMLTV guide the user entered for an M3U source; wins over the playlist's own.
    var guideURL: URL? = nil
    /// XMLTV guide named in the playlist header (`url-tvg`, `x-tvg-url`); updated on refresh.
    var playlistGuideURL: URL? = nil

    /// Where the programme guide of an M3U source comes from, if anywhere.
    var effectiveGuideURL: URL? { guideURL ?? playlistGuideURL }

    var kindTitle: String {
        switch kind {
        case .m3uURL: String(localized: "M3U link")
        case .m3uFile: String(localized: "M3U file")
        case .xtream: String(localized: "Xtream Codes")
        case .mediaServer(let flavor, _, _): flavor.title
        case .plex: "Plex"
        }
    }

    /// M3U links and Xtream re-download their channel lists; servers are browsed live.
    var canRefresh: Bool {
        switch kind {
        case .m3uURL, .xtream: true
        case .m3uFile, .mediaServer, .plex: false
        }
    }

    /// "1 channel", "12 channels".
    static func channelCountText(_ count: Int) -> String {
        String(AttributedString(localized: "^[\(count) channel](inflect: true)").characters)
    }

    /// Has posters to browse: Xtream movies and series, Jellyfin, Emby, Plex.
    var hasMediaLibraries: Bool {
        switch kind {
        case .xtream, .mediaServer, .plex: true
        case .m3uURL, .m3uFile: false
        }
    }
}

/// A video file the user imported from Files or Photos, stored in the app container.
struct LocalVideo: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var fileName: String
    var addedAt: Date
}

/// Anything the player can play: a channel, a local file, a stream cast from another app,
/// a video taken from a web page.
struct PlayableMedia: Hashable, Sendable {
    var title: String
    var subtitle: String?
    var url: URL
    var artwork: URL?
    var isLive: Bool
    /// Set for library channels, so the player can mark them recent and toggle favorites.
    var libraryItem: LibraryItem?
    /// Seconds to start from: a web video continues where it was on the page.
    var startTime: Double?
    /// A web video is requested the way the page requested it.
    var web: WebRequest?
    /// The mirrored iPhone screen: plays close to live, alongside the source app's own sound.
    var isScreen: Bool

    init(title: String, subtitle: String? = nil, url: URL, artwork: URL? = nil, isLive: Bool, libraryItem: LibraryItem? = nil,
         startTime: Double? = nil, web: WebRequest? = nil, isScreen: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.artwork = artwork
        self.isLive = isLive
        self.libraryItem = libraryItem
        self.startTime = startTime
        self.web = web
        self.isScreen = isScreen
    }

    init(_ item: MediaItem, sourceID: UUID, group: String?) {
        self.init(LibraryItem(item, sourceID: sourceID, group: group))
    }

    init(_ item: LibraryItem) {
        self.init(
            title: item.channel.name,
            subtitle: item.channel.group,
            url: item.channel.url,
            artwork: item.channel.logo,
            // Server posters are films and episodes; playlist channels are live.
            isLive: InternalURL.parse(item.channel.url) == nil,
            libraryItem: item
        )
    }
}

/// How a page's video is fetched outside the page: many sites serve it only to their own browser
/// and its cookies.
struct WebRequest: Hashable, Sendable {
    var userAgent: String?
    var cookies: [HTTPCookie] = []

    var assetOptions: [String: Any] {
        var options: [String: Any] = [:]
        if let userAgent {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        if !cookies.isEmpty {
            options[AVURLAssetHTTPCookiesKey] = cookies
        }
        return options
    }
}

extension LibraryItem {
    /// Films and episodes from servers, as opposed to live channels from playlists.
    var isPoster: Bool { InternalURL.parse(channel.url) != nil }

    /// A server poster as a library entry; its URL is internal and resolves to a stream at play time.
    init(_ item: MediaItem, sourceID: UUID, group: String?) {
        self.init(
            sourceID: sourceID,
            channel: Channel(
                id: "item:\(item.id)",
                name: item.name,
                url: InternalURL.item(sourceID: sourceID, itemID: item.id),
                group: [group, item.subtitle].compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
                logo: item.imageURL
            )
        )
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
