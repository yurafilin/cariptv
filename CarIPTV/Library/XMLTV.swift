import Compression
import Foundation

/// XMLTV programme guides — what IPTV providers publish next to M3U playlists:
/// `<tv><channel id="…"><display-name>…</display-name></channel>
/// <programme start="20261016180000 +0300" stop="…" channel="…"><title>…</title></programme></tv>`.
/// Guides run to hundreds of megabytes, so the file is streamed from disk and only the wanted
/// channels within a short window around now are kept.
enum XMLTV {
    /// The part of a guide one source needs.
    struct Guide: Codable, Sendable {
        /// Programmes per XMLTV channel id (lowercased), sorted by start.
        var programmes: [String: [Programme]] = [:]
        /// Name key (see `nameKeys`) → XMLTV channel id, for channels without a usable `tvg-id`.
        var names: [String: String] = [:]
        var window: DateInterval

        func programmes(for channel: Channel) -> [Programme] {
            if let id = channel.guideID?.lowercased(), let list = programmes[id] {
                return list
            }
            for key in XMLTV.nameKeys(channel.name) {
                if let id = names[key], let list = programmes[id] {
                    return list
                }
            }
            return []
        }
    }

    /// The channels a guide is read for: their `tvg-id`s and name keys.
    struct Wanted: Sendable {
        var ids: Set<String>
        var names: Set<String>

        init(_ channels: [Channel]) {
            ids = Set(channels.compactMap { $0.guideID?.lowercased() })
            names = Set(channels.flatMap { XMLTV.nameKeys($0.name) })
        }
    }

    enum GuideError: LocalizedError {
        case notAGuide

        var errorDescription: String? {
            String(localized: "This doesn't look like an XMLTV guide.")
        }
    }

    // MARK: - Loading

    /// Downloads the guide, unpacks it when gzipped (`.xml.gz` is the norm) and reads it.
    static func load(_ url: URL, wanted: Wanted, window: DateInterval) async throws -> Guide {
        let (downloaded, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 120))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("xmltv-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("guide")
        try FileManager.default.moveItem(at: downloaded, to: file)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
        var xml = file
        if try isGzip(file) {
            xml = directory.appendingPathComponent("guide.xml")
            try gunzip(file, to: xml)
        }
        return try parse(contentsOf: xml, wanted: wanted, window: window)
    }

    static func parse(contentsOf url: URL, wanted: Wanted, window: DateInterval) throws -> Guide {
        guard let stream = InputStream(url: url) else { throw GuideError.notAGuide }
        return try parse(XMLParser(stream: stream), wanted: wanted, window: window)
    }

    static func parse(_ data: Data, wanted: Wanted, window: DateInterval) throws -> Guide {
        try parse(XMLParser(data: data), wanted: wanted, window: window)
    }

    private static func parse(_ parser: XMLParser, wanted: Wanted, window: DateInterval) throws -> Guide {
        let reader = Reader(wanted: wanted, window: window)
        parser.delegate = reader
        parser.shouldResolveExternalEntities = false
        let finished = parser.parse()
        guard reader.sawRoot else { throw GuideError.notAGuide }
        // A guide cut off mid-download still has the programmes read so far.
        if !finished, reader.isEmpty {
            throw parser.parserError ?? GuideError.notAGuide
        }
        return reader.guide()
    }

    // MARK: - Matching

    /// Keys a channel name is matched by: letters and digits only, lowercased, also without a
    /// quality suffix — "CNN HD" matches a guide's "CNN".
    static func nameKeys(_ name: String) -> [String] {
        let base = String(name.lowercased().filter { $0.isLetter || $0.isNumber })
        guard !base.isEmpty else { return [] }
        for suffix in ["uhd", "fhd", "hd", "sd", "4k"] where base.hasSuffix(suffix) && base.count > suffix.count {
            return [base, String(base.dropLast(suffix.count))]
        }
        return [base]
    }

    // MARK: - Dates

    /// `20261016180000 +0300`; the offset may be missing (UTC) or glued on, seconds may be missing.
    static func date(_ value: String) -> Date? {
        let bytes = Array(value.utf8)
        var digits = 0
        while digits < bytes.count, bytes[digits] >= 48, bytes[digits] <= 57 {
            digits += 1
        }
        guard digits >= 12 else { return nil }
        func number(_ from: Int, _ length: Int) -> Int {
            var result = 0
            for index in from..<(from + length) {
                result = result * 10 + Int(bytes[index] - 48)
            }
            return result
        }
        let second = digits >= 14 ? number(12, 2) : 0
        let days = daysFromCivil(year: number(0, 4), month: number(4, 2), day: number(6, 2))
        var seconds = days * 86_400 + number(8, 2) * 3_600 + number(10, 2) * 60 + second

        // Time zone offset: "+0300", "-0530", after optional spaces.
        var index = digits
        while index < bytes.count, bytes[index] == 32 {
            index += 1
        }
        if index + 5 <= bytes.count, bytes[index] == 43 || bytes[index] == 45,
           bytes[(index + 1)..<(index + 5)].allSatisfy({ $0 >= 48 && $0 <= 57 }) {
            let offset = number(index + 1, 2) * 3_600 + number(index + 3, 2) * 60
            seconds += bytes[index] == 43 ? -offset : offset
        }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm):
    /// guides hold hundreds of thousands of dates, `Calendar` is too slow for that.
    static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: - Gzip

    static func isGzip(_ file: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 2) ?? Data()
        return head.elementsEqual([0x1f, 0x8b])
    }

    /// Unpacks a gzip file chunk by chunk: the header is skipped, the raw deflate stream goes
    /// through `Compression` (its `.zlib` is raw deflate), the 8-byte trailer is left out.
    static func gunzip(_ source: URL, to destination: URL) throws {
        let size = try FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }

        var buffer = try input.read(upToCount: 1 << 20) ?? Data()
        guard let headerLength = gzipHeaderLength(buffer) else { throw GuideError.notAGuide }
        let payloadEnd = size - 8
        var bufferOffset = 0
        var skip = headerLength
        var written = 0

        let filter = try OutputFilter(.decompress, using: .zlib) { data in
            if let data {
                written += data.count
                try output.write(contentsOf: data)
            }
        }
        do {
            while !buffer.isEmpty {
                let usable = max(0, min(buffer.count, payloadEnd - bufferOffset))
                if usable > skip {
                    try filter.write(buffer.subdata(in: skip..<usable))
                }
                skip = 0
                bufferOffset += buffer.count
                guard bufferOffset < payloadEnd else { break }
                buffer = try input.read(upToCount: 1 << 20) ?? Data()
            }
            try filter.finalize()
        } catch {
            // A broken tail (or a second gzip member) after a good start still leaves a readable guide.
            guard written > 0 else { throw error }
        }
    }

    /// Length of the gzip header (RFC 1952): fixed 10 bytes plus the optional fields its flags announce.
    static func gzipHeaderLength(_ data: Data) -> Int? {
        let bytes = [UInt8](data.prefix(64 * 1024))
        guard bytes.count >= 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {
            guard index + 2 <= bytes.count else { return nil }
            index += 2 + (Int(bytes[index]) | (Int(bytes[index + 1]) << 8))
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {
            while index < bytes.count, bytes[index] != 0 {
                index += 1
            }
            index += 1
        }
        if flags & 0x02 != 0 {
            index += 2
        }
        return index <= bytes.count ? index : nil
    }
}

// MARK: - Reader

/// `XMLParser` delegate that keeps only what `Wanted` asks for.
private final class Reader: NSObject, XMLParserDelegate {
    private let wanted: XMLTV.Wanted
    private let window: DateInterval

    private(set) var sawRoot = false
    private var programmes: [String: [Programme]] = [:]
    private var names: [String: String] = [:]
    private var namedIDs: Set<String> = []

    private var channelID: String?
    private var current: (channel: String, start: Date, stop: Date?)?
    private var title: String?
    private var text = ""
    private var isCollecting = false

    init(wanted: XMLTV.Wanted, window: DateInterval) {
        self.wanted = wanted
        self.window = window
    }

    var isEmpty: Bool { programmes.isEmpty }

    func guide() -> XMLTV.Guide {
        var sorted: [String: [Programme]] = [:]
        for (id, list) in programmes {
            var list = list.sorted { $0.start < $1.start }
            // `stop` is optional in XMLTV: a programme then runs until the next one starts.
            for index in list.indices where list[index].end <= list[index].start {
                list[index].end = index + 1 < list.count ? list[index + 1].start : list[index].start.addingTimeInterval(3_600)
            }
            sorted[id] = list.filter { $0.end > window.start }
        }
        return XMLTV.Guide(programmes: sorted, names: names, window: window)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch elementName {
        case "tv":
            sawRoot = true
        case "channel":
            channelID = attributes["id"]?.lowercased()
        case "display-name" where channelID != nil:
            startCollecting()
        case "programme":
            current = nil
            title = nil
            guard let channel = attributes["channel"]?.lowercased(), isWanted(channel),
                  let start = attributes["start"].flatMap(XMLTV.date), start < window.end else { return }
            let stop = attributes["stop"].flatMap(XMLTV.date)
            if let stop, stop <= window.start { return }
            // Without `stop` the end is known only later; keep anything that started in the last day.
            if stop == nil, start < window.start.addingTimeInterval(-86_400) { return }
            current = (channel, start, stop)
        case "title" where current != nil && title == nil:
            startCollecting()
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if isCollecting {
            text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
        switch elementName {
        case "display-name" where isCollecting:
            isCollecting = false
            guard let channelID else { return }
            for key in XMLTV.nameKeys(text) where wanted.names.contains(key) && names[key] == nil {
                names[key] = channelID
                namedIDs.insert(channelID)
            }
        case "channel":
            channelID = nil
        case "title" where isCollecting:
            isCollecting = false
            title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        case "programme":
            if let current, let title, !title.isEmpty {
                programmes[current.channel, default: []].append(
                    Programme(title: title, start: current.start, end: current.stop ?? current.start)
                )
            }
            current = nil
            title = nil
        default:
            break
        }
    }

    private func startCollecting() {
        text = ""
        isCollecting = true
    }

    private func isWanted(_ channel: String) -> Bool {
        wanted.ids.contains(channel) || namedIDs.contains(channel)
    }
}
