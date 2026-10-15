import Foundation

/// UPnP MediaRenderer documents and SOAP helpers: what DLNA control points (the Cast button
/// in other apps) expect from a renderer.
enum UPnP {
    enum Service: String, CaseIterable {
        case avTransport = "AVTransport"
        case renderingControl = "RenderingControl"
        case connectionManager = "ConnectionManager"

        var type: String { "urn:schemas-upnp-org:service:\(rawValue):1" }
        var scpdPath: String { "/\(rawValue).xml" }
        var controlPath: String { "/\(rawValue)/control" }
        var eventPath: String { "/\(rawValue)/event" }

        init?(controlPath: String) {
            guard let service = Service.allCases.first(where: { $0.controlPath == controlPath }) else { return nil }
            self = service
        }
    }

    static let sinkProtocolInfo = [
        "http-get:*:video/mp4:*",
        "http-get:*:video/x-m4v:*",
        "http-get:*:video/quicktime:*",
        "http-get:*:video/mpeg:*",
        "http-get:*:video/mp2t:*",
        "http-get:*:application/vnd.apple.mpegurl:*",
        "http-get:*:application/x-mpegURL:*",
        "http-get:*:video/*:*",
        "http-get:*:audio/mpeg:*",
        "http-get:*:audio/mp4:*",
        "http-get:*:audio/*:*",
    ].joined(separator: ",")

    // MARK: - Device description

    static func deviceDescription(friendlyName: String, udn: String) -> String {
        let services = Service.allCases.map { service in
            """
            <service><serviceType>\(service.type)</serviceType><serviceId>urn:upnp-org:serviceId:\(service.rawValue)</serviceId>\
            <SCPDURL>\(service.scpdPath)</SCPDURL><controlURL>\(service.controlPath)</controlURL><eventSubURL>\(service.eventPath)</eventSubURL></service>
            """
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <root xmlns="urn:schemas-upnp-org:device-1-0" xmlns:dlna="urn:schemas-dlna-org:device-1-0">\
        <specVersion><major>1</major><minor>0</minor></specVersion><device>\
        <deviceType>\(SSDPResponder.deviceType)</deviceType>\
        <friendlyName>\(escape(friendlyName))</friendlyName>\
        <manufacturer>Weappico</manufacturer><manufacturerURL>https://cariptv.com</manufacturerURL>\
        <modelDescription>CarIPTV video receiver</modelDescription><modelName>CarIPTV</modelName><modelNumber>1</modelNumber>\
        <UDN>\(udn)</UDN><dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>\
        <serviceList>\(services)</serviceList></device></root>
        """
    }

    // MARK: - Service descriptions

    private typealias Argument = (name: String, out: Bool, variable: String)
    private typealias Variable = (name: String, type: String, events: Bool)

    static func serviceDescription(_ service: Service) -> String {
        let (actions, variables) = definition(service)
        let actionXML = actions.map { name, arguments in
            let args = arguments.map {
                "<argument><name>\($0.name)</name><direction>\($0.out ? "out" : "in")</direction><relatedStateVariable>\($0.variable)</relatedStateVariable></argument>"
            }.joined()
            return "<action><name>\(name)</name><argumentList>\(args)</argumentList></action>"
        }.joined()
        let variableXML = variables.map {
            "<stateVariable sendEvents=\"\($0.events ? "yes" : "no")\"><name>\($0.name)</name><dataType>\($0.type)</dataType></stateVariable>"
        }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <scpd xmlns="urn:schemas-upnp-org:service-1-0"><specVersion><major>1</major><minor>0</minor></specVersion>\
        <actionList>\(actionXML)</actionList><serviceStateTable>\(variableXML)</serviceStateTable></scpd>
        """
    }

    private static func definition(_ service: Service) -> (actions: [(String, [Argument])], variables: [Variable]) {
        let instance: Argument = ("InstanceID", false, "A_ARG_TYPE_InstanceID")
        switch service {
        case .avTransport:
            return (
                [
                    ("SetAVTransportURI", [instance, ("CurrentURI", false, "AVTransportURI"), ("CurrentURIMetaData", false, "AVTransportURIMetaData")]),
                    ("Play", [instance, ("Speed", false, "TransportPlaySpeed")]),
                    ("Pause", [instance]),
                    ("Stop", [instance]),
                    ("Seek", [instance, ("Unit", false, "A_ARG_TYPE_SeekMode"), ("Target", false, "A_ARG_TYPE_SeekTarget")]),
                    ("GetTransportInfo", [instance, ("CurrentTransportState", true, "TransportState"), ("CurrentTransportStatus", true, "TransportStatus"), ("CurrentSpeed", true, "TransportPlaySpeed")]),
                    ("GetPositionInfo", [
                        instance, ("Track", true, "CurrentTrack"), ("TrackDuration", true, "CurrentTrackDuration"),
                        ("TrackMetaData", true, "CurrentTrackMetaData"), ("TrackURI", true, "CurrentTrackURI"),
                        ("RelTime", true, "RelativeTimePosition"), ("AbsTime", true, "AbsoluteTimePosition"),
                        ("RelCount", true, "RelativeCounterPosition"), ("AbsCount", true, "AbsoluteCounterPosition"),
                    ]),
                    ("GetMediaInfo", [
                        instance, ("NrTracks", true, "NumberOfTracks"), ("MediaDuration", true, "CurrentMediaDuration"),
                        ("CurrentURI", true, "AVTransportURI"), ("CurrentURIMetaData", true, "AVTransportURIMetaData"),
                        ("NextURI", true, "NextAVTransportURI"), ("NextURIMetaData", true, "NextAVTransportURIMetaData"),
                        ("PlayMedium", true, "PlaybackStorageMedium"), ("RecordMedium", true, "RecordStorageMedium"),
                        ("WriteStatus", true, "RecordMediumWriteStatus"),
                    ]),
                    ("GetTransportSettings", [instance, ("PlayMode", true, "CurrentPlayMode"), ("RecQualityMode", true, "CurrentRecordQualityMode")]),
                    ("GetCurrentTransportActions", [instance, ("Actions", true, "CurrentTransportActions")]),
                    ("GetDeviceCapabilities", [instance, ("PlayMedia", true, "PossiblePlaybackStorageMedia"), ("RecMedia", true, "PossibleRecordStorageMedia"), ("RecQualityModes", true, "PossibleRecordQualityModes")]),
                ],
                [
                    ("A_ARG_TYPE_InstanceID", "ui4", false), ("AVTransportURI", "string", false), ("AVTransportURIMetaData", "string", false),
                    ("TransportPlaySpeed", "string", false), ("A_ARG_TYPE_SeekMode", "string", false), ("A_ARG_TYPE_SeekTarget", "string", false),
                    ("TransportState", "string", false), ("TransportStatus", "string", false), ("CurrentTrack", "ui4", false),
                    ("CurrentTrackDuration", "string", false), ("CurrentTrackMetaData", "string", false), ("CurrentTrackURI", "string", false),
                    ("RelativeTimePosition", "string", false), ("AbsoluteTimePosition", "string", false),
                    ("RelativeCounterPosition", "i4", false), ("AbsoluteCounterPosition", "i4", false), ("NumberOfTracks", "ui4", false),
                    ("CurrentMediaDuration", "string", false), ("NextAVTransportURI", "string", false), ("NextAVTransportURIMetaData", "string", false),
                    ("PlaybackStorageMedium", "string", false), ("RecordStorageMedium", "string", false), ("RecordMediumWriteStatus", "string", false),
                    ("CurrentPlayMode", "string", false), ("CurrentRecordQualityMode", "string", false), ("CurrentTransportActions", "string", false),
                    ("PossiblePlaybackStorageMedia", "string", false), ("PossibleRecordStorageMedia", "string", false),
                    ("PossibleRecordQualityModes", "string", false), ("LastChange", "string", true),
                ]
            )
        case .renderingControl:
            let channel: Argument = ("Channel", false, "A_ARG_TYPE_Channel")
            return (
                [
                    ("GetVolume", [instance, channel, ("CurrentVolume", true, "Volume")]),
                    ("SetVolume", [instance, channel, ("DesiredVolume", false, "Volume")]),
                    ("GetMute", [instance, channel, ("CurrentMute", true, "Mute")]),
                    ("SetMute", [instance, channel, ("DesiredMute", false, "Mute")]),
                ],
                [
                    ("A_ARG_TYPE_InstanceID", "ui4", false), ("A_ARG_TYPE_Channel", "string", false),
                    ("Volume", "ui2", false), ("Mute", "boolean", false), ("LastChange", "string", true),
                ]
            )
        case .connectionManager:
            return (
                [
                    ("GetProtocolInfo", [("Source", true, "SourceProtocolInfo"), ("Sink", true, "SinkProtocolInfo")]),
                    ("GetCurrentConnectionIDs", [("ConnectionIDs", true, "CurrentConnectionIDs")]),
                    ("GetCurrentConnectionInfo", [
                        ("ConnectionID", false, "A_ARG_TYPE_ConnectionID"), ("RcsID", true, "A_ARG_TYPE_RcsID"),
                        ("AVTransportID", true, "A_ARG_TYPE_AVTransportID"), ("ProtocolInfo", true, "A_ARG_TYPE_ProtocolInfo"),
                        ("PeerConnectionManager", true, "A_ARG_TYPE_ConnectionManager"), ("PeerConnectionID", true, "A_ARG_TYPE_ConnectionID"),
                        ("Direction", true, "A_ARG_TYPE_Direction"), ("Status", true, "A_ARG_TYPE_ConnectionStatus"),
                    ]),
                ],
                [
                    ("SourceProtocolInfo", "string", true), ("SinkProtocolInfo", "string", true), ("CurrentConnectionIDs", "string", true),
                    ("A_ARG_TYPE_ConnectionStatus", "string", false), ("A_ARG_TYPE_ConnectionManager", "string", false),
                    ("A_ARG_TYPE_Direction", "string", false), ("A_ARG_TYPE_ProtocolInfo", "string", false),
                    ("A_ARG_TYPE_ConnectionID", "i4", false), ("A_ARG_TYPE_AVTransportID", "i4", false), ("A_ARG_TYPE_RcsID", "i4", false),
                ]
            )
        }
    }

    // MARK: - SOAP

    /// `"urn:schemas-upnp-org:service:AVTransport:1#Play"` → `Play`
    static func actionName(fromSOAPAction header: String?) -> String? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard let hash = trimmed.lastIndex(of: "#") else { return nil }
        let name = trimmed[trimmed.index(after: hash)...]
        return name.isEmpty ? nil : String(name)
    }

    /// Arguments of the action element: `<s:Envelope><s:Body><u:Action><Arg>value</Arg>…`
    static func arguments(_ body: Data) -> [String: String] {
        let collector = ElementTextCollector(depth: 4)
        let parser = XMLParser(data: body)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        return collector.values
    }

    static func response(action: String, service: Service, values: [(String, String)] = []) -> String {
        let arguments = values.map { "<\($0.0)>\(escape($0.1))</\($0.0)>" }.joined()
        return envelope("<u:\(action)Response xmlns:u=\"\(service.type)\">\(arguments)</u:\(action)Response>")
    }

    static func fault(code: Int, description: String) -> String {
        envelope("""
        <s:Fault><faultcode>s:Client</faultcode><faultstring>UPnPError</faultstring><detail>\
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0"><errorCode>\(code)</errorCode>\
        <errorDescription>\(escape(description))</errorDescription></UPnPError></detail></s:Fault>
        """)
    }

    private static func envelope(_ body: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    // MARK: - Events

    static func lastChangeEvent(transportState: String) -> String {
        let inner = "<Event xmlns=\"urn:schemas-upnp-org:metadata-1-0/AVT/\"><InstanceID val=\"0\"><TransportState val=\"\(transportState)\"/></InstanceID></Event>"
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0"><e:property><LastChange>\(escape(inner))</LastChange></e:property></e:propertyset>
        """
    }

    // MARK: - DIDL-Lite and time

    /// `dc:title` from DIDL-Lite metadata, if any.
    static func title(fromDIDL metadata: String) -> String? {
        guard !metadata.isEmpty, let data = metadata.data(using: .utf8) else { return nil }
        let collector = ElementTextCollector(names: ["title"])
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = collector
        parser.parse()
        guard let title = collector.values["title"]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    /// `H:MM:SS(.fff)` → seconds.
    static func seconds(fromTime text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Seconds → `HH:MM:SS`.
    static func time(fromSeconds value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "00:00:00" }
        let total = Int(value)
        return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// Collects element text by local name: either every element at one depth, or the named elements.
private final class ElementTextCollector: NSObject, XMLParserDelegate {
    private let depth: Int?
    private let names: Set<String>?
    private var currentDepth = 0
    private var current: String?
    private var text = ""
    private(set) var values: [String: String] = [:]

    init(depth: Int) {
        self.depth = depth
        names = nil
    }

    init(names: Set<String>) {
        depth = nil
        self.names = names
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        currentDepth += 1
        let wanted = depth.map { $0 == currentDepth } ?? (names?.contains(elementName) ?? false)
        if wanted, values[elementName] == nil {
            current = elementName
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if current != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == current {
            values[elementName] = text
            current = nil
        }
        currentDepth -= 1
    }
}
