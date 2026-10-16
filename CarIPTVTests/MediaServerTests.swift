import Foundation
import Testing
@testable import CarIPTV

/// Serves canned responses to `URLSession.shared`, routed by host so suites can run in parallel.
final class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (URLRequest) -> (status: Int, body: String)
    typealias DataHandler = @Sendable (URLRequest) -> (status: Int, body: Data)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: DataHandler] = [:]
    nonisolated(unsafe) private static var requests: [String: [URLRequest]] = [:]
    nonisolated(unsafe) private static var registered = false

    static func stub(host: String, _ handler: @escaping Handler) {
        stubData(host: host) { request in
            let (status, body) = handler(request)
            return (status, Data(body.utf8))
        }
    }

    /// Binary bodies, e.g. a gzipped guide.
    static func stubData(host: String, _ handler: @escaping DataHandler) {
        lock.withLock {
            if !registered {
                URLProtocol.registerClass(StubURLProtocol.self)
                registered = true
            }
            handlers[host] = handler
            requests[host] = []
        }
    }

    static func requests(for host: String) -> [URLRequest] {
        lock.withLock { requests[host] ?? [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host() else { return false }
        return lock.withLock { handlers[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host() else { return }
        var recorded = request
        if recorded.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = data
        }
        let handler = Self.lock.withLock { () -> DataHandler? in
            Self.requests[host, default: []].append(recorded)
            return Self.handlers[host]
        }
        let (status, body) = handler?(recorded) ?? (404, Data())
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Jellyfin / Emby

struct JellyfinTests {
    @Test func authenticatesAndSendsClientHeaders() async throws {
        StubURLProtocol.stub(host: "auth.jellyfin.test") { request in
            guard request.url?.path == "/Users/AuthenticateByName" else { return (404, "") }
            return (200, #"{"AccessToken":"tok123","User":{"Id":"user1","ServerName":"Home"}}"#)
        }
        let session = try await JellyfinClient.authenticate(
            server: URL(string: "http://auth.jellyfin.test:8096")!, flavor: .jellyfin, username: "me", password: "pw"
        )
        #expect(session.token == "tok123")
        #expect(session.userID == "user1")
        #expect(session.serverName == "Home")

        let request = try #require(StubURLProtocol.requests(for: "auth.jellyfin.test").first)
        #expect(request.value(forHTTPHeaderField: "Authorization")?.contains(#"Client="CarIPTV""#) == true)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["Username": "me", "Pw": "pw"])
    }

    @Test func wrongPasswordIsReported() async {
        StubURLProtocol.stub(host: "denied.jellyfin.test") { _ in (401, "") }
        await #expect(throws: MediaServerError.self) {
            _ = try await JellyfinClient.authenticate(server: URL(string: "http://denied.jellyfin.test")!, flavor: .jellyfin, username: "a", password: "b")
        }
    }

    @Test func embyServesUnderEmbyPath() {
        #expect(JellyfinClient.apiBase(URL(string: "http://nas:8096")!, flavor: .emby).absoluteString == "http://nas:8096/emby")
        #expect(JellyfinClient.apiBase(URL(string: "http://nas:8096/custom")!, flavor: .emby).absoluteString == "http://nas:8096/custom")
        #expect(JellyfinClient.apiBase(URL(string: "http://nas:8096")!, flavor: .jellyfin).absoluteString == "http://nas:8096")
    }

    @Test func mapsLibrariesItemsAndEpisodes() async throws {
        StubURLProtocol.stub(host: "lib.jellyfin.test") { request in
            switch request.url?.path {
            case "/UserViews":
                return (200, #"{"Items":[{"Id":"m","Name":"Movies","CollectionType":"movies"},{"Id":"t","Name":"Shows","CollectionType":"tvshows"},{"Id":"x","Name":"Misc"}]}"#)
            case "/Items":
                return (200, #"{"Items":[{"Id":"1","Name":"Heat","Type":"Movie","ProductionYear":1995,"ImageTags":{"Primary":"abc"}},{"Id":"2","Name":"Song","Type":"Audio"}]}"#)
            case "/Shows/s1/Episodes":
                return (200, #"{"Items":[{"Id":"e1","Name":"Pilot","Type":"Episode","IndexNumber":1,"ParentIndexNumber":2}]}"#)
            default:
                return (404, "")
            }
        }
        let client = JellyfinClient(server: URL(string: "http://lib.jellyfin.test")!, flavor: .jellyfin, token: "tok", userID: "u")

        let libraries = try await client.libraries()
        #expect(libraries.map(\.kind) == [.movies, .shows, .mixed])

        let items = try await client.items(in: libraries[0])
        #expect(items.count == 1, "audio is skipped")
        #expect(items[0].kind == .movie)
        #expect(items[0].subtitle == "1995")
        #expect(items[0].imageURL?.path == "/Items/1/Images/Primary")
        #expect(items[0].imageURL?.query()?.contains("tag=abc") == true)

        let itemsRequest = try #require(StubURLProtocol.requests(for: "lib.jellyfin.test").first { $0.url?.path == "/Items" })
        let query = try #require(itemsRequest.url?.query())
        #expect(query.contains("userId=u") && query.contains("IncludeItemTypes=Movie") && query.contains("ParentId=m"))
        #expect(itemsRequest.value(forHTTPHeaderField: "X-Emby-Token") == "tok")

        let episodes = try await client.children(of: MediaItem(id: "s1", name: "Show", kind: .series))
        #expect(episodes.first?.subtitle == "S2 · E1")
        #expect(episodes.first?.isPlayable == true)
    }

    @Test func fallsBackToLegacyPathsOnOldJellyfin() async throws {
        StubURLProtocol.stub(host: "old.jellyfin.test") { request in
            request.url?.path == "/Users/u/Views" ? (200, #"{"Items":[{"Id":"m","Name":"Movies","CollectionType":"movies"}]}"#) : (404, "")
        }
        let client = JellyfinClient(server: URL(string: "http://old.jellyfin.test")!, flavor: .jellyfin, token: "tok", userID: "u")
        let libraries = try await client.libraries()
        #expect(libraries.map(\.name) == ["Movies"])
    }

    @Test func playbackIsServerSideHLSWithToken() throws {
        let client = JellyfinClient(server: URL(string: "http://nas:8096")!, flavor: .emby, token: "tok", userID: "u")
        let url = try #require(client.playbackURL(itemID: "42"))
        #expect(url.path == "/emby/Videos/42/master.m3u8")
        let query = try #require(url.query())
        #expect(query.contains("api_key=tok") && query.contains("MediaSourceId=42") && query.contains("VideoCodec=h264"))
    }
}

// MARK: - Plex

struct PlexTests {
    @Test func ordersConnectionsLocalRemoteRelayAndSkipsPlayers() throws {
        let json = #"""
        [
          {"name":"Living room TV","provides":"client,player","clientIdentifier":"tv","connections":[{"uri":"http://10.0.0.5:32500","local":true}]},
          {"name":"NAS","provides":"server","clientIdentifier":"nas","accessToken":"srv",
           "connections":[
             {"uri":"https://relay.plex.direct:8443","local":false,"relay":true},
             {"uri":"https://1-2-3-4.plex.direct:32400","local":false,"relay":false},
             {"uri":"https://10-0-0-2.plex.direct:32400","local":true,"relay":false}
           ]}
        ]
        """#
        let resources = try JSONDecoder().decode([PlexClient.ResourceDTO].self, from: Data(json.utf8))
        let servers = PlexClient.servers(from: resources)
        #expect(servers.map(\.name) == ["NAS"])
        #expect(servers[0].accessToken == "srv")
        #expect(servers[0].connections.map(\.host) == ["10-0-0-2.plex.direct", "1-2-3-4.plex.direct", "relay.plex.direct"])
    }

    @Test func mapsLibrariesAndEpisodesWithTokenFreePosters() async throws {
        StubURLProtocol.stub(host: "pms.plex.test") { request in
            switch request.url?.path {
            case "/library/sections":
                return (200, #"{"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie"},{"key":"2","title":"TV","type":"show"},{"key":"3","title":"Music","type":"artist"}]}}"#)
            case "/library/metadata/77/allLeaves":
                return (200, #"{"MediaContainer":{"Metadata":[{"ratingKey":"78","title":"Pilot","type":"episode","index":1,"parentIndex":1,"grandparentThumb":"/library/metadata/77/thumb/1"}]}}"#)
            default:
                return (404, "")
            }
        }
        let source = UUID()
        let client = PlexClient(sourceID: source, connections: [URL(string: "http://pms.plex.test:32400")!], token: "tok", preferred: nil)

        let libraries = try await client.libraries()
        #expect(libraries.map(\.name) == ["Movies", "TV"])
        let request = try #require(StubURLProtocol.requests(for: "pms.plex.test").first)
        #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "tok")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")

        let episodes = try await client.children(of: MediaItem(id: "77", name: "Show", kind: .series))
        let episode = try #require(episodes.first)
        #expect(episode.subtitle == "S1 · E1")
        let poster = try #require(episode.imageURL)
        #expect(poster.scheme == InternalURL.imageScheme, "the stored poster URL must not carry the token")
        #expect(InternalURL.parse(poster)?.value == "/library/metadata/77/thumb/1")
        #expect(client.imageURL(path: "/library/metadata/77/thumb/1")?.query()?.contains("X-Plex-Token=tok") == true)
    }

    @Test func playbackIsUniversalTranscodeHLS() throws {
        let client = PlexClient(sourceID: UUID(), connections: [URL(string: "https://nas.plex.direct:32400")!], token: "tok", preferred: nil)
        let url = try #require(client.playbackURL(itemID: "78"))
        #expect(url.path == "/video/:/transcode/universal/start.m3u8")
        let query = try #require(url.query(percentEncoded: false))
        #expect(query.contains("path=/library/metadata/78") && query.contains("protocol=hls") && query.contains("X-Plex-Token=tok"))
    }
}

// MARK: - Xtream movies and series

struct XtreamCatalogTests {
    private let catalog = XtreamCatalog(client: XtreamClient(server: URL(string: "http://panel.test:8080")!, username: "u", password: "p"))

    @Test func moviesKeepContainerAndCategory() throws {
        let entry = try JSONDecoder().decode(XtreamCatalog.Entry.self, from: Data(#"{"stream_id":12,"name":"Heat","stream_icon":"http://img/heat.jpg","category_id":"5","container_extension":"mkv"}"#.utf8))
        let movie = try #require(XtreamCatalog.movie(entry, ["5": "Action"]))
        #expect(movie.id == "movie/12.mkv")
        #expect(movie.group == "Action")
        #expect(catalog.playbackURL(itemID: movie.id)?.absoluteString == "http://panel.test:8080/movie/u/p/12.mkv")
    }

    @Test func seriesEpisodesFromObjectOrArray() throws {
        let byObject = #"{"episodes":{"2":[{"id":"9","episode_num":3,"title":"Three","container_extension":"mp4"}],"1":[{"id":"8","episode_num":1,"title":"One","container_extension":"mp4","info":{"movie_image":"http://img/1.jpg"}}]}}"#
        let episodes = XtreamCatalog.episodes(try JSONDecoder().decode(XtreamCatalog.SeriesInfo.self, from: Data(byObject.utf8)), fallbackImage: nil)
        #expect(episodes.map(\.subtitle) == ["S1 · E1", "S2 · E3"])
        #expect(episodes.map(\.id) == ["series/8.mp4", "series/9.mp4"])
        #expect(episodes[0].imageURL?.absoluteString == "http://img/1.jpg")

        let byArray = #"{"episodes":[[{"id":"8","episode_num":1,"title":"One"}]]}"#
        let fromArray = XtreamCatalog.episodes(try JSONDecoder().decode(XtreamCatalog.SeriesInfo.self, from: Data(byArray.utf8)), fallbackImage: nil)
        #expect(fromArray.first?.subtitle == "S1 · E1")
        #expect(catalog.playbackURL(itemID: fromArray[0].id)?.absoluteString == "http://panel.test:8080/series/u/p/8.mp4")
    }

    @Test func rejectsForeignItemIDs() {
        #expect(catalog.playbackURL(itemID: "live/1.ts") == nil)
    }
}

struct InternalURLTests {
    @Test func roundTripsValuesWithSlashesAndQueries() throws {
        let source = UUID()
        let url = InternalURL.image(sourceID: source, path: "/library/metadata/1/thumb/2?x=1&y=2")
        let parsed = try #require(InternalURL.parse(url))
        #expect(parsed.scheme == InternalURL.imageScheme)
        #expect(parsed.sourceID == source)
        #expect(parsed.value == "/library/metadata/1/thumb/2?x=1&y=2")
    }

    @Test func ignoresOrdinaryURLs() {
        #expect(InternalURL.parse(URL(string: "https://example.com/a?v=1")!) == nil)
    }

    @Test func posterItemsAreNotLive() {
        let item = MediaItem(id: "1", name: "Heat", kind: .movie, subtitle: "1995")
        let media = PlayableMedia(item, sourceID: UUID(), group: "Action")
        #expect(!media.isLive)
        #expect(media.subtitle == "Action · 1995")
        #expect(InternalURL.parse(media.url)?.value == "1")
    }
}
