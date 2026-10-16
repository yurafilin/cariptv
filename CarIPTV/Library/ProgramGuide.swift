import Foundation

/// A TV programme from the guide.
struct Programme: Hashable, Sendable {
    var title: String
    var start: Date
    var end: Date
}

/// What is on now and next for live channels. Xtream panels answer per channel (`get_short_epg`);
/// answers are cached for a few minutes so scrolling a channel list does not hammer the panel.
actor ProgramGuide {
    static let shared = ProgramGuide()

    private static let lifetime: TimeInterval = 10 * 60
    private var cache: [String: (fetched: Date, programmes: [Programme])] = [:]
    private var inFlight: [String: Task<[Programme], Never>] = [:]

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
