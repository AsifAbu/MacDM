import Foundation
import Network
import Testing
@testable import MacDM

/// The loopback HTTP server the browser extensions talk to.
@MainActor
@Suite("Local HTTP server", .serialized)
struct LocalServerTests {
    private let extensionOrigin = "chrome-extension://iocffmeejelkamedgocfjaefbdlofhec" // MacDM's pinned Chrome extension

    private func startServer() async -> (LocalHTTPServer, UInt16)? {
        let server = LocalHTTPServer(port: .any)
        server.start()
        let ready = await waitUntil(timeout: 5) { server.boundPort != nil }
        guard ready, let port = server.boundPort?.rawValue else { return nil }
        return (server, port)
    }

    private struct Reply {
        let status: Int
        let json: [String: Any]?
        let headers: [String: String]
    }

    private func send(_ method: String, to port: UInt16, path: String = "/api",
                      origin: String?, body: Data? = nil) async throws -> Reply {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.httpMethod = method
        request.timeoutInterval = 10
        if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
        let http = response as! HTTPURLResponse
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers["\(key)".lowercased()] = "\(value)" }
        return Reply(status: http.statusCode,
                     json: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                     headers: headers)
    }

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Origin checks

    @Test("requests without an Origin are rejected")
    func rejectsNoOrigin() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: nil, body: json(["action": "download"]))
        #expect(reply.status == 403)
    }

    @Test("requests from ordinary web pages are rejected", arguments: [
        "https://evil.example", "http://localhost:3000", "null", "file://",
        "chrome-extension://abcdefghijklmnopabcdefghijklmnop", // some other Chrome extension
        "moz-extension://12345678-1234-1234-1234-123456789012"
    ])
    func rejectsWebOrigins(origin: String) async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: origin, body: json(["action": "download", "url": "http://x/y"]))
        #expect(reply.status == 403)
    }

    @Test("browser extension origins are accepted", arguments: [
        "chrome-extension://iocffmeejelkamedgocfjaefbdlofhec",
        "safari-web-extension://12345678-1234-1234-1234-123456789012"
    ])
    func acceptsExtensionOrigins(origin: String) async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: origin, body: json(["action": "download"]))
        #expect(reply.status == 200)
        // The origin is echoed so the extension is allowed to read the reply.
        #expect(reply.headers["access-control-allow-origin"] == origin)
    }

    // MARK: Request handling

    @Test("OPTIONS preflight answers 204 with CORS headers")
    func preflight() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("OPTIONS", to: port, origin: extensionOrigin)
        #expect(reply.status == 204)
        #expect(reply.headers["access-control-allow-methods"]?.contains("POST") == true)
    }

    @Test("malformed JSON gets 400")
    func badJSON() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: extensionOrigin, body: Data("not json".utf8))
        #expect(reply.status == 400)
    }

    @Test("wrong method or path gets 400")
    func wrongRoute() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        #expect(try await send("GET", to: port, origin: extensionOrigin).status == 400)
        #expect(try await send("POST", to: port, path: "/other", origin: extensionOrigin, body: json([:])).status == 400)
    }

    // MARK: Messages

    @Test("a download message without a URL reports an error")
    func missingURL() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: extensionOrigin, body: json(["action": "download"]))
        #expect(reply.json?["ok"] as? Bool == false)
        #expect(reply.json?["error"] as? String == "Missing URL")
    }

    @Test("small unforced downloads are skipped, forced ones are queued")
    func smallFileRule() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let before = DownloadManager.shared.tasks.count

        let skipped = try await send("POST", to: port, origin: extensionOrigin, body: json([
            "action": "download", "url": "http://127.0.0.1:9/tiny.png", "sizeBytes": 100
        ]))
        #expect(skipped.json?["ok"] as? Bool == true)
        #expect(skipped.json?["skipped"] as? Bool == true)
        #expect(DownloadManager.shared.tasks.count == before)

        let forced = try await send("POST", to: port, origin: extensionOrigin, body: json([
            "action": "download", "url": "http://127.0.0.1:9/tiny.png", "sizeBytes": 100, "forced": true
        ]))
        #expect(forced.json?["ok"] as? Bool == true)
        #expect(forced.json?["skipped"] == nil)
        #expect(DownloadManager.shared.tasks.count == before + 1)

        // Don't leave a download running against a dead port.
        DownloadManager.shared.tasks.forEach { DownloadManager.shared.remove($0) }
    }

    @Test("headers sent by the extension are filtered: allowed ones kept, the rest dropped")
    func extensionHeadersFiltered() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let before = DownloadManager.shared.tasks.count

        let reply = try await send("POST", to: port, origin: extensionOrigin, body: json([
            "action": "download", "url": "http://127.0.0.1:9/video.mp4", "forced": true,
            "headers": ["Referer": "https://site.example/watch", "Cookie": "s=1", "Authorization": "Bearer secret", "Host": "evil.example"]
        ]))
        #expect(reply.json?["ok"] as? Bool == true)
        #expect(DownloadManager.shared.tasks.count == before + 1)
        let task = try #require(DownloadManager.shared.tasks.first)
        #expect(task.requestHeaders == ["Referer": "https://site.example/watch", "Cookie": "s=1"])

        DownloadManager.shared.tasks.forEach { DownloadManager.shared.remove($0) }
    }

    @Test("download_media without a format selector is rejected")
    func mediaNeedsSelector() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: extensionOrigin, body: json([
            "action": "download_media", "url": "https://example.com/watch"
        ]))
        #expect(reply.json?["ok"] as? Bool == false)
    }

    @Test("formats without a URL is rejected")
    func formatsNeedsURL() async throws {
        let (server, port) = try #require(await startServer())
        defer { server.stop() }
        let reply = try await send("POST", to: port, origin: extensionOrigin, body: json(["action": "formats"]))
        #expect(reply.json?["ok"] as? Bool == false)
    }
}

/// How yt-dlp's format list is turned into the quality choices shown in the browser.
@Suite("Media quality options")
struct MediaOptionsTests {
    private func format(height: Int? = nil, video: Bool, audio: Bool, size: Int? = nil) -> [String: Any] {
        var f: [String: Any] = [
            "vcodec": video ? "avc1" : "none",
            "acodec": audio ? "mp4a" : "none"
        ]
        if let height { f["height"] = height }
        if let size { f["filesize"] = size }
        return f
    }

    private var sample: [String: Any] {
        [
            "title": "Sample video",
            "duration": 120.0,
            "formats": [
                format(height: 1080, video: true, audio: false, size: 1000),
                format(height: 720, video: true, audio: false, size: 600),
                format(height: 360, video: true, audio: true, size: 300),
                format(video: false, audio: true, size: 50)
            ]
        ]
    }

    @Test("with ffmpeg: every height plus audio only, largest first")
    func withFFmpeg() {
        let info = MediaExtractor.buildInfo(from: sample, canMerge: true)
        #expect(info.title == "Sample video")
        #expect(info.options.map(\.label) == ["1080p", "720p", "360p", "Audio only"])
        #expect(info.options[0].selector == "bv*[height<=1080]+ba/b[height<=1080]")
        // Size is the video stream plus the best audio stream.
        #expect(info.options[0].sizeBytes == 1050)
        #expect(info.options.last?.audioOnly == true)
    }

    @Test("without ffmpeg: only formats that already include audio")
    func withoutFFmpeg() {
        let info = MediaExtractor.buildInfo(from: sample, canMerge: false)
        #expect(info.options.map(\.label) == ["360p", "Audio only"])
        #expect(info.options[0].selector == "b[height<=360]/b")
    }

    @Test("a video with no height information offers Best available (and no Audio only: it has no separate audio stream)")
    func bestAvailableFallback() {
        let info = MediaExtractor.buildInfo(from: ["title": "x", "formats": [format(video: true, audio: true)]], canMerge: true)
        #expect(info.options.map(\.label) == ["Best available"])
        #expect(info.options[0].selector == "b/bv*+ba")
        #expect(info.options[0].audioOnly == false)
    }

    /// Formats the way some sites report them: a height, but no codec information at all.
    private func unknownCodec(height: Int?, size: Int? = nil) -> [String: Any] {
        var f: [String: Any] = [:]
        if let height { f["height"] = height }
        if let size { f["filesize"] = size }
        return f
    }

    @Test("sizes are listed even when the site does not say which codecs are used", arguments: [true, false])
    func unknownCodecsKeepTheirSizes(canMerge: Bool) {
        let json: [String: Any] = ["title": "x", "formats": [
            unknownCodec(height: 360), unknownCodec(height: 480), unknownCodec(height: 720), unknownCodec(height: 1080)
        ]]
        let info = MediaExtractor.buildInfo(from: json, canMerge: canMerge)
        #expect(info.options.map(\.label) == ["1080p", "720p", "480p", "360p"])
        #expect(!info.options.contains { $0.audioOnly }, "no audio-only stream exists")
    }

    @Test("a source with unknown codecs and no heights offers Best available, never an empty list")
    func unknownCodecsNoHeights() {
        let info = MediaExtractor.buildInfo(from: ["title": "x", "formats": [unknownCodec(height: nil), unknownCodec(height: nil)]], canMerge: true)
        #expect(info.options.map(\.label) == ["Best available"])
    }

    @Test("the list is never empty for any kind of source", arguments: [
        [[String: Any]](),
        [["height": 720]],
        [["vcodec": "avc1", "acodec": "mp4a"]],
        [["vcodec": "avc1", "acodec": "none", "height": 480]],
        [["vcodec": "none", "acodec": "mp4a"]],
        [["vcodec": "none", "acodec": "none"]]
    ])
    func neverEmpty(formats: [[String: Any]]) {
        for canMerge in [true, false] {
            let info = MediaExtractor.buildInfo(from: ["title": "x", "formats": formats], canMerge: canMerge)
            #expect(!info.options.isEmpty, "no choices for \(formats) (ffmpeg: \(canMerge))")
        }
    }

    @Test("an audio-only source offers just Audio only")
    func audioOnlySource() {
        let info = MediaExtractor.buildInfo(from: ["title": "x", "formats": [format(video: false, audio: true)]], canMerge: true)
        #expect(info.options.map(\.label) == ["Audio only"])
    }

    @Test("no formats at all falls back to Best available")
    func noFormats() {
        let info = MediaExtractor.buildInfo(from: ["title": "x", "formats": []], canMerge: true)
        #expect(info.options.map(\.label) == ["Best available"])
    }

    @Test("a missing title falls back to 'video'")
    func defaultTitle() {
        #expect(MediaExtractor.buildInfo(from: ["formats": []], canMerge: true).title == "video")
    }

    @Test("yt-dlp bot-check and cookie errors become actionable messages")
    func friendlyErrors() {
        #expect(MediaError.fromYtDlp("ERROR: Sign in to confirm you're not a bot").errorDescription?.contains("Settings") == true)
        #expect(MediaError.fromYtDlp("ERROR: [Cookies] Operation not permitted").errorDescription?.contains("Full Disk Access") == true)
        #expect(MediaError.fromYtDlp("ERROR: Video unavailable").errorDescription == "Video unavailable")
    }
}
