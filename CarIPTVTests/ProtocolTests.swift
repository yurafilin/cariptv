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

struct UPnPTests {
    @Test func readsActionFromSOAPActionHeader() {
        #expect(UPnP.actionName(fromSOAPAction: "\"urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI\"") == "SetAVTransportURI")
        #expect(UPnP.actionName(fromSOAPAction: nil) == nil)
    }

    @Test func parsesSOAPArgumentsAndDIDLTitle() throws {
        let metadata = UPnP.escape("""
        <DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/"><item><dc:title>Road trip</dc:title></item></DIDL-Lite>
        """)
        let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>\
        <u:SetAVTransportURI xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">\
        <InstanceID>0</InstanceID><CurrentURI>http://192.168.1.5/video.mp4?a=1&amp;b=2</CurrentURI>\
        <CurrentURIMetaData>\(metadata)</CurrentURIMetaData></u:SetAVTransportURI></s:Body></s:Envelope>
        """
        let arguments = UPnP.arguments(Data(body.utf8))
        #expect(arguments["InstanceID"] == "0")
        #expect(arguments["CurrentURI"] == "http://192.168.1.5/video.mp4?a=1&b=2")
        let title = try #require(arguments["CurrentURIMetaData"].flatMap(UPnP.title(fromDIDL:)))
        #expect(title == "Road trip")
    }

    @Test func convertsTimes() {
        #expect(UPnP.seconds(fromTime: "01:02:03") == 3723)
        #expect(UPnP.seconds(fromTime: "0:00:05.500") == 5.5)
        #expect(UPnP.seconds(fromTime: "garbage") == nil)
        #expect(UPnP.time(fromSeconds: 3723) == "01:02:03")
        #expect(UPnP.time(fromSeconds: nil) == "00:00:00")
    }

    @Test func serviceDescriptionsAreWellFormedXML() {
        for service in UPnP.Service.allCases {
            let parser = XMLParser(data: Data(UPnP.serviceDescription(service).utf8))
            #expect(parser.parse(), "\(service.rawValue) SCPD")
        }
        let device = XMLParser(data: Data(UPnP.deviceDescription(friendlyName: "Car & IPTV", udn: "uuid:1").utf8))
        #expect(device.parse())
    }

    @Test func parsesHTTPRequestOnlyWhenBodyIsComplete() throws {
        let head = "POST /AVTransport/control HTTP/1.1\r\nSOAPACTION: \"x#Play\"\r\nContent-Length: 4\r\n\r\n"
        #expect(HTTPServer.parse(Data((head + "ab").utf8)) == nil)
        let request = try #require(HTTPServer.parse(Data((head + "abcd").utf8)))
        #expect(request.method == "POST")
        #expect(request.path == "/AVTransport/control")
        #expect(request.headers["soapaction"] == "\"x#Play\"")
        #expect(request.body == Data("abcd".utf8))
    }

    @Test func ssdpHeadersAreCaseInsensitiveAndUnquoted() {
        let headers = SSDPResponder.headers("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMan: \"ssdp:discover\"\r\nST: ssdp:all\r\n\r\n")
        #expect(headers["man"] == "ssdp:discover")
        #expect(headers["st"] == "ssdp:all")
    }
}
