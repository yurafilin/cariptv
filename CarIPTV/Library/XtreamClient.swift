import Foundation

/// Xtream Codes `player_api.php`: login check and the live channel list.
struct XtreamClient {
    enum XtreamError: LocalizedError {
        case invalidServer
        case wrongCredentials
        case accountInactive(String)

        var errorDescription: String? {
            switch self {
            case .invalidServer:
                String(localized: "Enter the server address, for example http://example.com:8080")
            case .wrongCredentials:
                String(localized: "The username or password is wrong.")
            case .accountInactive(let status):
                String(localized: "The account is not active (\(status)).")
            }
        }
    }

    let server: URL
    let username: String
    let password: String

    /// Accepts what users paste: with or without scheme, with a trailing slash or `/player_api.php`.
    static func normalizedServer(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = "http://" + text
        }
        guard var components = URLComponents(string: text), let host = components.host, !host.isEmpty else { return nil }
        components.query = nil
        components.fragment = nil
        var path = components.path
        for suffix in ["/player_api.php", "/get.php"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.path = path
        return components.url
    }

    /// HLS output: AVPlayer cannot play the default MPEG-TS one.
    func streamURL(streamID: String) -> URL {
        server
            .appendingPathComponent("live")
            .appendingPathComponent(username)
            .appendingPathComponent(password)
            .appendingPathComponent("\(streamID).m3u8")
    }

    func authenticate() async throws {
        let response: AuthResponse = try await request(action: nil)
        guard let info = response.userInfo, info.auth?.value == "1" else {
            throw XtreamError.wrongCredentials
        }
        if let status = info.status?.value, status.lowercased() != "active" {
            throw XtreamError.accountInactive(status)
        }
    }

    func liveChannels() async throws -> [Channel] {
        async let categoriesRequest: [Category] = request(action: "get_live_categories")
        async let streamsRequest: [LiveStream] = request(action: "get_live_streams")
        let (categories, streams) = try await (categoriesRequest, streamsRequest)

        var categoryNames: [String: String] = [:]
        for category in categories {
            if let id = category.categoryID?.value, let name = category.categoryName?.value {
                categoryNames[id] = name
            }
        }
        return streams.compactMap { stream in
            guard let streamID = stream.streamID?.value else { return nil }
            return Channel(
                id: streamID,
                name: stream.name?.value ?? streamID,
                url: streamURL(streamID: streamID),
                group: stream.categoryID?.value.flatMap { categoryNames[$0] },
                logo: stream.icon?.value.flatMap { URL(string: $0) }
            )
        }
    }

    // MARK: - HTTP

    func request<Response: Decodable>(action: String?, parameters: [String: String] = [:]) async throws -> Response {
        guard var components = URLComponents(url: server.appendingPathComponent("player_api.php"), resolvingAgainstBaseURL: false) else {
            throw XtreamError.invalidServer
        }
        var query = [
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password),
        ]
        if let action {
            query.append(URLQueryItem(name: "action", value: action))
        }
        query += parameters.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.queryItems = query
        guard let url = components.url else { throw XtreamError.invalidServer }

        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 30))
        if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            throw XtreamError.wrongCredentials
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }

    // MARK: - Wire types (panels mix numbers and strings freely)

    private struct AuthResponse: Decodable {
        let userInfo: UserInfo?
        enum CodingKeys: String, CodingKey { case userInfo = "user_info" }
    }

    private struct UserInfo: Decodable {
        let auth: LooseString?
        let status: LooseString?
    }

    struct Category: Decodable {
        let categoryID: LooseString?
        let categoryName: LooseString?
        enum CodingKeys: String, CodingKey {
            case categoryID = "category_id"
            case categoryName = "category_name"
        }
    }

    private struct LiveStream: Decodable {
        let streamID: LooseString?
        let name: LooseString?
        let icon: LooseString?
        let categoryID: LooseString?
        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case name
            case icon = "stream_icon"
            case categoryID = "category_id"
        }
    }
}

/// Decodes a JSON string, number or bool as text; empty or null becomes `nil`.
struct LooseString: Decodable, Hashable {
    let value: String?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string.isEmpty ? nil : string
        } else if let int = try? container.decode(Int.self) {
            value = String(int)
        } else if let double = try? container.decode(Double.self) {
            value = String(double)
        } else if let bool = try? container.decode(Bool.self) {
            value = bool ? "1" : "0"
        } else {
            value = nil
        }
    }
}

/// Xtream's on-demand sections (movies, series) as a media server; live channels stay in the channel list.
struct XtreamCatalog: MediaServer {
    static let moviesID = "vod"
    static let seriesID = "series"

    let client: XtreamClient

    func libraries() async throws -> [MediaLibrary] {
        [
            MediaLibrary(id: Self.moviesID, name: String(localized: "Movies"), kind: .movies),
            MediaLibrary(id: Self.seriesID, name: String(localized: "Series"), kind: .shows),
        ]
    }

    func items(in library: MediaLibrary) async throws -> [MediaItem] {
        let isMovies = library.id == Self.moviesID
        async let categoriesRequest: [XtreamClient.Category] = client.request(action: isMovies ? "get_vod_categories" : "get_series_categories")
        async let entriesRequest: [Entry] = client.request(action: isMovies ? "get_vod_streams" : "get_series")
        let (categories, entries) = try await (categoriesRequest, entriesRequest)
        let names = Self.categoryNames(categories)
        return entries.compactMap { isMovies ? Self.movie($0, names) : Self.series($0, names) }
    }

    func children(of item: MediaItem) async throws -> [MediaItem] {
        guard item.kind == .series, let seriesID = item.id.split(separator: ":").last else { return [] }
        let info: SeriesInfo = try await client.request(action: "get_series_info", parameters: ["series_id": String(seriesID)])
        return Self.episodes(info, fallbackImage: item.imageURL)
    }

    /// `movie/<id>.<ext>` and `series/<id>.<ext>` map onto the panel's stream paths.
    func playbackURL(itemID: String) -> URL? {
        let parts = itemID.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, parts[0] == "movie" || parts[0] == "series" else { return nil }
        return client.server
            .appendingPathComponent(String(parts[0]))
            .appendingPathComponent(client.username)
            .appendingPathComponent(client.password)
            .appendingPathComponent(String(parts[1]))
    }

    // MARK: - Mapping

    static func categoryNames(_ categories: [XtreamClient.Category]) -> [String: String] {
        var names: [String: String] = [:]
        for category in categories {
            if let id = category.categoryID?.value, let name = category.categoryName?.value {
                names[id] = name
            }
        }
        return names
    }

    static func movie(_ entry: Entry, _ categories: [String: String]) -> MediaItem? {
        guard let id = entry.streamID?.value else { return nil }
        let ext = entry.containerExtension?.value ?? "mp4"
        return MediaItem(
            id: "movie/\(id).\(ext)",
            name: entry.name?.value ?? id,
            kind: .movie,
            subtitle: entry.year?.value,
            group: entry.categoryID?.value.flatMap { categories[$0] },
            imageURL: entry.streamIcon?.value.flatMap(URL.init(string:))
        )
    }

    static func series(_ entry: Entry, _ categories: [String: String]) -> MediaItem? {
        guard let id = entry.seriesID?.value else { return nil }
        return MediaItem(
            id: "series:\(id)",
            name: entry.name?.value ?? id,
            kind: .series,
            subtitle: entry.year?.value,
            group: entry.categoryID?.value.flatMap { categories[$0] },
            imageURL: entry.cover?.value.flatMap(URL.init(string:))
        )
    }

    static func episodes(_ info: SeriesInfo, fallbackImage: URL?) -> [MediaItem] {
        info.episodes
            .sorted { (Int($0.key) ?? 0) < (Int($1.key) ?? 0) }
            .flatMap { season, episodes in
                episodes.compactMap { episode -> MediaItem? in
                    guard let id = episode.id?.value else { return nil }
                    let ext = episode.containerExtension?.value ?? "mp4"
                    let number = episode.episodeNum?.value ?? ""
                    return MediaItem(
                        id: "series/\(id).\(ext)",
                        name: episode.title?.value ?? String(localized: "Episode \(number)"),
                        kind: .episode,
                        subtitle: "S\(season) · E\(number)",
                        group: nil,
                        imageURL: episode.info?.movieImage?.value.flatMap(URL.init(string:)) ?? fallbackImage
                    )
                }
            }
    }

    // MARK: - Wire types

    struct Entry: Decodable {
        let streamID: LooseString?
        let seriesID: LooseString?
        let name: LooseString?
        let streamIcon: LooseString?
        let cover: LooseString?
        let categoryID: LooseString?
        let containerExtension: LooseString?
        let year: LooseString?

        enum CodingKeys: String, CodingKey {
            case streamID = "stream_id"
            case seriesID = "series_id"
            case name
            case streamIcon = "stream_icon"
            case cover
            case categoryID = "category_id"
            case containerExtension = "container_extension"
            case year
        }
    }

    struct SeriesInfo: Decodable {
        struct Episode: Decodable {
            struct Info: Decodable {
                let movieImage: LooseString?
                enum CodingKeys: String, CodingKey { case movieImage = "movie_image" }
            }

            let id: LooseString?
            let episodeNum: LooseString?
            let title: LooseString?
            let containerExtension: LooseString?
            let info: Info?

            enum CodingKeys: String, CodingKey {
                case id
                case episodeNum = "episode_num"
                case title
                case containerExtension = "container_extension"
                case info
            }
        }

        /// Season number → episodes. Panels send either an object keyed by season or an array of seasons.
        let episodes: [String: [Episode]]

        enum CodingKeys: String, CodingKey { case episodes }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let bySeason = try? container.decode([String: [Episode]].self, forKey: .episodes) {
                episodes = bySeason
            } else if let list = try? container.decode([[Episode]].self, forKey: .episodes) {
                episodes = Dictionary(uniqueKeysWithValues: list.enumerated().map { (String($0.offset + 1), $0.element) })
            } else {
                episodes = [:]
            }
        }
    }
}
