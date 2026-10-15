import Foundation
import Network

/// SSDP side of the renderer: answers `M-SEARCH` and announces itself on 239.255.255.250:1900.
/// On a device this needs the `com.apple.developer.networking.multicast` entitlement.
final class SSDPResponder {
    static let deviceType = "urn:schemas-upnp-org:device:MediaRenderer:1"
    static let serviceTypes = [
        "urn:schemas-upnp-org:service:AVTransport:1",
        "urn:schemas-upnp-org:service:RenderingControl:1",
        "urn:schemas-upnp-org:service:ConnectionManager:1",
    ]

    var onFailure: ((String) -> Void)?

    private let queue = DispatchQueue(label: "weappico.cariptv.cast.ssdp")
    private let udn: String
    private let location: String
    private var group: NWConnectionGroup?
    private var notifyTimer: DispatchSourceTimer?

    /// `udn` is `uuid:…`; `location` is the device description URL.
    init(udn: String, location: String) {
        self.udn = udn
        self.location = location
    }

    private var notificationTypes: [String] {
        ["upnp:rootdevice", udn, Self.deviceType] + Self.serviceTypes
    }

    func start() {
        queue.async { [self] in
            guard group == nil else { return }
            do {
                let multicast = try NWMulticastGroup(for: [.hostPort(host: "239.255.255.250", port: 1900)])
                let parameters = NWParameters.udp
                parameters.allowLocalEndpointReuse = true
                let group = NWConnectionGroup(with: multicast, using: parameters)
                group.setReceiveHandler(maximumMessageSize: 8192, rejectOversizedMessages: true) { [weak self] message, content, _ in
                    guard let self, let content, let text = String(data: content, encoding: .utf8) else { return }
                    queue.async { self.handle(text, message: message) }
                }
                group.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        Log.cast.info("ssdp: ready")
                        announce(alive: true)
                        startNotifyTimer()
                    case .failed(let error):
                        Log.cast.error("ssdp: failed \(error.localizedDescription)")
                        onFailure?(error.localizedDescription)
                    default:
                        break
                    }
                }
                self.group = group
                group.start(queue: queue)
            } catch {
                Log.cast.error("ssdp: group create failed \(error.localizedDescription)")
                onFailure?(error.localizedDescription)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            notifyTimer?.cancel()
            notifyTimer = nil
            guard let group else { return }
            announce(alive: false)
            // Let the byebye leave before the group goes away.
            queue.asyncAfter(deadline: .now() + 0.2) { group.cancel() }
            self.group = nil
        }
    }

    // MARK: - Private

    private func handle(_ text: String, message: NWConnectionGroup.Message) {
        guard text.hasPrefix("M-SEARCH") else { return }
        let headers = Self.headers(text)
        guard headers["man"]?.contains("ssdp:discover") ?? false, let searchTarget = headers["st"] else { return }

        let targets: [String]
        if searchTarget == "ssdp:all" {
            targets = notificationTypes
        } else if notificationTypes.contains(searchTarget) {
            targets = [searchTarget]
        } else {
            return
        }
        for target in targets {
            message.reply(content: Data(searchResponse(target).utf8))
        }
    }

    private func announce(alive: Bool) {
        guard let group else { return }
        for type in notificationTypes {
            var lines = [
                "NOTIFY * HTTP/1.1",
                "HOST: 239.255.255.250:1900",
                "NT: \(type)",
                "NTS: \(alive ? "ssdp:alive" : "ssdp:byebye")",
                "USN: \(usn(type))",
            ]
            if alive {
                lines += ["CACHE-CONTROL: max-age=1800", "LOCATION: \(location)", "SERVER: iOS UPnP/1.0 CarIPTV/1.0"]
            }
            group.send(content: Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)) { error in
                if let error {
                    Log.cast.error("ssdp: notify failed \(error.localizedDescription)")
                }
            }
        }
    }

    private func startNotifyTimer() {
        notifyTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.announce(alive: true)
        }
        timer.resume()
        notifyTimer = timer
    }

    private func searchResponse(_ target: String) -> String {
        [
            "HTTP/1.1 200 OK",
            "CACHE-CONTROL: max-age=1800",
            "EXT:",
            "LOCATION: \(location)",
            "SERVER: iOS UPnP/1.0 CarIPTV/1.0",
            "ST: \(target)",
            "USN: \(usn(target))",
        ].joined(separator: "\r\n") + "\r\n\r\n"
    }

    private func usn(_ type: String) -> String {
        type == udn ? udn : "\(udn)::\(type)"
    }

    static func headers(_ message: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in message.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            headers[name] = value
        }
        return headers
    }
}
