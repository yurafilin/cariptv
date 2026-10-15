import Foundation
import Network

/// Minimal HTTP/1.1 server for the UPnP renderer: one request per connection, `Connection: close`.
final class HTTPServer {
    struct Request {
        var method: String
        var path: String
        /// Header names lowercased.
        var headers: [String: String]
        var body: Data
    }

    struct Response {
        var status: Int
        var headers: [String: String] = [:]
        var body = Data()

        static func xml(_ text: String, status: Int = 200) -> Response {
            Response(status: status, headers: ["Content-Type": "text/xml; charset=\"utf-8\""], body: Data(text.utf8))
        }

        static func empty(_ status: Int, headers: [String: String] = [:]) -> Response {
            Response(status: status, headers: headers)
        }

        func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
            var headers = headers
            headers["Content-Length"] = String(body.count)
            headers["Connection"] = "close"
            headers["Server"] = "iOS UPnP/1.0 CarIPTV/1.0"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) {
                head += "\(name): \(value)\r\n"
            }
            head += "\r\n"
            return Data(head.utf8) + body
        }

        private static func reason(_ status: Int) -> String {
            switch status {
            case 200: "OK"
            case 400: "Bad Request"
            case 404: "Not Found"
            case 405: "Method Not Allowed"
            case 412: "Precondition Failed"
            case 500: "Internal Server Error"
            default: "Status"
            }
        }
    }

    typealias Handler = (Request, @escaping (Response) -> Void) -> Void

    var onReady: ((UInt16) -> Void)?
    var onFailure: ((String) -> Void)?

    private static let maxRequestSize = 1 << 20
    private let queue = DispatchQueue(label: "weappico.cariptv.cast.http")
    private let handler: Handler
    private var listener: NWListener?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: .tcp)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.serve(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    switch state {
                    case .ready:
                        if let port = listener?.port?.rawValue {
                            self?.onReady?(port)
                        }
                    case .failed(let error):
                        self?.onFailure?(error.localizedDescription)
                    default:
                        break
                    }
                }
                self.listener = listener
                listener.start(queue: queue)
            } catch {
                onFailure?(error.localizedDescription)
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parse(buffer) {
                handler(request) { response in
                    connection.send(content: response.serialized(), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                }
                return
            }
            if isComplete || error != nil || buffer.count > Self.maxRequestSize {
                connection.cancel()
                return
            }
            receive(connection, buffer: buffer)
        }
    }

    /// Returns `nil` until the head and the whole body (per Content-Length) have arrived.
    static func parse(_ data: Data) -> Request? {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[data.startIndex..<separator.lowerBound], encoding: .utf8) else { return nil }

        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }

        let length = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = separator.upperBound
        guard data.count - (bodyStart - data.startIndex) >= length else { return nil }
        let body = data.subdata(in: bodyStart..<bodyStart + length)

        // Some control points send an absolute URL as the request target.
        var target = String(requestLine[1])
        if let url = URL(string: target), url.scheme != nil {
            target = url.path
        }
        if let query = target.firstIndex(of: "?") {
            target = String(target[..<query])
        }
        return Request(method: String(requestLine[0]).uppercased(), path: target, headers: headers, body: body)
    }
}
