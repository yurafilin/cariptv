import Foundation
import Testing
@testable import CarIPTV

struct XMLTVTests {
    private static func utc(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private static let window = DateInterval(start: utc("2026-10-16T08:00:00Z"), duration: 38 * 60 * 60)

    private static let sample = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE tv SYSTEM "xmltv.dtd">
    <tv generator-info-name="test">
      <channel id="News.uk"><display-name>Mock News</display-name></channel>
      <channel id="sport.uk"><display-name lang="en">Sport One</display-name><display-name>Sport 1</display-name></channel>
      <channel id="other"><display-name>Other</display-name></channel>
      <programme start="20261015100000 +0000" stop="20261015110000 +0000" channel="News.uk"><title>Yesterday</title></programme>
      <programme start="20261016100000 +0000" stop="20261016110000 +0000" channel="News.uk"><title>Morning</title></programme>
      <programme start="20261016110000 +0000" stop="20261016120000 +0000" channel="news.uk"><title lang="en">Noon &amp; More</title><title lang="ru">Полдень</title></programme>
      <programme start="20261016120000 +0300" channel="sport.uk"><title>Match</title></programme>
      <programme start="20261016130000 +0300" channel="sport.uk"><title>After the match</title></programme>
      <programme start="20261020100000 +0000" stop="20261020110000 +0000" channel="News.uk"><title>Next week</title></programme>
      <programme start="20261016100000 +0000" stop="20261016110000 +0000" channel="other"><title>Unwanted</title></programme>
    </tv>
    """

    private static let news = Channel(id: "1", name: "Mock News", url: URL(string: "http://x/1")!, guideID: "NEWS.UK")
    private static let sport = Channel(id: "2", name: "Sport 1 HD", url: URL(string: "http://x/2")!)
    private static let unknown = Channel(id: "3", name: "Unknown", url: URL(string: "http://x/3")!)

    private func guide() throws -> XMLTV.Guide {
        try XMLTV.parse(Data(Self.sample.utf8), wanted: XMLTV.Wanted([Self.news, Self.sport, Self.unknown]), window: Self.window)
    }

    @Test func readsDatesWithAndWithoutOffsets() {
        #expect(XMLTV.date("20261016120000 +0300") == Self.utc("2026-10-16T09:00:00Z"))
        #expect(XMLTV.date("20261016120000+0530") == Self.utc("2026-10-16T06:30:00Z"))
        #expect(XMLTV.date("20240229235959 -0100") == Self.utc("2024-03-01T00:59:59Z"))
        #expect(XMLTV.date("202610161200") == Self.utc("2026-10-16T12:00:00Z"))
        #expect(XMLTV.date("2026-10-16") == nil)
    }

    @Test func matchesChannelsByGuideIDIgnoringCase() throws {
        let titles = try guide().programmes(for: Self.news).map(\.title)
        // Yesterday ended before the window, next week starts after it; only the first title counts.
        #expect(titles == ["Morning", "Noon & More"])
    }

    @Test func matchesChannelsByNameWithoutQualitySuffix() throws {
        let programmes = try guide().programmes(for: Self.sport)
        #expect(programmes.map(\.title) == ["Match", "After the match"])
        // No `stop`: a programme runs until the next one, the last one for an hour.
        #expect(programmes[0].end == Self.utc("2026-10-16T10:00:00Z"))
        #expect(programmes[1].end == Self.utc("2026-10-16T11:00:00Z"))
    }

    @Test func keepsOnlyWantedChannels() throws {
        let guide = try guide()
        #expect(guide.programmes["other"] == nil)
        #expect(guide.programmes(for: Self.unknown).isEmpty)
    }

    @Test func nowAndNextFromTheGuide() throws {
        let programmes = try guide().programmes(for: Self.news)
        let (now, next) = ProgramGuide.nowNext(programmes, at: Self.utc("2026-10-16T10:30:00Z"))
        #expect(now?.title == "Morning")
        #expect(next?.title == "Noon & More")
    }

    @Test func rejectsFilesThatAreNotGuides() {
        #expect(throws: XMLTV.GuideError.self) {
            try XMLTV.parse(Data("<html><body>Not found</body></html>".utf8), wanted: XMLTV.Wanted([]), window: Self.window)
        }
    }

    @Test func nameKeysDropPunctuationAndQuality() {
        #expect(XMLTV.nameKeys("CNN HD") == ["cnnhd", "cnn"])
        #expect(XMLTV.nameKeys("Канал 1") == ["канал1"])
        #expect(XMLTV.nameKeys("HD") == ["hd"])
        #expect(XMLTV.nameKeys(" - ").isEmpty)
    }

    /// gzip with a file name in the header (FNAME), as `gzip guide.xml` makes it.
    private static let zipped = Data(base64Encoded: "H4sICAAAAAAC/2d1aWRlLnhtbABVjk0KAjEMha9SshVtOwtXaQev4S7YoIX+0ZZBb2+HGWQMJOTxhfeC8zsGsXBtPicD+qJgttgXi48XpcRBeGeAwKLzrQT6nBNFtjeUfxrlfm6x1PysFCOL1ql2A5Oarlrp0WuJ0zphwFwOTB/Z7rXldt8D27svhR3KTaH8pYx9fPsFhUHKiscAAAA=")!
    private static let zippedChannel = Channel(id: "a", name: "A", url: URL(string: "http://x/a")!, guideID: "a")

    @Test func unpacksGzippedGuides() throws {
        let packed = Self.zipped
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("guide.xml.gz")
        let destination = directory.appendingPathComponent("guide.xml")
        try packed.write(to: source)

        #expect(try XMLTV.isGzip(source))
        try XMLTV.gunzip(source, to: destination)
        #expect(try Data(contentsOf: destination).count == 199)

        let channel = Self.zippedChannel
        let guide = try XMLTV.parse(contentsOf: destination, wanted: XMLTV.Wanted([channel]), window: Self.window)
        #expect(guide.programmes(for: channel).map(\.title) == ["Zipped"])
    }

    @Test func downloadsAndUnpacksAGuide() async throws {
        StubURLProtocol.stubData(host: "gz.epg.test") { _ in (200, Self.zipped) }
        let channel = Self.zippedChannel
        let guide = try await XMLTV.load(URL(string: "http://gz.epg.test/epg.xml.gz")!, wanted: XMLTV.Wanted([channel]), window: Self.window)
        #expect(guide.programmes(for: channel).map(\.title) == ["Zipped"])
    }

    @Test func missingGuideIsAnError() async {
        StubURLProtocol.stub(host: "missing.epg.test") { _ in (404, "Not found") }
        await #expect(throws: URLError.self) {
            try await XMLTV.load(URL(string: "http://missing.epg.test/epg.xml")!, wanted: XMLTV.Wanted([Self.zippedChannel]), window: Self.window)
        }
    }

    /// One download per source serves every channel and every later lookup.
    @Test func programGuideReadsTheSourceGuideOnce() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        func stamp(_ offset: TimeInterval) -> String { formatter.string(from: Date.now.addingTimeInterval(offset)) + " +0000" }
        let xml = """
        <tv><channel id="n"><display-name>N</display-name></channel>
        <programme start="\(stamp(-600))" stop="\(stamp(600))" channel="n"><title>On air</title></programme>
        <programme start="\(stamp(600))" stop="\(stamp(1800))" channel="n"><title>Later</title></programme></tv>
        """
        StubURLProtocol.stub(host: "once.epg.test") { _ in (200, xml) }

        let news = Channel(id: "n1", name: "N", url: URL(string: "http://x/n")!, guideID: "n")
        let other = Channel(id: "o1", name: "Other", url: URL(string: "http://x/o")!)
        let sourceID = UUID()
        let url = URL(string: "http://once.epg.test/epg.xml")!
        let first = await ProgramGuide.shared.nowNext(.xmltv(sourceID: sourceID, url: url, channel: news, channels: [news, other]))
        let second = await ProgramGuide.shared.nowNext(.xmltv(sourceID: sourceID, url: url, channel: other, channels: [news, other]))
        let again = await ProgramGuide.shared.nowNext(.xmltv(sourceID: sourceID, url: url, channel: news, channels: [news, other]))
        await ProgramGuide.shared.forget(sourceID)

        #expect(first.now?.title == "On air")
        #expect(first.next?.title == "Later")
        #expect(second.now == nil)
        #expect(again.now?.title == "On air")
        #expect(StubURLProtocol.requests(for: "once.epg.test").count == 1)
    }
}

struct PlaylistGuideTests {
    @Test func readsGuideLinksFromTheHeader() {
        let text = """
        #EXTM3U url-tvg="https://a.example/epg.xml.gz, https://b.example/epg.xml" x-tvg-url="https://a.example/epg.xml.gz"
        #EXTINF:-1 tvg-id="News.uk" group-title="News",Mock News
        http://example.com/news.m3u8
        """
        let playlist = M3UParser.parsePlaylist(text)
        #expect(M3UParser.guideURLs(text).map(\.absoluteString) == ["https://a.example/epg.xml.gz", "https://b.example/epg.xml"])
        #expect(playlist.guideURL?.absoluteString == "https://a.example/epg.xml.gz")
        #expect(playlist.channels.first?.guideID == "News.uk")
    }

    @Test func playlistWithoutGuideHasNone() {
        let playlist = M3UParser.parsePlaylist("#EXTM3U\n#EXTINF:-1,One\nhttp://example.com/1.m3u8")
        #expect(playlist.guideURL == nil)
        #expect(playlist.channels.first?.guideID == nil)
    }

    @Test func userGuideWinsOverThePlaylists() {
        var source = Source(id: UUID(), name: "P", kind: .m3uFile(fileName: "p.m3u"), channelCount: 1, updatedAt: .now,
                            playlistGuideURL: URL(string: "https://a.example/epg.xml"))
        #expect(source.effectiveGuideURL?.host() == "a.example")
        source.guideURL = URL(string: "https://mine.example/epg.xml")
        #expect(source.effectiveGuideURL?.host() == "mine.example")
    }
}
