import Foundation
import Network

/// Receives requests from the browser extension and turns them into downloads.
///
/// Two transports feed the same handler:
///   - raw JSON over TCP on 127.0.0.1:57642 (used by the Safari app extension's
///     SafariWebExtensionHandler)
///   - HTTP on 127.0.0.1:57643 (see LocalHTTPServer), used directly by the web
///     extension's background script so it works without a signed app extension
///
/// Supported `action` values:
///   - "formats":        resolve a page URL with yt-dlp and return the quality options
///   - "download_media": queue a yt-dlp download with a chosen format selector
///   - "download" (default): queue a plain file download
final class NativeMessagingHost {
    static let shared = NativeMessagingHost()
    private var listener: NWListener?
    private var readyPort: NWEndpoint.Port?
    private let port: NWEndpoint.Port

    /// Tests pass `.any` to get a free port instead of the fixed one.
    init(port: NWEndpoint.Port = 57642) {
        self.port = port
    }

    /// The port actually bound once the listener is running.
    var boundPort: NWEndpoint.Port? { readyPort }

    func start() {
        startTCP()
        LocalHTTPServer.shared.start()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        readyPort = nil
    }

    /// Starts only the raw TCP listener (used by the Safari app extension).
    func startTCP() {
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            // 127.0.0.1 only: other devices on the network must not be able to connect.
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: port)
            listener = try NWListener(using: params)
            listener?.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener?.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.readyPort = self?.listener?.port }
            }
            listener?.start(queue: .main)
        } catch {
            print("NativeMessagingHost failed to start: \(error)")
        }
    }

    // MARK: - TCP transport

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .main)
        receiveMessage(on: connection)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processTCP(data: data, on: connection)
                return // the reply (or cancel) closes the connection
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self?.receiveMessage(on: connection)
            }
        }
    }

    private func processTCP(data: Data, on connection: NWConnection) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            sendTCPReply(["ok": false, "error": "Invalid message"], on: connection)
            return
        }
        handleMessage(message) { [weak self] payload in
            self?.sendTCPReply(payload, on: connection)
        }
    }

    private func sendTCPReply(_ payload: [String: Any], on connection: NWConnection) {
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{\"ok\":false}".utf8)
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Shared message handling

    /// Must be called on the main queue; `reply` is always invoked on the main queue.
    func handleMessage(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        switch message["action"] as? String ?? "download" {
        case "formats":
            handleFormats(message, reply: reply)
        case "download_media":
            handleMediaDownload(message, reply: reply)
        case "stream_info":
            handleStreamInfo(message, reply: reply)
        case "grab":
            handleGrab(message, reply: reply)
        default:
            handleFileDownload(message, reply: reply)
        }
    }

    /// The `url` field as a safe web address, or an error reply if it is missing or not http(s).
    private func requireWebURL(_ message: [String: Any], reply: ([String: Any]) -> Void) -> URL? {
        guard let urlString = message["url"] as? String, !urlString.isEmpty else {
            reply(["ok": false, "error": "Missing URL"])
            return nil
        }
        guard let url = RequestSecurity.webURL(from: urlString) else {
            reply(["ok": false, "error": "Only http and https links can be downloaded."])
            return nil
        }
        return url
    }

    /// Links collected from the page the user is looking at in their browser (logged in, scripts run).
    /// They open in the Site Grabber, where the user filters and picks what to download.
    private func handleGrab(_ message: [String: Any], reply: ([String: Any]) -> Void) {
        guard let pageString = message["pageURL"] as? String, let pageURL = RequestSecurity.webURL(from: pageString) else {
            reply(["ok": false, "error": "Missing page address"])
            return
        }
        var links: [GrabbedLink] = []
        var seen = Set<URL>()
        for item in ((message["links"] as? [Any]) ?? []).prefix(10_000) {
            let text = (item as? String) ?? ((item as? [String: Any])?["url"] as? String)
            // Only web addresses of real files; page links without a file ending are skipped.
            guard let text, let url = RequestSecurity.webURL(from: text),
                  GrabKind.knownExtensions.contains(url.pathExtension.lowercased()),
                  seen.insert(url).inserted else { continue }
            links.append(GrabbedLink(url: url, sourcePage: pageURL))
            if links.count >= 3000 { break }
        }
        guard !links.isEmpty else {
            reply(["ok": false, "error": "No downloadable files were found on this page."])
            return
        }
        let title = (message["title"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(200)) } ?? (pageURL.host ?? "")
        let session = GrabSession(pageURL: pageURL, title: title, links: links, headers: RequestSecurity.safeHeaders(message["headers"]))
        Task { @MainActor in SiteGrabberStore.shared.present(session) }
        reply(["ok": true, "count": links.count])
    }

    /// Resolution, length and rough size of a detected HLS stream, so the browser can show them next to it.
    private func handleStreamInfo(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let url = requireWebURL(message, reply: reply) else { return }
        let headers = RequestSecurity.safeHeaders(message["headers"]) ?? [:]
        Task {
            let summary = await StreamInspector.summary(of: url, headers: headers)
            var payload: [String: Any] = ["ok": summary != nil]
            if let summary {
                if let width = summary.width { payload["width"] = width }
                if let height = summary.height { payload["height"] = height }
                if let duration = summary.duration { payload["duration"] = duration }
                if let bytes = summary.estimatedBytes { payload["sizeBytes"] = bytes }
            } else {
                payload["error"] = "Could not read the stream."
            }
            await MainActor.run { reply(payload) }
        }
    }

    private func handleFormats(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let url = requireWebURL(message, reply: reply) else { return }
        let referer = message["referer"] as? String
        let cookies = RequestSecurity.safeCookies(message["cookies"])

        Task {
            do {
                let info = try await MediaExtractor.fetchInfoCached(url: url, referer: referer, cookies: cookies)
                var payload: [String: Any] = [
                    "ok": true,
                    "title": info.title,
                    "options": info.options.map { $0.dictionary },
                    "ffmpeg": MediaTools.hasFFmpeg
                ]
                if let thumbnail = info.thumbnail { payload["thumbnail"] = thumbnail }
                if let duration = info.duration { payload["duration"] = duration }
                await MainActor.run { reply(payload) }
            } catch {
                await MainActor.run { reply(["ok": false, "error": error.localizedDescription]) }
            }
        }
    }

    private func handleMediaDownload(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let url = requireWebURL(message, reply: reply) else { return }
        guard let selector = message["selector"] as? String, !selector.isEmpty else {
            reply(["ok": false, "error": "Missing URL or format"])
            return
        }
        let title = (message["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "video"
        DownloadManager.shared.addMediaDownload(
            pageURL: url,
            title: title,
            formatSelector: selector,
            audioOnly: message["audioOnly"] as? Bool ?? false,
            referer: message["referer"] as? String,
            headers: RequestSecurity.safeHeaders(message["headers"]),
            cookies: RequestSecurity.safeCookies(message["cookies"])
        )
        reply(["ok": true])
    }

    private func handleFileDownload(_ message: [String: Any], reply: @escaping ([String: Any]) -> Void) {
        guard let url = requireWebURL(message, reply: reply) else { return }
        let size = (message["sizeBytes"] as? NSNumber)?.int64Value
        let forced = message["forced"] as? Bool ?? false

        // Skip tiny files / inline images unless the user explicitly grabbed it.
        if let size, size < 50_000, !forced {
            reply(["ok": true, "skipped": true])
            return
        }
        DownloadManager.shared.addDownload(url: url, suggestedName: message["suggestedFileName"] as? String,
                                           headers: RequestSecurity.safeHeaders(message["headers"]))
        reply(["ok": true])
    }
}
