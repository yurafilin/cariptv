import Foundation

/// A TV programme from the guide.
struct Programme: Codable, Hashable, Sendable {
    var title: String
    var start: Date
    var end: Date
}

/// What is on now and next for live channels.
/// - Xtream panels answer per channel (`get_short_epg`); answers are cached for a few minutes
///   so scrolling a channel list does not hammer the panel.
/// - M3U playlists point to an XMLTV file; it is read once per source for the next day and a half
///   and kept on disk for 12 hours.
actor ProgramGuide {
    static let shared = ProgramGuide()

    /// Where a channel's guide comes from; built on the main actor by `LibraryStore.guideLookup(for:)`.
    enum Lookup: Sendable {
        case xtream(XtreamClient, streamID: String)
        /// `channels` — the whole source, so one read of the file serves every channel in it.
        case xmltv(sourceID: UUID, url: URL, channel: Channel, channels: [Channel])
    }

    private static let lifetime: TimeInterval = 10 * 60
    private var cache: [String: (fetched: Date, programmes: [Programme])] = [:]
    private var inFlight: [String: Task<[Programme], Never>] = [:]

    private static let guideLifetime: TimeInterval = 12 * 60 * 60
    private static let guideRetryDelay: TimeInterval = 10 * 60
    private var guides: [UUID: StoredGuide] = [:]
    private var guideTasks: [UUID: Task<XMLTV.Guide?, Never>] = [:]
    private var failedGuides: [UUID: Date] = [:]
    private var checkedDisk: Set<UUID> = []

    private struct StoredGuide: Codable {
        var url: URL
        var fetched: Date
        var guide: XMLTV.Guide

        var isFresh: Bool {
            Date.now.timeIntervalSince(fetched) < ProgramGuide.guideLifetime
                && guide.window.end > Date.now.addingTimeInterval(6 * 60 * 60)
        }
    }

    func nowNext(_ lookup: Lookup, at date: Date = .now) async -> (now: Programme?, next: Programme?) {
        switch lookup {
        case .xtream(let client, let streamID):
            return await nowNext(client: client, streamID: streamID, at: date)
        case .xmltv(let sourceID, let url, let channel, let channels):
            guard let guide = await xmltvGuide(sourceID: sourceID, url: url, channels: channels) else { return (nil, nil) }
            return Self.nowNext(guide.programmes(for: channel), at: date)
        }
    }

    /// Drops the stored guide of a removed source.
    func forget(_ sourceID: UUID) {
        guides[sourceID] = nil
        failedGuides[sourceID] = nil
        try? FileManager.default.removeItem(at: Self.guideFile(sourceID))
    }

    /// `(now, next)` for an Xtream stream; empty when the panel has no guide for it.
    func nowNext(client: XtreamClient, streamID: String, at date: Date = .now) async -> (now: Programme?, next: Programme?) {
        let programmes = await programmes(client: client, streamID: streamID)
        return Self.nowNext(programmes, at: date)
    }

    nonisolated static func nowNext(_ programmes: [Programme], at date: Date) -> (now: Programme?, next: Programme?) {
        let sorted = programmes.sorted { $0.start < $1.start }
        let now = sorted.first { $0.start <= date && date < $0.end }
        let next = sorted.first { $0.start > date }
        return (now, next)
    }

    private func programmes(client: XtreamClient, streamID: String) async -> [Programme] {
        let key = "\(client.server.absoluteString)|\(client.username)|\(streamID)"
        if let cached = cache[key], Date.now.timeIntervalSince(cached.fetched) < Self.lifetime {
            return cached.programmes
        }
        if let running = inFlight[key] {
            return await running.value
        }
        let task = Task<[Programme], Never> {
            (try? await client.shortEPG(streamID: streamID)) ?? []
        }
        inFlight[key] = task
        let programmes = await task.value
        inFlight[key] = nil
        cache[key] = (.now, programmes)
        return programmes
    }
}

extension ProgramGuide {
    private func xmltvGuide(sourceID: UUID, url: URL, channels: [Channel]) async -> XMLTV.Guide? {
        if guides[sourceID] == nil, !checkedDisk.contains(sourceID) {
            checkedDisk.insert(sourceID)
            guides[sourceID] = Self.readGuide(sourceID)
        }
        let stored = guides[sourceID].flatMap { $0.url == url ? $0 : nil }
        if let stored, stored.isFresh {
            return stored.guide
        }
        if let failed = failedGuides[sourceID], Date.now.timeIntervalSince(failed) < Self.guideRetryDelay {
            return stored?.guide
        }
        if let running = guideTasks[sourceID] {
            return await running.value ?? stored?.guide
        }

        let window = DateInterval(start: Date.now.addingTimeInterval(-2 * 60 * 60), duration: 38 * 60 * 60)
        let wanted = XMLTV.Wanted(channels)
        // Parsing a large guide takes seconds: off the actor, so cached lookups keep answering.
        let task = Task.detached(priority: .utility) { () -> XMLTV.Guide? in
            do {
                return try await XMLTV.load(url, wanted: wanted, window: window)
            } catch {
                Log.playback.error("guide: \(url.host() ?? "?", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        guideTasks[sourceID] = task
        let guide = await task.value
        guideTasks[sourceID] = nil

        guard let guide else {
            failedGuides[sourceID] = .now
            return stored?.guide
        }
        failedGuides[sourceID] = nil
        let fresh = StoredGuide(url: url, fetched: .now, guide: guide)
        guides[sourceID] = fresh
        Self.writeGuide(fresh, sourceID)
        Log.playback.info("guide: \(url.host() ?? "?", privacy: .public) \(guide.programmes.count) channels")
        return guide
    }

    private static var guidesDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Guides", isDirectory: true)
    }

    private static func guideFile(_ sourceID: UUID) -> URL {
        guidesDirectory.appendingPathComponent("\(sourceID.uuidString).json")
    }

    private static func readGuide(_ sourceID: UUID) -> StoredGuide? {
        guard let data = try? Data(contentsOf: guideFile(sourceID)) else { return nil }
        return try? JSONDecoder().decode(StoredGuide.self, from: data)
    }

    private static func writeGuide(_ stored: StoredGuide, _ sourceID: UUID) {
        try? FileManager.default.createDirectory(at: guidesDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: guideFile(sourceID), options: .atomic)
    }
}

extension XtreamClient {
    func shortEPG(streamID: String, limit: Int = 4) async throws -> [Programme] {
        let response: ShortEPG = try await request(action: "get_short_epg", parameters: ["stream_id": streamID, "limit": String(limit)])
        return response.listings.compactMap(\.programme)
    }

    struct ShortEPG: Decodable {
        struct Listing: Decodable {
            let title: LooseString?
            let startTimestamp: LooseString?
            let stopTimestamp: LooseString?

            enum CodingKeys: String, CodingKey {
                case title
                case startTimestamp = "start_timestamp"
                case stopTimestamp = "stop_timestamp"
            }

            var programme: Programme? {
                guard let start = startTimestamp?.value.flatMap(TimeInterval.init),
                      let stop = stopTimestamp?.value.flatMap(TimeInterval.init),
                      let raw = title?.value else { return nil }
                return Programme(title: Self.decodeTitle(raw), start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: stop))
            }

            /// Panels send titles base64-encoded; some send plain text.
            static func decodeTitle(_ raw: String) -> String {
                guard let data = Data(base64Encoded: raw), let text = String(data: data, encoding: .utf8),
                      !text.isEmpty else { return raw }
                return text
            }
        }

        let listings: [Listing]
        enum CodingKeys: String, CodingKey { case listings = "epg_listings" }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            listings = (try? container.decode([Listing].self, forKey: .listings)) ?? []
        }
    }
}
