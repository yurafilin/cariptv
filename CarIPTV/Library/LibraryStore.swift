import Foundation
import Observation

/// The user's sources, their channels, favorites, recents and imported videos.
/// Everything is stored as JSON in Application Support; Xtream passwords in the Keychain.
@MainActor @Observable
final class LibraryStore {
    static let shared = LibraryStore()

    enum LibraryError: LocalizedError {
        case notAPlaylist
        case emptyPlaylist
        case missingPassword

        var errorDescription: String? {
            switch self {
            case .notAPlaylist:
                String(localized: "This doesn't look like an M3U playlist.")
            case .emptyPlaylist:
                String(localized: "The playlist has no channels.")
            case .missingPassword:
                String(localized: "The password for this account is missing. Remove the source and add it again.")
            }
        }
    }

    private static let maxRecent = 30

    private(set) var sources: [Source] = []
    private(set) var favorites: [LibraryItem] = []
    private(set) var recent: [LibraryItem] = []
    private(set) var localVideos: [LocalVideo] = []
    /// Channels per source, loaded from disk in the background at launch.
    private(set) var channels: [UUID: [Channel]] = [:]

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let videosDirectory: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = support.appendingPathComponent("Library", isDirectory: true)
        videosDirectory = support.appendingPathComponent("LocalVideos", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: videosDirectory, withIntermediateDirectories: true)

        sources = read([Source].self, "sources.json") ?? []
        favorites = read([LibraryItem].self, "favorites.json") ?? []
        recent = read([LibraryItem].self, "recent.json") ?? []
        localVideos = read([LocalVideo].self, "local-videos.json") ?? []
        loadChannels()
    }

    // MARK: - Sources

    func channels(in source: Source) -> [Channel] {
        channels[source.id] ?? []
    }

    var isLoadingChannels: Bool {
        sources.contains { channels[$0.id] == nil }
    }

    func addM3U(url: URL, name: String?) async throws {
        let parsed = try await Self.downloadPlaylist(url)
        let source = Source(
            id: UUID(),
            name: Self.cleanName(name) ?? url.host() ?? String(localized: "Playlist"),
            kind: .m3uURL(url),
            channelCount: parsed.count,
            updatedAt: .now
        )
        store(source, channels: parsed)
    }

    func importM3U(file url: URL) async throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let parsed = try await Self.parsePlaylist(data)
        let source = Source(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            kind: .m3uFile(fileName: url.lastPathComponent),
            channelCount: parsed.count,
            updatedAt: .now
        )
        store(source, channels: parsed)
    }

    func addXtream(server: String, username: String, password: String, name: String?) async throws {
        guard let serverURL = XtreamClient.normalizedServer(server) else {
            throw XtreamClient.XtreamError.invalidServer
        }
        let client = XtreamClient(server: serverURL, username: username, password: password)
        try await client.authenticate()
        let parsed = try await client.liveChannels()
        guard !parsed.isEmpty else { throw LibraryError.emptyPlaylist }

        let source = Source(
            id: UUID(),
            name: Self.cleanName(name) ?? serverURL.host() ?? "Xtream",
            kind: .xtream(server: serverURL, username: username),
            channelCount: parsed.count,
            updatedAt: .now
        )
        Keychain.set(password, for: source.id.uuidString)
        store(source, channels: parsed)
    }

    func refresh(_ source: Source) async throws {
        let parsed: [Channel]
        switch source.kind {
        case .m3uURL(let url):
            parsed = try await Self.downloadPlaylist(url)
        case .xtream(let server, let username):
            guard let password = Keychain.get(source.id.uuidString) else { throw LibraryError.missingPassword }
            parsed = try await XtreamClient(server: server, username: username, password: password).liveChannels()
        case .m3uFile:
            return
        }
        var updated = source
        updated.channelCount = parsed.count
        updated.updatedAt = .now
        store(updated, channels: parsed)
    }

    func delete(_ source: Source) {
        sources.removeAll { $0.id == source.id }
        channels[source.id] = nil
        favorites.removeAll { $0.sourceID == source.id }
        recent.removeAll { $0.sourceID == source.id }
        Keychain.remove(source.id.uuidString)
        try? FileManager.default.removeItem(at: channelsFile(source.id))
        write(sources, "sources.json")
        write(favorites, "favorites.json")
        write(recent, "recent.json")
    }

    // MARK: - Favorites and recents

    func isFavorite(_ item: LibraryItem) -> Bool {
        favorites.contains { $0.id == item.id }
    }

    func toggleFavorite(_ item: LibraryItem) {
        if let index = favorites.firstIndex(where: { $0.id == item.id }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(item, at: 0)
        }
        write(favorites, "favorites.json")
    }

    func markPlayed(_ item: LibraryItem) {
        recent.removeAll { $0.id == item.id }
        recent.insert(item, at: 0)
        if recent.count > Self.maxRecent {
            recent.removeLast(recent.count - Self.maxRecent)
        }
        write(recent, "recent.json")
    }

    /// Case- and diacritic-insensitive match on channel name and group, across all sources.
    func search(_ query: String, limit: Int = 200) -> [LibraryItem] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return [] }
        var results: [LibraryItem] = []
        for source in sources {
            for channel in channels(in: source) where Self.matches(channel, query) {
                results.append(LibraryItem(sourceID: source.id, channel: channel))
                if results.count >= limit { return results }
            }
        }
        return results
    }

    static func matches(_ channel: Channel, _ query: String) -> Bool {
        channel.name.localizedStandardContains(query) || (channel.group?.localizedStandardContains(query) ?? false)
    }

    // MARK: - Local videos

    func url(for video: LocalVideo) -> URL {
        videosDirectory.appendingPathComponent(video.fileName)
    }

    /// Copies (or moves, for temporary files handed over by Photos) a video into the app container.
    func importVideo(from url: URL, title: String? = nil, moving: Bool = false) throws {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let ext = url.pathExtension.isEmpty ? "mov" : url.pathExtension
        let fileName = "\(id.uuidString).\(ext)"
        let destination = videosDirectory.appendingPathComponent(fileName)
        if moving {
            try FileManager.default.moveItem(at: url, to: destination)
        } else {
            try FileManager.default.copyItem(at: url, to: destination)
        }
        let video = LocalVideo(
            id: id,
            title: Self.cleanName(title) ?? url.deletingPathExtension().lastPathComponent,
            fileName: fileName,
            addedAt: .now
        )
        localVideos.insert(video, at: 0)
        write(localVideos, "local-videos.json")
    }

    func delete(_ video: LocalVideo) {
        localVideos.removeAll { $0.id == video.id }
        try? FileManager.default.removeItem(at: url(for: video))
        write(localVideos, "local-videos.json")
    }

    // MARK: - Playlist loading

    nonisolated static func downloadPlaylist(_ url: URL) async throws -> [Channel] {
        let (data, response) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 60))
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        return try await parsePlaylist(data)
    }

    nonisolated static func parsePlaylist(_ data: Data) async throws -> [Channel] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        guard text.contains("#EXTINF") || text.contains("#EXTM3U") || text.contains("://") else {
            throw LibraryError.notAPlaylist
        }
        let channels = M3UParser.parse(text)
        guard !channels.isEmpty else { throw LibraryError.emptyPlaylist }
        return channels
    }

    // MARK: - Persistence

    private func store(_ source: Source, channels parsed: [Channel]) {
        if let index = sources.firstIndex(where: { $0.id == source.id }) {
            sources[index] = source
        } else {
            sources.append(source)
        }
        channels[source.id] = parsed
        write(sources, "sources.json")
        let file = channelsFile(source.id)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(parsed) {
                try? data.write(to: file, options: .atomic)
            }
        }
    }

    private func loadChannels() {
        let files = sources.map { ($0.id, channelsFile($0.id)) }
        Task.detached(priority: .userInitiated) {
            for (id, file) in files {
                let loaded = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Channel].self, from: $0) } ?? []
                await MainActor.run {
                    LibraryStore.shared.channels[id] = loaded
                }
            }
        }
    }

    private func channelsFile(_ id: UUID) -> URL {
        directory.appendingPathComponent("channels-\(id.uuidString).json")
    }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return name
    }
}
