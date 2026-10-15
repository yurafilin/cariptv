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

    private func request<Response: Decodable>(action: String?) async throws -> Response {
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

    private struct Category: Decodable {
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
