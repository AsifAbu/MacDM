import Foundation
import Network

/// Minimal loopback HTTP server (127.0.0.1:57643) for the browser extension.
///
/// The extension's background script POSTs JSON to `/api` and gets JSON back,
/// which lets it talk to MacDM without a signed Safari app extension.
///
/// Security: the server is bound to 127.0.0.1 only, and only requests whose Origin
/// is MacDM's Chrome extension (fixed ID) or a Safari web extension are accepted,
/// so web pages and other extensions can't trigger downloads or yt-dlp runs.
/// See RequestSecurity.
final class LocalHTTPServer {
    static let shared = LocalHTTPServer()
    static let port: NWEndpoint.Port = 57643

    private var listener: NWListener?
    private let maxRequestBytes = 1_048_576
    private let requestedPort: NWEndpoint.Port
    private var readyPort: NWEndpoint.Port?

    /// Tests pass `.any` to get a free port instead of the fixed one.
    init(port: NWEndpoint.Port = LocalHTTPServer.port) {
        self.requestedPort = port
    }

    /// The port actually bound once the listener is running (differs from the
    /// requested one when `.any` was used).
    var boundPort: NWEndpoint.Port? { readyPort }

    func stop() {
        listener?.cancel()
        listener = nil
        readyPort = nil
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            // Bind to 127.0.0.1 explicitly: only programs on this Mac can connect,
            // never other devices on the Wi-Fi/LAN.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: requestedPort)
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] connection in
                connection.start(queue: .main)
                self?.receive(on: connection, buffer: Data())
            }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.readyPort = self?.listener?.port }
            }
            listener?.start(queue: .main)
        } catch {
            print("LocalHTTPServer failed to start: \(error)")
        }
    }

    // MARK: - Request parsing

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if buffer.count > self.maxRequestBytes {
                self.respond(on: connection, status: "413 Payload Too Large", origin: nil, body: nil)
                return
            }
            if let request = HTTPRequest(parsing: buffer) {
                self.route(request, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        // Only MacDM's own browser extensions may call this; web pages and other extensions are refused.
        let origin = request.headers["origin"]
        guard let origin, RequestSecurity.isAllowedOrigin(origin) else {
            respond(on: connection, status: "403 Forbidden", origin: nil, body: ["ok": false, "error": "Forbidden"])
            return
        }

        if request.method == "OPTIONS" {
            respond(on: connection, status: "204 No Content", origin: origin, body: nil)
            return
        }
        guard request.method == "POST", request.path == "/api",
              let message = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] else {
            respond(on: connection, status: "400 Bad Request", origin: origin, body: ["ok": false, "error": "Bad request"])
            return
        }

        NativeMessagingHost.shared.handleMessage(message) { [weak self] payload in
            self?.respond(on: connection, status: "200 OK", origin: origin, body: payload)
        }
    }

    private func respond(on connection: NWConnection, status: String, origin: String?, body: [String: Any]?) {
        let bodyData = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        var head = "HTTP/1.1 \(status)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        if let origin {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Access-Control-Allow-Methods: POST, OPTIONS\r\n"
            head += "Access-Control-Allow-Headers: Content-Type\r\n"
            head += "Vary: Origin\r\n"
        }
        head += "Connection: close\r\n\r\n"

        var response = Data(head.utf8)
        response.append(bodyData)
        connection.send(content: response, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Just enough HTTP/1.1 parsing for one small JSON request per connection.
private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String] // lowercased names
    let body: Data

    /// Returns nil until the full header block and Content-Length bytes have arrived.
    init?(parsing data: Data) {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headText = String(decoding: data[data.startIndex..<headerEnd.lowerBound], as: UTF8.self)
        let lines = headText.components(separatedBy: "\r\n")
        let requestLine = lines.first?.split(separator: " ") ?? []
        guard requestLine.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headerEnd.upperBound
        let expected = Int(headers["content-length"] ?? "0") ?? 0
        guard data.count - bodyStart >= expected else { return nil }

        self.method = String(requestLine[0])
        self.path = String(requestLine[1])
        self.headers = headers
        self.body = data.subdata(in: bodyStart..<(bodyStart + expected))
    }
}
