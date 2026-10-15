import Foundation

/// Jellyfin and Emby share most of their HTTP API (Jellyfin is a fork of Emby).
struct JellyfinClient: MediaServer {
    enum Flavor: String, Codable, Sendable {
        case jellyfin
        case emby

        var title: String {
            switch self {
            case .jellyfin: "Jellyfin"
            case .emby: "Emby"
            }
        }
    }

    struct Session: Sendable {
        var token: String
        var userID: String
        var serverName: String?
    }

    let server: URL
    let flavor: Flavor
    let token: String
    let userID: String

    /// Emby serves its API under `/emby` unless the user typed a path of their own.
    static func apiBase(_ server: URL, flavor: Flavor) -> URL {
        guard flavor == .emby else { return server }
        let path = server.path
        return path.isEmpty || path == "/" ? server.adding(path: "/emby") : server
    }

    /// Accepts `host:port`, with or without scheme and trailing slash.
    static func normalizedServer(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), components.host?.isEmpty == false else { return nil }
        components.query = nil
        components.fragment = nil
        while components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.url
    }

    static func authenticate(server: URL, flavor: Flavor, username: String, password: String) async throws -> Session {
        let url = apiBase(server, flavor: flavor).adding(path: "/Users/AuthenticateByName")
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: nil)
        request.httpBody = try JSONEncoder().encode(["Username": username, "Pw": password])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw MediaServerError.wrongCredentials }
        guard (200..<300).contains(status) else { throw MediaServerError.badResponse(status) }
        let result = try JSONDecoder().decode(AuthResult.self, from: data)
        return Session(token: result.accessToken, userID: result.user.id, serverName: result.user.serverName)
    }

    // MARK: - MediaServer

    func libraries() async throws -> [MediaLibrary] {
        let result: ItemsResult = try await get(flavor == .jellyfin ? "/UserViews" : legacyViewsPath, fallback: legacyViewsPath, query: userQuery)
        return result.items.map { view in
            let kind: MediaLibrary.Kind = switch view.collectionType {
            case "movies": .movies
            case "tvshows": .shows
            default: .mixed
            }
            return MediaLibrary(id: view.id, name: view.name, kind: kind)
        }
    }

    func items(in library: MediaLibrary) async throws -> [MediaItem] {
        var query = userQuery.merging([
            "ParentId": library.id,
            "SortBy": "SortName",
            "SortOrder": "Ascending",
            "Fields": "ProductionYear",
            "Limit": "2000",
        ]) { $1 }
        switch library.kind {
        case .movies:
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = "Movie"
        case .shows:
            query["Recursive"] = "true"
            query["IncludeItemTypes"] = "Series"
        case .mixed:
            break
        }
        let result: ItemsResult = try await get(itemsPath, fallback: legacyItemsPath, query: query)
        return result.items.compactMap(mediaItem)
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        let result: ItemsResult
        if item.kind == .series {
            result = try await get("/Shows/\(item.id)/Episodes", query: userQuery.merging(["Fields": "ProductionYear"]) { $1 })
        } else {
            result = try await get(itemsPath, fallback: legacyItemsPath, query: userQuery.merging(["ParentId": item.id, "SortBy": "SortName"]) { $1 })
        }
        return result.items.compactMap(mediaItem)
    }

    /// HLS from the server: it remuxes or transcodes whatever the file is into something AVPlayer plays.
    func playbackURL(itemID: String) -> URL? {
        Self.apiBase(server, flavor: flavor).adding(path: "/Videos/\(itemID)/master.m3u8", query: [
            "MediaSourceId": itemID,
            "DeviceId": ClientIdentity.deviceID,
            "PlaySessionId": UUID().uuidString.lowercased(),
            "VideoCodec": "h264,hevc",
            "AudioCodec": "aac,mp3,ac3,eac3",
            "TranscodingMaxAudioChannels": "2",
            "MaxStreamingBitrate": "20000000",
            "SegmentContainer": "ts",
            "BreakOnNonKeyFrames": "True",
            "api_key": token,
            "ApiKey": token,
        ])
    }

    // MARK: - Private

    private var userQuery: [String: String] {
        flavor == .jellyfin ? ["userId": userID] : [:]
    }

    /// Jellyfin 10.9+ takes the user as a parameter; Emby and older Jellyfin keep it in the path.
    private var itemsPath: String {
        flavor == .jellyfin ? "/Items" : legacyItemsPath
    }

    private var legacyItemsPath: String { "/Users/\(userID)/Items" }
    private var legacyViewsPath: String { "/Users/\(userID)/Views" }

    private func mediaItem(_ item: ItemDTO) -> MediaItem? {
        let kind: MediaItem.Kind
        switch item.type {
        case "Movie": kind = .movie
        case "Series": kind = .series
        case "Episode": kind = .episode
        case "Video", "MusicVideo", "Trailer": kind = .video
        case "Folder", "CollectionFolder", "BoxSet", "Season", "UserView": kind = .folder
        default: return nil
        }
        var subtitle: String?
        if kind == .episode, let episode = item.indexNumber {
            subtitle = item.parentIndexNumber.map { "S\($0) · E\(episode)" } ?? "E\(episode)"
        } else if let year = item.productionYear {
            subtitle = String(year)
        }
        var imageURL: URL?
        if let tag = item.imageTags?["Primary"] {
            imageURL = Self.apiBase(server, flavor: flavor).adding(path: "/Items/\(item.id)/Images/Primary", query: ["maxHeight": "480", "tag": tag])
        }
        return MediaItem(id: item.id, name: item.name, kind: kind, subtitle: subtitle, group: nil, imageURL: imageURL)
    }

    /// Retries on the older path when the newer one is missing (404).
    private func get<T: Decodable>(_ path: String, fallback: String, query: [String: String]) async throws -> T {
        do {
            return try await get(path, query: query)
        } catch MediaServerError.badResponse(404) where fallback != path {
            return try await get(fallback, query: query)
        }
    }

    private func get<T: Decodable>(_ path: String, query: [String: String]) async throws -> T {
        var request = URLRequest(url: Self.apiBase(server, flavor: flavor).adding(path: path, query: query), timeoutInterval: 30)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        Self.authorize(&request, token: token)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw MediaServerError.wrongCredentials }
        guard (200..<300).contains(status) else { throw MediaServerError.badResponse(status) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Both header spellings: Jellyfin reads `Authorization`, Emby `X-Emby-Authorization` / `X-Emby-Token`.
    private static func authorize(_ request: inout URLRequest, token: String?) {
        var value = #"MediaBrowser Client="\#(ClientIdentity.product)", Device="iPhone", DeviceId="\#(ClientIdentity.deviceID)", Version="\#(ClientIdentity.version)""#
        if let token {
            value += #", Token="\#(token)""#
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        request.setValue(value, forHTTPHeaderField: "Authorization")
        request.setValue(value, forHTTPHeaderField: "X-Emby-Authorization")
    }

    // MARK: - Wire types

    private struct AuthResult: Decodable {
        struct User: Decodable {
            let id: String
            let serverName: String?
            enum CodingKeys: String, CodingKey {
                case id = "Id"
                case serverName = "ServerName"
            }
        }

        let accessToken: String
        let user: User
        enum CodingKeys: String, CodingKey {
            case accessToken = "AccessToken"
            case user = "User"
        }
    }

    struct ItemsResult: Decodable {
        let items: [ItemDTO]
        enum CodingKeys: String, CodingKey { case items = "Items" }
    }

    struct ItemDTO: Decodable {
        let id: String
        let name: String
        let type: String?
        let collectionType: String?
        let productionYear: Int?
        let indexNumber: Int?
        let parentIndexNumber: Int?
        let imageTags: [String: String]?

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case name = "Name"
            case type = "Type"
            case collectionType = "CollectionType"
            case productionYear = "ProductionYear"
            case indexNumber = "IndexNumber"
            case parentIndexNumber = "ParentIndexNumber"
            case imageTags = "ImageTags"
        }
    }
}
