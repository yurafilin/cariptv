import Foundation
import Testing
@testable import CarIPTV

struct M3UParserTests {
    @Test func parsesAttributesAndTitle() throws {
        let channels = M3UParser.parse("""
        #EXTM3U
        #EXTINF:-1 tvg-id="bbc1" tvg-name="BBC One" tvg-logo="http://logo/bbc.png" group-title="UK",BBC One HD
        http://example.com/bbc1.m3u8
        """)
        let channel = try #require(channels.first)
        #expect(channels.count == 1)
        #expect(channel.name == "BBC One HD")
        #expect(channel.group == "UK")
        #expect(channel.logo == URL(string: "http://logo/bbc.png"))
        #expect(channel.url == URL(string: "http://example.com/bbc1.m3u8"))
    }

    @Test func titleMayContainCommasAndAttributesMayToo() {
        let channels = M3UParser.parse("""
        #EXTINF:-1 group-title="News, World",Channel, with comma
        https://example.com/a.m3u8
        """)
        #expect(channels.first?.name == "Channel, with comma")
        #expect(channels.first?.group == "News, World")
    }

    @Test func handlesCRLFAndEXTGRP() {
        let channels = M3UParser.parse("#EXTM3U\r\n#EXTINF:-1,One\r\n#EXTGRP:Sports\r\nhttp://a/1\r\n")
        #expect(channels.count == 1)
        #expect(channels.first?.name == "One")
        #expect(channels.first?.group == "Sports")
    }

    @Test func bareURLsBecomeChannelsNamedByHost() {
        let channels = M3UParser.parse("http://stream.example.com/live.m3u8\n")
        #expect(channels.first?.name == "stream.example.com")
        #expect(channels.first?.group == nil)
    }

    @Test func skipsCommentsAndGarbage() {
        let channels = M3UParser.parse("""
        #EXTM3U
        #EXTVLCOPT:http-user-agent=VLC
        not a url
        #EXTINF:-1,Good
        http://a/good
        """)
        #expect(channels.map(\.name) == ["Good"])
    }

    @Test func duplicateURLsGetUniqueIDs() {
        let channels = M3UParser.parse("""
        #EXTINF:-1 group-title="A",One
        http://a/same
        #EXTINF:-1 group-title="B",One again
        http://a/same
        """)
        #expect(channels.count == 2)
        #expect(Set(channels.map(\.id)).count == 2)
    }

    @Test func infoWithoutTitleFallsBackToTvgName() {
        let channels = M3UParser.parse("""
        #EXTINF:-1 tvg-name="Fallback"
        http://a/x
        """)
        #expect(channels.first?.name == "Fallback")
    }
}

struct XtreamTests {
    @Test(arguments: [
        ("example.com:8080", "http://example.com:8080"),
        ("http://example.com:8080/", "http://example.com:8080"),
        ("https://example.com/player_api.php?username=a&password=b", "https://example.com"),
        ("http://example.com/get.php", "http://example.com"),
    ])
    func normalizesServer(input: String, expected: String) {
        #expect(XtreamClient.normalizedServer(input)?.absoluteString == expected)
    }

    @Test func rejectsEmptyServer() {
        #expect(XtreamClient.normalizedServer("  ") == nil)
    }

    @Test func buildsHLSStreamURL() {
        let client = XtreamClient(server: URL(string: "http://example.com:8080")!, username: "user", password: "pass")
        #expect(client.streamURL(streamID: "42").absoluteString == "http://example.com:8080/live/user/pass/42.m3u8")
    }

    @Test func looseStringDecodesNumbersAndStrings() throws {
        let decoded = try JSONDecoder().decode([LooseString].self, from: Data(#"[1, "2", 3.5, true, null, ""]"#.utf8))
        #expect(decoded.map(\.value) == ["1", "2", "3.5", "1", nil, nil])
    }
}

struct BrowserAddressTests {
    @Test func keepsFullURLs() {
        #expect(BrowserModel.url(from: "https://vimeo.com/123")?.absoluteString == "https://vimeo.com/123")
    }

    @Test func addsSchemeToDomains() {
        #expect(BrowserModel.url(from: "youtube.com")?.absoluteString == "https://youtube.com")
    }

    @Test func siteAddressesAreSitesOnly() {
        #expect(BrowserModel.siteURL(from: " example.com ")?.absoluteString == "https://example.com")
        #expect(BrowserModel.siteURL(from: "http://tv.example.org/live")?.absoluteString == "http://tv.example.org/live")
        #expect(BrowserModel.siteURL(from: "funny cats") == nil)
        #expect(BrowserModel.siteURL(from: "localhost") == nil)
        #expect(BrowserModel.siteURL(from: "ftp://example.com") == nil)
        #expect(BrowserModel.siteURL(from: "") == nil)
    }

    @Test func siteNameIsTheDomainWithoutWWW() {
        #expect(BrowserModel.siteName(URL(string: "https://www.example.com/x")!) == "example.com")
        #expect(BrowserModel.siteName(URL(string: "https://tv.example.org")!) == "tv.example.org")
    }

    @Test func searchesEverythingElse() {
        let url = BrowserModel.url(from: "cat videos")
        #expect(url?.host() == "www.google.com")
        #expect(url?.query()?.contains("q=cat%20videos") == true)
    }
}
