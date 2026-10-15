import Foundation

/// A library on a media server: "Movies", "TV Shows", or Xtream's movies and series sections.
struct MediaLibrary: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movies
        case shows
        case mixed
    }

    var id: String
    var name: String
    var kind: Kind
}

/// A poster on a media server: something to play or something to open.
struct MediaItem: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case movie
        case series
        case episode
        case folder
        case video
    }

    var id: String
    var name: String
    var kind: Kind
    /// Year for movies, "S1 · E2" for episodes.
    var subtitle: String?
    /// Category for filtering (Xtream).
    var group: String?
    var imageURL: URL?

    var isPlayable: Bool {
        kind == .movie || kind == .episode || kind == .video
    }
}

/// Jellyfin, Emby, Plex and Xtream's on-demand sections behind one interface.
protocol MediaServer: Sendable {
    func libraries() async throws -> [MediaLibrary]
    func items(in library: MediaLibrary) async throws -> [MediaItem]
    func children(of item: MediaItem) async throws -> [MediaItem]
    /// Stream URL with credentials; built at play time so tokens never land in stored data.
    func playbackURL(itemID: String) -> URL?
}

enum MediaServerError: LocalizedError {
    case wrongCredentials
    case badResponse(Int)
    case invalidServer

    var errorDescription: String? {
        switch self {
        case .wrongCredentials:
            String(localized: "The username or password is wrong.")
        case .badResponse(let status):
            String(localized: "The server answered with an error (\(status)).")
        case .invalidServer:
            String(localized: "Enter the server address, for example http://192.168.1.10:8096")
        }
    }
}

/// App-internal URLs stored in favorites and recents instead of URLs that carry tokens:
/// `cariptv-item://<source>/<item>` resolves to a stream, `cariptv-image://<source>/<path>` to an image.
enum InternalURL {
    static let itemScheme = "cariptv-item"
    static let imageScheme = "cariptv-image"

    static func item(sourceID: UUID, itemID: String) -> URL {
        make(itemScheme, sourceID, itemID)
    }

    static func image(sourceID: UUID, path: String) -> URL {
        make(imageScheme, sourceID, path)
    }

    /// `(scheme, sourceID, value)` for an internal URL, `nil` for any other URL.
    static func parse(_ url: URL) -> (scheme: String, sourceID: UUID, value: String)? {
        guard let scheme = url.scheme, scheme == itemScheme || scheme == imageScheme,
              let host = url.host(), let sourceID = UUID(uuidString: host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "v" })?.value else { return nil }
        return (scheme, sourceID, value)
    }

    private static func make(_ scheme: String, _ sourceID: UUID, _ value: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = sourceID.uuidString
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "v", value: value)]
        return components.url!
    }
}

/// Identifies this installation to servers that track devices (Jellyfin, Emby, Plex).
enum ClientIdentity {
    static let product = "CarIPTV"

    static var deviceID: String {
        let key = "client.deviceID"
        if let saved = UserDefaults.standard.string(forKey: key) {
            return saved
        }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }
}

extension URL {
    /// Appends path components and query items without percent-encoding surprises.
    func adding(path: String, query: [String: String] = [:]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)!
        let base = components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path
        components.path = base + (path.hasPrefix("/") ? path : "/" + path)
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }
}
