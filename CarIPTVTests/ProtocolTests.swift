import Foundation
import Testing
@testable import CarIPTV

struct MirrorProtocolTests {
    @Test func frameRoundTripsAcrossSplitChunks() throws {
        let frame = MirrorProtocol.Frame(isKeyframe: true, orientation: 6, ptsMicroseconds: 123_456, data: Data([0, 0, 0, 1, 0x65, 0xAA]))
        let stream = MirrorProtocol.helloPacket() + MirrorProtocol.framePacket(frame)

        var parser = MirrorPacketParser()
        var packets: [(MirrorProtocol.MessageType, Data)] = []
        for byte in stream {
            let chunk = parser.append(Data([byte]))
            packets += try #require(chunk)
        }

        #expect(packets.map(\.0) == [.hello, .frame])
        let parsed = try #require(MirrorProtocol.parseFrame(packets[1].1))
        #expect(parsed.isKeyframe)
        #expect(parsed.orientation == 6)
        #expect(parsed.ptsMicroseconds == 123_456)
        #expect(parsed.data == frame.data)
    }

    @Test func parameterSetsRoundTrip() throws {
        let sets = [Data([0x67, 1, 2, 3]), Data([0x68, 9])]
        var parser = MirrorPacketParser()
        let result = parser.append(MirrorProtocol.parameterSetsPacket(sets))
        let packets = try #require(result)
        #expect(MirrorProtocol.parseParameterSets(packets[0].1) == sets)
    }

    @Test func rejectsAbsurdLength() {
        var parser = MirrorPacketParser()
        #expect(parser.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 1])) == nil)
    }

    @Test func skipsUnknownMessageTypes() throws {
        var unknown = Data()
        unknown.appendBigEndian(UInt32(2))
        unknown.append(contentsOf: [99, 0])
        var parser = MirrorPacketParser()
        let result = parser.append(unknown + MirrorProtocol.packet(.bye))
        let packets = try #require(result)
        #expect(packets.map(\.0) == [.bye])
    }
}

struct HTTPServerTests {
    @Test func parsesHTTPRequestOnlyWhenBodyIsComplete() throws {
        let head = "POST /hls/1/index.m3u8?_HLS_msn=3 HTTP/1.1\r\nX-Test: \"a\"\r\nContent-Length: 4\r\n\r\n"
        #expect(HTTPServer.parse(Data((head + "ab").utf8)) == nil)
        let request = try #require(HTTPServer.parse(Data((head + "abcd").utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/hls/1/index.m3u8")
        #expect(request.headers["x-test"] == "\"a\"")
        #expect(request.body == Data("abcd".utf8))
    }
}
