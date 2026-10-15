import Darwin
import Foundation
import Observation

/// DLNA/UPnP media renderer: other apps' Cast button finds "CarIPTV" on the Wi-Fi network and
/// hands over a video URL, which plays through `PlaybackController` and so on the car display.
/// Runs while CarPlay is connected or the Cast screen is open.
@MainActor @Observable
final class CastReceiver {
    static let shared = CastReceiver()

    enum Reason: Hashable {
        case carPlay
        case castScreen
    }

    enum Status: Equatable {
        case stopped
        case needsWiFi
        case running
        case failed(String)
    }

    let friendlyName = "CarIPTV"
    private(set) var status: Status = .stopped
    /// Title of the last video another app cast here.
    private(set) var lastCastTitle: String?

    @ObservationIgnored private var reasons: Set<Reason> = []
    @ObservationIgnored private var server: HTTPServer?
    @ObservationIgnored private var ssdp: SSDPResponder?
    @ObservationIgnored private var address: String?
    @ObservationIgnored private let udn: String
    @ObservationIgnored private var transportURI: String = ""
    @ObservationIgnored private var transportMetadata: String = ""
    @ObservationIgnored private var subscribers: [String: URL] = [:]
    @ObservationIgnored private var eventSequence = 0
    @ObservationIgnored private var stateObserver: StateObserver?
    @ObservationIgnored private var lastEventState: String?

    private init() {
        let key = "cast.deviceUUID"
        if let saved = UserDefaults.standard.string(forKey: key) {
            udn = "uuid:\(saved)"
        } else {
            let id = UUID().uuidString.lowercased()
            UserDefaults.standard.set(id, forKey: key)
            udn = "uuid:\(id)"
        }
    }

    func setActive(_ active: Bool, for reason: Reason) {
        if active {
            reasons.insert(reason)
        } else {
            reasons.remove(reason)
        }
        if reasons.isEmpty {
            stop()
        } else if status != .running {
            start()
        }
    }

    // MARK: - Lifecycle

    private func start() {
        guard server == nil else { return }
        guard let address = Self.localIPv4Address() else {
            status = .needsWiFi
            Log.cast.info("cast: no Wi-Fi address")
            return
        }
        self.address = address

        let server = HTTPServer { request, reply in
            Task { @MainActor in
                reply(CastReceiver.shared.respond(to: request))
            }
        }
        server.onReady = { port in
            Task { @MainActor in CastReceiver.shared.serverReady(port: port) }
        }
        server.onFailure = { message in
            Task { @MainActor in CastReceiver.shared.fail(message) }
        }
        self.server = server
        server.start()
    }

    private func serverReady(port: UInt16) {
        guard let address, server != nil else { return }
        let location = "http://\(address):\(port)/description.xml"
        Log.cast.info("cast: renderer at \(location)")
        let ssdp = SSDPResponder(udn: udn, location: location)
        ssdp.onFailure = { message in
            Task { @MainActor in CastReceiver.shared.fail(message) }
        }
        self.ssdp = ssdp
        ssdp.start()
        status = .running
        stateObserver = StateObserver { [weak self] in
            self?.playbackChanged()
        }
    }

    private func stop() {
        stateObserver?.cancel()
        stateObserver = nil
        ssdp?.stop()
        ssdp = nil
        server?.stop()
        server = nil
        subscribers = [:]
        status = .stopped
    }

    private func fail(_ message: String) {
        Log.cast.error("cast: \(message)")
        stop()
        status = .failed(message)
    }

    /// Retry after the user joined Wi-Fi or a failure.
    func restart() {
        guard !reasons.isEmpty else { return }
        stop()
        start()
    }

    // MARK: - HTTP

    private func respond(to request: HTTPServer.Request) -> HTTPServer.Response {
        switch (request.method, request.path) {
        case ("GET", "/description.xml"):
            return .xml(UPnP.deviceDescription(friendlyName: friendlyName, udn: udn))
        case ("GET", let path):
            if let service = UPnP.Service.allCases.first(where: { $0.scpdPath == path }) {
                return .xml(UPnP.serviceDescription(service))
            }
            return .empty(404)
        case ("POST", let path):
            guard let service = UPnP.Service(controlPath: path),
                  let action = UPnP.actionName(fromSOAPAction: request.headers["soapaction"]) else { return .empty(400) }
            return control(service, action: action, arguments: UPnP.arguments(request.body))
        case ("SUBSCRIBE", let path):
            return subscribe(path: path, headers: request.headers)
        case ("UNSUBSCRIBE", _):
            if let sid = request.headers["sid"] {
                subscribers[sid] = nil
            }
            return .empty(200)
        default:
            return .empty(405)
        }
    }

    private func control(_ service: UPnP.Service, action: String, arguments: [String: String]) -> HTTPServer.Response {
        Log.cast.info("cast: \(service.rawValue)#\(action)")
        let playback = PlaybackController.shared
        let ok = HTTPServer.Response.xml(UPnP.response(action: action, service: service))

        switch (service, action) {
        case (.avTransport, "SetAVTransportURI"):
            guard let uri = arguments["CurrentURI"], let url = URL(string: uri) else {
                return .xml(UPnP.fault(code: 714, description: "Illegal MIME-type"), status: 500)
            }
            transportURI = uri
            transportMetadata = arguments["CurrentURIMetaData"] ?? ""
            let title = UPnP.title(fromDIDL: transportMetadata) ?? url.lastPathComponent
            lastCastTitle = title
            playback.play(PlayableMedia(title: title, subtitle: String(localized: "Cast from an app"), url: url, isLive: false))
            return ok
        case (.avTransport, "Play"):
            if isCastPlaying { playback.resume() }
            return ok
        case (.avTransport, "Pause"):
            if isCastPlaying { playback.pause() }
            return ok
        case (.avTransport, "Stop"):
            if isCastPlaying { playback.stop() }
            return ok
        case (.avTransport, "Seek"):
            if isCastPlaying, let target = arguments["Target"], let seconds = UPnP.seconds(fromTime: target) {
                playback.seek(to: seconds)
            }
            return ok
        case (.avTransport, "GetTransportInfo"):
            return .xml(UPnP.response(action: action, service: service, values: [
                ("CurrentTransportState", transportState),
                ("CurrentTransportStatus", isCastPlaying && Self.isFailed(playback.state) ? "ERROR_OCCURRED" : "OK"),
                ("CurrentSpeed", "1"),
            ]))
        case (.avTransport, "GetPositionInfo"):
            let position: (elapsed: Double, duration: Double?) = isCastPlaying ? playback.position : (0, nil)
            return .xml(UPnP.response(action: action, service: service, values: [
                ("Track", isCastPlaying ? "1" : "0"),
                ("TrackDuration", UPnP.time(fromSeconds: position.duration)),
                ("TrackMetaData", transportMetadata),
                ("TrackURI", transportURI),
                ("RelTime", UPnP.time(fromSeconds: position.elapsed)),
                ("AbsTime", UPnP.time(fromSeconds: position.elapsed)),
                ("RelCount", "2147483647"),
                ("AbsCount", "2147483647"),
            ]))
        case (.avTransport, "GetMediaInfo"):
            let duration = isCastPlaying ? playback.position.duration : nil
            return .xml(UPnP.response(action: action, service: service, values: [
                ("NrTracks", transportURI.isEmpty ? "0" : "1"),
                ("MediaDuration", UPnP.time(fromSeconds: duration)),
                ("CurrentURI", transportURI),
                ("CurrentURIMetaData", transportMetadata),
                ("NextURI", ""),
                ("NextURIMetaData", ""),
                ("PlayMedium", "NETWORK"),
                ("RecordMedium", "NOT_IMPLEMENTED"),
                ("WriteStatus", "NOT_IMPLEMENTED"),
            ]))
        case (.avTransport, "GetTransportSettings"):
            return .xml(UPnP.response(action: action, service: service, values: [("PlayMode", "NORMAL"), ("RecQualityMode", "NOT_IMPLEMENTED")]))
        case (.avTransport, "GetCurrentTransportActions"):
            return .xml(UPnP.response(action: action, service: service, values: [("Actions", "Play,Pause,Stop,Seek")]))
        case (.avTransport, "GetDeviceCapabilities"):
            return .xml(UPnP.response(action: action, service: service, values: [
                ("PlayMedia", "NETWORK"), ("RecMedia", "NOT_IMPLEMENTED"), ("RecQualityModes", "NOT_IMPLEMENTED"),
            ]))

        case (.renderingControl, "GetVolume"):
            return .xml(UPnP.response(action: action, service: service, values: [("CurrentVolume", String(Int(playback.player.volume * 100)))]))
        case (.renderingControl, "SetVolume"):
            if let value = arguments["DesiredVolume"].flatMap(Int.init) {
                playback.player.volume = Float(min(max(value, 0), 100)) / 100
            }
            return ok
        case (.renderingControl, "GetMute"):
            return .xml(UPnP.response(action: action, service: service, values: [("CurrentMute", playback.player.isMuted ? "1" : "0")]))
        case (.renderingControl, "SetMute"):
            let value = arguments["DesiredMute"]?.lowercased()
            playback.player.isMuted = value == "1" || value == "true"
            return ok

        case (.connectionManager, "GetProtocolInfo"):
            return .xml(UPnP.response(action: action, service: service, values: [("Source", ""), ("Sink", UPnP.sinkProtocolInfo)]))
        case (.connectionManager, "GetCurrentConnectionIDs"):
            return .xml(UPnP.response(action: action, service: service, values: [("ConnectionIDs", "0")]))
        case (.connectionManager, "GetCurrentConnectionInfo"):
            return .xml(UPnP.response(action: action, service: service, values: [
                ("RcsID", "0"), ("AVTransportID", "0"), ("ProtocolInfo", ""), ("PeerConnectionManager", ""),
                ("PeerConnectionID", "-1"), ("Direction", "Input"), ("Status", "OK"),
            ]))

        default:
            return .xml(UPnP.fault(code: 401, description: "Invalid Action"), status: 500)
        }
    }

    /// The player is busy with what was cast here, not with something the user picked since.
    private var isCastPlaying: Bool {
        guard !transportURI.isEmpty, let media = PlaybackController.shared.media else { return false }
        return media.url.absoluteString == transportURI
    }

    private static func isFailed(_ state: PlaybackController.State) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private var transportState: String {
        guard !transportURI.isEmpty else { return "NO_MEDIA_PRESENT" }
        guard isCastPlaying else { return "STOPPED" }
        switch PlaybackController.shared.state {
        case .playing: return "PLAYING"
        case .paused: return "PAUSED_PLAYBACK"
        case .loading: return "TRANSITIONING"
        case .idle, .failed: return "STOPPED"
        }
    }

    // MARK: - Events

    private func subscribe(path: String, headers: [String: String]) -> HTTPServer.Response {
        // Renewal: same SID, no callback.
        if let sid = headers["sid"] {
            return subscribers[sid] == nil ? .empty(412) : .empty(200, headers: ["SID": sid, "TIMEOUT": "Second-1800"])
        }
        guard path == UPnP.Service.avTransport.eventPath,
              let callback = headers["callback"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")),
              let url = URL(string: callback) else { return .empty(412) }
        let sid = "uuid:\(UUID().uuidString.lowercased())"
        subscribers[sid] = url
        // The initial event must follow the subscription response.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            CastReceiver.shared.sendEvent(to: sid)
        }
        return .empty(200, headers: ["SID": sid, "TIMEOUT": "Second-1800"])
    }

    private func playbackChanged() {
        let state = transportState
        guard state != lastEventState else { return }
        lastEventState = state
        for sid in subscribers.keys {
            sendEvent(to: sid)
        }
    }

    private func sendEvent(to sid: String) {
        guard let url = subscribers[sid] else { return }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "NOTIFY"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("upnp:event", forHTTPHeaderField: "NT")
        request.setValue("upnp:propchange", forHTTPHeaderField: "NTS")
        request.setValue(sid, forHTTPHeaderField: "SID")
        request.setValue(String(eventSequence), forHTTPHeaderField: "SEQ")
        eventSequence += 1
        request.httpBody = Data(UPnP.lastChangeEvent(transportState: transportState).utf8)
        URLSession.shared.dataTask(with: request).resume()
    }

    // MARK: - Network

    /// IPv4 address of the Wi-Fi interface (`en0` on iPhone), or of the first other `en*` interface.
    nonisolated static func localIPv4Address() -> String? {
        var addresses: [(name: String, address: String)] = []
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(interface.pointee.ifa_flags)
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            addresses.append((name, String(cString: host)))
        }
        return (addresses.first { $0.name == "en0" } ?? addresses.first)?.address
    }
}
