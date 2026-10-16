import Foundation
import Testing
@testable import CarIPTV

struct ChannelStepTests {
    private let ids = ["a", "b", "c"]

    @Test func stepsForwardAndBackWithWrapAround() {
        #expect(PlaybackController.index(of: "a", in: ids, offset: 1) == 1)
        #expect(PlaybackController.index(of: "c", in: ids, offset: 1) == 0)
        #expect(PlaybackController.index(of: "a", in: ids, offset: -1) == 2)
        #expect(PlaybackController.index(of: "b", in: ids, offset: -4) == 0)
    }

    @Test func unknownItemOrEmptyQueueGoesNowhere() {
        #expect(PlaybackController.index(of: "z", in: ids, offset: 1) == nil)
        #expect(PlaybackController.index(of: "a", in: [], offset: 1) == nil)
    }
}

struct ProgramGuideTests {
    @Test func decodesBase64TitlesAndTimestamps() async throws {
        StubURLProtocol.stub(host: "epg.xtream.test") { request in
            guard request.url?.query()?.contains("action=get_short_epg") == true,
                  request.url?.query()?.contains("stream_id=7") == true else { return (404, "") }
            let news = Data("Evening News".utf8).base64EncodedString()
            return (200, #"{"epg_listings":[{"title":"\#(news)","start_timestamp":"1000","stop_timestamp":"2000"},{"title":"Plain title","start_timestamp":2000,"stop_timestamp":3000}]}"#)
        }
        let client = XtreamClient(server: URL(string: "http://epg.xtream.test")!, username: "u", password: "p")
        let programmes = try await client.shortEPG(streamID: "7")
        #expect(programmes.map(\.title) == ["Evening News", "Plain title"])
        #expect(programmes[0].start == Date(timeIntervalSince1970: 1000))
        #expect(programmes[1].end == Date(timeIntervalSince1970: 3000))
    }

    @Test func panelWithoutGuideGivesNothing() async throws {
        StubURLProtocol.stub(host: "noepg.xtream.test") { _ in (200, #"{"epg_listings":false}"#) }
        let client = XtreamClient(server: URL(string: "http://noepg.xtream.test")!, username: "u", password: "p")
        #expect(try await client.shortEPG(streamID: "1").isEmpty)
    }

    @Test func picksNowAndNext() {
        let programmes = [
            Programme(title: "Later", start: Date(timeIntervalSince1970: 300), end: Date(timeIntervalSince1970: 400)),
            Programme(title: "Earlier", start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 100)),
            Programme(title: "Current", start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 300)),
        ]
        let guide = ProgramGuide.nowNext(programmes, at: Date(timeIntervalSince1970: 150))
        #expect(guide.now?.title == "Current")
        #expect(guide.next?.title == "Later")
        #expect(ProgramGuide.nowNext(programmes, at: Date(timeIntervalSince1970: 500)).now == nil)
    }
}
