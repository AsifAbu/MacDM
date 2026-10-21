import Foundation
import Network
import Testing
@testable import MacDM

/// Rules that keep web pages, other extensions and other devices away from MacDM.
@Suite("Request security")
struct RequestSecurityTests {
    // MARK: Origins

    @Test("only MacDM's own extensions are allowed", arguments: [
        ("chrome-extension://iocffmeejelkamedgocfjaefbdlofhec", true),
        ("chrome-extension://iocffmeejelkamedgocfjaefbdlofhec/", true),
        ("safari-web-extension://12345678-1234-1234-1234-123456789012", true),
        ("chrome-extension://abcdefghijklmnopabcdefghijklmnop", false), // another extension
        ("chrome-extension://", false),
        ("safari-web-extension://", false),
        ("moz-extension://12345678-1234-1234-1234-123456789012", false),
        ("https://example.com", false),
        ("http://127.0.0.1:8080", false),
        ("null", false),
        ("", false)
    ])
    func origins(origin: String, allowed: Bool) {
        #expect(RequestSecurity.isAllowedOrigin(origin) == allowed)
    }

    @Test("a missing Origin header is never allowed")
    func noOrigin() {
        #expect(!RequestSecurity.isAllowedOrigin(nil))
    }

    @Test("a Web Store ID can be added to the allow-list")
    func extraID() {
        let ids: Set<String> = ["iocffmeejelkamedgocfjaefbdlofhec", "storeidstoreidstoreidstoreidstore"]
        #expect(RequestSecurity.isAllowedOrigin("chrome-extension://storeidstoreidstoreidstoreidstore", chromeExtensionIDs: ids))
    }

    // MARK: Links

    @Test("only http and https links are accepted", arguments: [
        ("https://example.com/a.zip", true),
        ("http://example.com/a.zip", true),
        ("HTTPS://EXAMPLE.COM/a.zip", true),
        ("file:///etc/passwd", false),
        ("file:///Users/someone/secret.txt", false),
        ("javascript:alert(1)", false),
        ("data:text/html;base64,AAAA", false),
        ("ftp://example.com/a.zip", false),
        ("blob:https://example.com/uuid", false),
        ("https://", false),
        ("not a url", false),
        ("", false)
    ])
    func links(link: String, accepted: Bool) {
        #expect((RequestSecurity.webURL(from: link) != nil) == accepted)
    }

    @Test("a missing link is rejected")
    func noLink() {
        #expect(RequestSecurity.webURL(from: nil) == nil)
    }

    // MARK: Browser headers passed on to the downloader

    @Test("Referer, Cookie, User-Agent and Origin are passed on; names are matched in any letter case")
    func headersAllowed() {
        let result = RequestSecurity.safeHeaders([
            "referer": "https://site.example/watch?v=1", "COOKIE": "a=1; b=2",
            "User-Agent": "Mozilla/5.0", "Origin": "https://site.example"
        ])
        #expect(result == ["Referer": "https://site.example/watch?v=1", "Cookie": "a=1; b=2",
                           "User-Agent": "Mozilla/5.0", "Origin": "https://site.example"])
    }

    @Test("other headers are dropped", arguments: ["Authorization", "Host", "Content-Length", "X-Anything", "Range", "Proxy-Authorization"])
    func headersDropped(name: String) {
        #expect(RequestSecurity.safeHeaders([name: "value"]) == nil)
    }

    @Test("a header value with a line break is dropped, so it cannot smuggle in another header")
    func headersNoInjection() {
        #expect(RequestSecurity.safeHeaders(["Cookie": "a=1\r\nX-Evil: 1"]) == nil)
        #expect(RequestSecurity.safeHeaders(["User-Agent": "x\ny"]) == nil)
        #expect(RequestSecurity.safeHeaders(["Cookie": "ok=1", "User-Agent": "bad\r\nvalue"]) == ["Cookie": "ok=1"])
    }

    @Test("a Referer or Origin must be a web address")
    func headersReferer() {
        #expect(RequestSecurity.safeHeaders(["Referer": "file:///etc/passwd"]) == nil)
        #expect(RequestSecurity.safeHeaders(["Origin": "javascript:alert(1)"]) == nil)
        #expect(RequestSecurity.safeHeaders(["Referer": "not a url"]) == nil)
    }

    @Test("empty, oversized and non-text values are dropped; nothing usable gives nil")
    func headersLimits() {
        #expect(RequestSecurity.safeHeaders(["Cookie": "   "]) == nil)
        #expect(RequestSecurity.safeHeaders(["Cookie": String(repeating: "a", count: 9000)]) == nil)
        #expect(RequestSecurity.safeHeaders(["Cookie": String(repeating: "a", count: 8000)])?["Cookie"]?.count == 8000)
        #expect(RequestSecurity.safeHeaders(["Cookie": 42]) == nil)
        #expect(RequestSecurity.safeHeaders("not a dictionary") == nil)
        #expect(RequestSecurity.safeHeaders(nil) == nil)
        #expect(RequestSecurity.safeHeaders([String: Any]()) == nil)
    }

    // MARK: File names

    @Test("a page cannot choose a name that escapes the download folder", arguments: [
        ("../../Library/LaunchAgents/evil.plist", "evil.plist"),
        ("../../../.zshrc", "zshrc"),
        ("/etc/passwd", "passwd"),
        ("..\\..\\Windows\\evil.exe", "evil.exe"),
        ("folder/sub/file.zip", "file.zip"),
        (".hidden", "hidden"),
        ("....", "download"),
        ("..", "download"),
        (".", "download"),
        ("", "download"),
        ("   ", "download"),
        ("a:b.zip", "ab.zip")
    ])
    func unsafeNames(input: String, expected: String) {
        #expect(RequestSecurity.safeFileName(input) == expected)
    }

    @Test("normal names are left alone", arguments: [
        "movie.mp4", "My Report (final).pdf", "ファイル.zip", "a.tar.gz", "Clip [1080p].mp4"
    ])
    func normalNames(name: String) {
        #expect(RequestSecurity.safeFileName(name) == name)
    }

    @Test("control characters are removed")
    func controlCharacters() {
        #expect(RequestSecurity.safeFileName("bad\u{0}na\nme.zip") == "badname.zip")
    }

    @Test("very long names are shortened but keep their extension")
    func longNames() {
        let name = String(repeating: "a", count: 400) + ".mp4"
        let safe = RequestSecurity.safeFileName(name)
        #expect(safe.utf8.count <= 200)
        #expect(safe.hasSuffix(".mp4"))
    }
}

@MainActor
@Suite("Security: downloads and servers", .serialized)
struct SecurityIntegrationTests {
    @Test("a hostile file name cannot place a file outside the download folder")
    func traversalStaysInside() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let root = env.manager.defaultDownloadFolder.standardizedFileURL.path

        for name in ["../../evil.sh", "/tmp/evil.sh", "../../../Library/LaunchAgents/x.plist", "a/../../b"] {
            let task = env.manager.addDownload(url: URL(string: "https://example.com/x")!, suggestedName: name)
            let destination = task.finalDestinationURL.standardizedFileURL.path
            #expect(destination.hasPrefix(root + "/"), "\(name) escaped to \(destination)")
            #expect(!task.fileName.contains("/"))
        }
    }

    @Test("a hostile URL-derived name is also made safe")
    func nameFromURL() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let task = env.manager.addDownload(url: URL(string: "https://example.com/..")!)
        #expect(!task.fileName.hasPrefix("."))
        #expect(!task.fileName.isEmpty)
    }

    // MARK: Links over the wire

    private func post(_ body: [String: Any], to port: UInt16) async throws -> [String: Any]? {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api")!)
        request.httpMethod = "POST"
        request.setValue("chrome-extension://iocffmeejelkamedgocfjaefbdlofhec", forHTTPHeaderField: "Origin")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @Test("local-file and script links are refused for every action", arguments: [
        "file:///etc/passwd", "javascript:alert(1)", "data:text/plain,hi", "ftp://example.com/a"
    ])
    func refusesNonWebLinks(link: String) async throws {
        let server = LocalHTTPServer(port: .any)
        server.start()
        defer { server.stop() }
        #expect(await waitUntil(timeout: 5) { server.boundPort != nil })
        let port = try #require(server.boundPort?.rawValue)
        let before = DownloadManager.shared.tasks.count

        for message: [String: Any] in [
            ["action": "download", "url": link, "forced": true],
            ["action": "download_media", "url": link, "selector": "b"],
            ["action": "formats", "url": link]
        ] {
            let reply = try await post(message, to: port)
            #expect(reply?["ok"] as? Bool == false, "\(message["action"] ?? "") accepted \(link)")
        }
        #expect(DownloadManager.shared.tasks.count == before)
    }

    // MARK: Only this Mac

    /// First non-loopback IPv4 address of this Mac (Wi-Fi/Ethernet), if it has one.
    private func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            let flags = Int32(entry.pointee.ifa_flags)
            if let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
               flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            cursor = entry.pointee.ifa_next
        }
        return nil
    }

    /// True if a TCP connection to host:port is accepted.
    private func canConnect(to host: String, port: UInt16) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    @Test("the HTTP server accepts this Mac but not its network address")
    func httpServerIsLoopbackOnly() async throws {
        let server = LocalHTTPServer(port: .any)
        server.start()
        defer { server.stop() }
        #expect(await waitUntil(timeout: 5) { server.boundPort != nil })
        let port = try #require(server.boundPort?.rawValue)

        #expect(canConnect(to: "127.0.0.1", port: port))
        // Other devices reach this Mac through its LAN address. (Skipped on a Mac with no network.)
        if let lan = lanAddress() {
            #expect(!canConnect(to: lan, port: port), "reachable from the network at \(lan)")
        }
    }

    @Test("the message server accepts this Mac but not its network address")
    func tcpServerIsLoopbackOnly() async throws {
        let host = NativeMessagingHost(port: .any)
        host.startTCP()
        defer { host.stop() }
        #expect(await waitUntil(timeout: 5) { host.boundPort != nil })
        let port = try #require(host.boundPort?.rawValue)

        #expect(canConnect(to: "127.0.0.1", port: port))
        if let lan = lanAddress() {
            #expect(!canConnect(to: lan, port: port), "reachable from the network at \(lan)")
        }
    }
}
