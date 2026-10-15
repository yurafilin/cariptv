import Foundation

/// One playable entry of a source: a live channel from an M3U playlist or an Xtream account.
struct Channel: Codable, Hashable, Identifiable, Sendable {
    /// Unique within its source; stable across refreshes while the stream URL stays the same.
    var id: String
    var name: String
    var url: URL
    var group: String?
    var logo: URL?
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
    }

    var id: UUID
    var name: String
    var kind: Kind
    var channelCount: Int
    var updatedAt: Date

    var kindTitle: String {
        switch kind {
        case .m3uURL: String(localized: "M3U link")
        case .m3uFile: String(localized: "M3U file")
        case .xtream: String(localized: "Xtream Codes")
        }
    }

    var canRefresh: Bool {
        if case .m3uFile = kind { return false }
        return true
    }
}

/// A video file the user imported from Files or Photos, stored in the app container.
struct LocalVideo: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    var title: String
    var fileName: String
    var addedAt: Date
}

/// Anything the player can play: a channel, a local file, a stream cast from another app.
struct PlayableMedia: Hashable, Sendable {
    var title: String
    var subtitle: String?
    var url: URL
    var artwork: URL?
    var isLive: Bool
    /// Set for library channels, so the player can mark them recent and toggle favorites.
    var libraryItem: LibraryItem?

    init(title: String, subtitle: String? = nil, url: URL, artwork: URL? = nil, isLive: Bool, libraryItem: LibraryItem? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.artwork = artwork
        self.isLive = isLive
        self.libraryItem = libraryItem
    }

    init(_ item: LibraryItem) {
        self.init(
            title: item.channel.name,
            subtitle: item.channel.group,
            url: item.channel.url,
            artwork: item.channel.logo,
            isLive: true,
            libraryItem: item
        )
    }
}
