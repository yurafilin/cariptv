import Foundation

/// Plex: sign-in with a code on plex.tv/link, server discovery, libraries and HLS playback.
struct PlexClient: MediaServer {
    struct Server: Identifiable, Hashable, Sendable {
        var id: String
        var name: String
        var accessToken: String
        /// Ordered: local, remote, relay.
        var connections: [URL]
    }

    struct Pin: Sendable {
        var id: Int
        var code: String
    }

    static let linkURL = URL(string: "https://plex.tv/link")!
    private static let plexTV = URL(string: "https://plex.tv/api/v2")!

    let sourceID: UUID
    let connections: [URL]
    let token: String
    /// Which connection answered last; picked again for streams.
    let preferred: URL?

    var base: URL? { preferred ?? connections.first }

    // MARK: - Sign-in

    static func createPin() async throws -> Pin {
        var request = URLRequest(url: plexTV.adding(path: "/pins", query: ["strong": "false"]), timeoutInterval: 20)
        request.httpMethod = "POST"
        addHeaders(&request, token: nil)
        let pin: PinDTO = try await send(request)
        return Pin(id: pin.id, code: pin.code)
    }

    /// The account token once the user entered the code on plex.tv/link, otherwise `nil`.
    static func checkPin(_ pin: Pin) async throws -> String? {
        var request = URLRequest(url: plexTV.adding(path: "/pins/\(pin.id)"), timeoutInterval: 20)
        addHeaders(&request, token: nil)
        let result: PinDTO = try await send(request)
        return result.authToken.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func servers(accountToken: String) async throws -> [Server] {
        var request = URLRequest(url: plexTV.adding(path: "/resources", query: ["includeHttps": "1", "includeRelay": "1"]), timeoutInterval: 20)
        addHeaders(&request, token: accountToken)
        let resources: [ResourceDTO] = try await send(request)
        return servers(from: resources)
    }

    static func servers(from resources: [ResourceDTO]) -> [Server] {
        resources
            .filter { $0.provides.split(separator: ",").contains("server") }
            .compactMap { resource in
                let ordered = resource.connections.sorted { rank($0) < rank($1) }.compactMap { URL(string: $0.uri) }
                guard !ordered.isEmpty else { return nil }
                return Server(
                    id: resource.clientIdentifier,
                    name: resource.name,
                    accessToken: resource.accessToken ?? "",
                    connections: ordered
                )
            }
    }

    private static func rank(_ connection: ResourceDTO.Connection) -> Int {
        if connection.relay == true { return 2 }
        return connection.local == true ? 0 : 1
    }

    /// The first connection that answers within a few seconds.
    static func reachableConnection(_ connections: [URL], token: String) async -> URL? {
        for url in connections {
            var request = URLRequest(url: url.adding(path: "/identity"), timeoutInterval: 4)
            addHeaders(&request, token: token)
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return url
            }
        }
        return nil
    }

    // MARK: - MediaServer

    func libraries() async throws -> [MediaLibrary] {
        let result: ContainerDTO = try await get("/library/sections")
        return (result.mediaContainer.directory ?? []).compactMap { directory in
            switch directory.type {
            case "movie": MediaLibrary(id: directory.key, name: directory.title, kind: .movies)
            case "show": MediaLibrary(id: directory.key, name: directory.title, kind: .shows)
            default: nil
            }
        }
    }

    func items(in library: MediaLibrary) async throws -> [MediaItem] {
        let result: ContainerDTO = try await get("/library/sections/\(library.id)/all")
        return (result.mediaContainer.metadata ?? []).compactMap(mediaItem)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let result: ContainerDTO = try await get("/library/metadata/\(item.id)/allLeaves")
        return (result.mediaContainer.metadata ?? []).compactMap(mediaItem)
    }

    func playbackURL(itemID: String) -> URL? {
        guard let base else { return nil }
        let session = UUID().uuidString.lowercased()
        return base.adding(path: "/video/:/transcode/universal/start.m3u8", query: [
            "path": "/library/metadata/\(itemID)",
            "mediaIndex": "0",
            "partIndex": "0",
            "protocol": "hls",
            "fastSeek": "1",
            "directPlay": "0",
            "directStream": "1",
            "directStreamAudio": "1",
            "videoResolution": "1920x1080",
            "maxVideoBitrate": "20000",
            "subtitles": "burn",
            "session": session,
            "X-Plex-Session-Identifier": session,
            "X-Plex-Product": ClientIdentity.product,
            "X-Plex-Platform": "iOS",
            "X-Plex-Client-Identifier": ClientIdentity.deviceID,
            "X-Plex-Token": token,
        ])
    }

    /// Poster path (`/library/metadata/1/thumb/…`) → URL with the token.
    func imageURL(path: String) -> URL? {
        guard let base else { return nil }
        return base.adding(path: "/photo/:/transcode", query: [
            "url": path,
            "width": "320",
            "height": "480",
            "minSize": "1",
            "X-Plex-Token": token,
        ])
    }

    // MARK: - Private

    private func mediaItem(_ metadata: ContainerDTO.Metadata) -> MediaItem? {
        let kind: MediaItem.Kind
        switch metadata.type {
        case "movie": kind = .movie
        case "show": kind = .series
        case "episode": kind = .episode
        case "clip": kind = .video
        default: return nil
        }
        var subtitle: String?
        if kind == .episode, let index = metadata.index {
            subtitle = metadata.parentIndex.map { "S\($0) · E\(index)" } ?? "E\(index)"
        } else if let year = metadata.year {
            subtitle = String(year)
        }
        let thumb = kind == .episode ? (metadata.thumb ?? metadata.grandparentThumb) : metadata.thumb
        return MediaItem(
            id: metadata.ratingKey,
            name: metadata.title,
            kind: kind,
            subtitle: subtitle,
            group: nil,
            // Posters keep only the path; the token is added when the image is shown.
            imageURL: thumb.map { InternalURL.image(sourceID: sourceID, path: $0) }
        )
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        guard let base else { throw MediaServerError.invalidServer }
        var request = URLRequest(url: base.adding(path: path), timeoutInterval: 30)
        Self.addHeaders(&request, token: token)
        return try await Self.send(request)
    }

    private static func addHeaders(_ request: inout URLRequest, token: String?) {
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(ClientIdentity.product, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(ClientIdentity.version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue(ClientIdentity.deviceID, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue("iOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue("iPhone", forHTTPHeaderField: "X-Plex-Device")
        if let token {
            request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        }
    }

    private static func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw MediaServerError.wrongCredentials }
        guard (200..<300).contains(status) else { throw MediaServerError.badResponse(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Wire types

    private struct PinDTO: Decodable {
        let id: Int
        let code: String
        let authToken: String?
    }

    struct ResourceDTO: Decodable {
        struct Connection: Decodable {
            let uri: String
            let local: Bool?
            let relay: Bool?
        }

        let name: String
        let provides: String
        let clientIdentifier: String
        let accessToken: String?
        let connections: [Connection]
    }

    struct ContainerDTO: Decodable {
        struct Container: Decodable {
            let directory: [Directory]?
            let metadata: [Metadata]?
            enum CodingKeys: String, CodingKey {
                case directory = "Directory"
                case metadata = "Metadata"
            }
        }

        struct Directory: Decodable {
            let key: String
            let title: String
            let type: String
        }

        struct Metadata: Decodable {
            let ratingKey: String
            let title: String
            let type: String
            let year: Int?
            let index: Int?
            let parentIndex: Int?
            let thumb: String?
            let grandparentThumb: String?
        }

        let mediaContainer: Container
        enum CodingKeys: String, CodingKey { case mediaContainer = "MediaContainer" }
    }
}
