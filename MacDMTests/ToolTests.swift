import Foundation
import Testing
@testable import MacDM

// MARK: - Fake GitHub

/// Answers URLSession requests from memory, so updater tests never touch the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responses: [String: (status: Int, body: Data)] = [:]
    nonisolated(unsafe) static var requested: [String] = []
    /// Optional per-address extras: the Content-Type to report (default is a web page), and a Content-Length
    /// to report instead of the body's size (for HEAD requests).
    nonisolated(unsafe) static var contentTypes: [String: String] = [:]
    nonisolated(unsafe) static var declaredSizes: [String: Int] = [:]
    /// Every request seen: address, method and headers.
    nonisolated(unsafe) static var seen: [(url: String, method: String, headers: [String: String])] = []

    static func reset() { responses = [:]; requested = []; contentTypes = [:]; declaredSizes = [:]; seen = [] }

    static func html(_ page: String) -> (status: Int, body: Data) { (200, Data(page.utf8)) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!.absoluteString
        Self.requested.append(url)
        Self.seen.append((url, request.httpMethod ?? "GET", request.allHTTPHeaderFields ?? [:]))
        let reply = Self.responses[url] ?? (404, Data())
        let fields = ["Content-Type": Self.contentTypes[url] ?? "text/html; charset=utf-8",
                      "Content-Length": String(Self.declaredSizes[url] ?? reply.body.count)]
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: fields)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A throwaway folder with fake "yt-dlp" programs (tiny shell scripts that print a version).
struct ToolSandbox {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMTools-\(UUID().uuidString)", isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func dir(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func script(printing text: String) -> Data { Data("#!/bin/sh\necho \(text)\n".utf8) }

    @discardableResult
    func makeTool(in folder: String, named name: String = "yt-dlp", printing text: String, executable: Bool = true) -> URL {
        let url = dir(folder).appendingPathComponent(name)
        try? Self.script(printing: text).write(to: url)
        try? FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: url.path)
        return url
    }

    /// A zip shaped like yt-dlp's multi-file build: a "yt-dlp_macos" program and an "_internal" folder.
    func makeToolZip(printing text: String) -> Data {
        let src = dir("zip-src-\(UUID().uuidString)")
        let program = src.appendingPathComponent("yt-dlp_macos")
        try? Self.script(printing: text).write(to: program)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
        let internalDir = src.appendingPathComponent("_internal")
        try? FileManager.default.createDirectory(at: internalDir, withIntermediateDirectories: true)
        try? Data("library".utf8).write(to: internalDir.appendingPathComponent("marker.txt"))

        let zip = root.appendingPathComponent("tool-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", src.path, zip.path]
        try? p.run(); p.waitUntilExit()
        return (try? Data(contentsOf: zip)) ?? Data()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

// MARK: - Where tools are looked up

@Suite("Tool lookup")
struct MediaToolsLookupTests {
    @Test("the first folder that has the tool wins")
    func firstMatchWins() {
        let box = ToolSandbox(); defer { box.cleanUp() }
        let first = box.makeTool(in: "a", printing: "1")
        box.makeTool(in: "b", printing: "2")
        #expect(MediaTools.find("yt-dlp", in: [box.dir("a").path, box.dir("b").path]) == first)
    }

    @Test("falls through to the next folder when the first has none")
    func fallsThrough() {
        let box = ToolSandbox(); defer { box.cleanUp() }
        let second = box.makeTool(in: "b", printing: "2")
        #expect(MediaTools.find("yt-dlp", in: [box.dir("a").path, box.dir("b").path]) == second)
    }

    @Test("a file that is not executable is ignored")
    func ignoresNonExecutable() {
        let box = ToolSandbox(); defer { box.cleanUp() }
        box.makeTool(in: "a", printing: "1", executable: false)
        #expect(MediaTools.find("yt-dlp", in: [box.dir("a").path]) == nil)
    }

    @Test("a missing tool gives nil")
    func missing() {
        let box = ToolSandbox(); defer { box.cleanUp() }
        #expect(MediaTools.find("definitely-not-installed", in: [box.dir("a").path]) == nil)
    }

    @Test("order is: downloaded update, then the copies inside the app, then Homebrew")
    func defaultOrder() {
        let dirs = MediaTools.searchDirs
        #expect(dirs[0] == MediaTools.updatedDirectory.path)
        #expect(dirs[1] == MediaTools.bundledYtDlpDirectory.path)
        #expect(dirs[2] == MediaTools.bundledDirectory.path)
        #expect(dirs.dropFirst(3).contains("/opt/homebrew/bin"))
        #expect(MediaTools.bundledDirectory.path.hasSuffix("MacDM.app/Contents/Helpers"))
        #expect(MediaTools.bundledYtDlpDirectory.path.hasSuffix("MacDM.app/Contents/Resources/yt-dlp"))
    }

    @Test("child programs get the tool folders on their PATH")
    func environmentPath() {
        let path = MediaTools.environment["PATH"] ?? ""
        #expect(path.contains(MediaTools.bundledDirectory.path))
        #expect(path.contains(MediaTools.bundledYtDlpDirectory.path))
    }
}

// MARK: - Version and checksum helpers

@Suite("Updater helpers")
struct UpdaterHelperTests {
    @Test("version comparison", arguments: [
        ("2026.08.19", "2026.08.18", true),
        ("2026.08.19", "2026.08.19", false),
        ("2026.08.18", "2026.08.19", false),
        ("2026.09.01", "2026.08.30", true),
        ("2027.01.01", "2026.12.31", true),
        ("2026.08.19.232103", "2026.08.19", true),
        ("2026.08.19", "2026.08.19.232103", false),
        ("2026.08.19.5", "2026.08.19.4", true)
    ])
    func newer(latest: String, current: String, expected: Bool) {
        #expect(YtDlpUpdater.isNewer(latest, than: current) == expected)
    }

    @Test("checksum is read from a SHA2-256SUMS listing")
    func parsesChecksum() {
        let hash = String(repeating: "ab", count: 32)
        let other = String(repeating: "cd", count: 32)
        let listing = "\(other)  yt-dlp\n\(hash)  yt-dlp_macos\n\(other) *yt-dlp.exe\n"
        #expect(YtDlpUpdater.checksum(for: "yt-dlp_macos", in: listing) == hash)
        #expect(YtDlpUpdater.checksum(for: "yt-dlp.exe", in: listing) == other)
        #expect(YtDlpUpdater.checksum(for: "missing", in: listing) == nil)
        #expect(YtDlpUpdater.checksum(for: "yt-dlp_macos", in: "short  yt-dlp_macos") == nil)
        #expect(YtDlpUpdater.checksum(for: "yt-dlp_macos", in: "") == nil)
    }

    @Test("only https downloads from GitHub are trusted", arguments: [
        ("https://github.com/yt-dlp/yt-dlp/releases/download/1/yt-dlp_macos", true),
        ("https://objects.githubusercontent.com/abc", true),
        ("http://github.com/yt-dlp/yt-dlp/releases/download/1/yt-dlp_macos", false),
        ("https://evil.example/yt-dlp_macos", false),
        ("https://github.com.evil.example/yt-dlp_macos", false),
        ("https://notgithub.com/yt-dlp_macos", false),
        ("file:///tmp/yt-dlp_macos", false)
    ])
    func trustedURLs(url: String, trusted: Bool) {
        #expect(YtDlpUpdater.isTrustedDownloadURL(URL(string: url)!) == trusted)
    }

    @Test("version(of:) reads a real program's version and rejects junk")
    func readsVersion() {
        let box = ToolSandbox(); defer { box.cleanUp() }
        #expect(YtDlpUpdater.version(of: box.makeTool(in: "a", printing: "2026.08.19")) == "2026.08.19")
        #expect(YtDlpUpdater.version(of: box.makeTool(in: "b", printing: "hello world")) == nil)
        #expect(YtDlpUpdater.version(of: box.makeTool(in: "c", printing: "")) == nil)
        #expect(YtDlpUpdater.version(of: box.dir("d").appendingPathComponent("nope")) == nil)
    }

    @Test("sha256 of a file")
    func hashesFile() throws {
        let box = ToolSandbox(); defer { box.cleanUp() }
        let file = box.dir("a").appendingPathComponent("f")
        try Data("abc".utf8).write(to: file)
        #expect(try YtDlpUpdater.sha256(of: file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - The update flow

@Suite("yt-dlp updater", .serialized)
struct YtDlpUpdaterTests {
    private let releaseAPI = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    private func asset(_ latest: String, _ name: String) -> String {
        "https://github.com/yt-dlp/yt-dlp/releases/download/\(latest)/\(name)"
    }

    private struct Setup {
        let box: ToolSandbox
        let updater: YtDlpUpdater
        var installed: URL { box.root.appendingPathComponent("support/yt-dlp") }
    }

    /// Builds an updater whose "GitHub" offers `latest`. `assetPrints` is what the downloaded
    /// program reports; `checksumMatches` controls whether the published checksum is right.
    private func setup(latest: String, current: String?, bundled: String? = nil,
                       assetPrints: String? = nil, checksumMatches: Bool = true,
                       assetHost: String = "github.com") -> Setup {
        StubURLProtocol.reset()
        let box = ToolSandbox()
        let body = box.makeToolZip(printing: assetPrints ?? latest)
        let binaryURL = "https://\(assetHost)/yt-dlp/yt-dlp/releases/download/\(latest)/yt-dlp_macos.zip"
        let sumsURL = asset(latest, "SHA2-256SUMS")

        let hash = (try? { () throws -> String in
            let f = box.root.appendingPathComponent("tmp-asset"); try body.write(to: f); return try YtDlpUpdater.sha256(of: f)
        }()) ?? ""
        let published = checksumMatches ? hash : String(repeating: "0", count: 64)

        let release: [String: Any] = [
            "tag_name": latest,
            "assets": [
                ["name": "yt-dlp_macos.zip", "browser_download_url": binaryURL],
                ["name": "SHA2-256SUMS", "browser_download_url": sumsURL]
            ]
        ]
        StubURLProtocol.responses[releaseAPI.absoluteString] = (200, try! JSONSerialization.data(withJSONObject: release))
        StubURLProtocol.responses[sumsURL] = (200, Data("\(published)  yt-dlp_macos.zip\n".utf8))
        StubURLProtocol.responses[binaryURL] = (200, body)

        let currentTool = current.map { box.makeTool(in: "current", printing: $0) }
        let bundledTool = bundled.map { box.makeTool(in: "bundled", printing: $0) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let updater = YtDlpUpdater(
            session: URLSession(configuration: config),
            releaseURL: releaseAPI,
            installDirectory: box.root.appendingPathComponent("support"),
            currentTool: { currentTool },
            bundledTool: { bundledTool })
        return Setup(box: box, updater: updater)
    }

    @Test("a newer release is downloaded, verified and installed")
    func installsNewer() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01")
        defer { s.box.cleanUp() }
        let outcome = await s.updater.checkAndUpdate()
        #expect(outcome == .updated(from: "2026.01.01", to: "2099.01.01"))
        #expect(FileManager.default.isExecutableFile(atPath: s.installed.path))
        #expect(YtDlpUpdater.version(of: s.installed) == "2099.01.01")
        // The multi-file build is installed whole: the program and its _internal folder together.
        let internalMarker = s.installed.deletingLastPathComponent().appendingPathComponent("_internal/marker.txt")
        #expect(FileManager.default.fileExists(atPath: internalMarker.path))
    }

    @Test("an archive that is not what was expected is never installed")
    func wrongArchive() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01")
        defer { s.box.cleanUp() }
        // A zip without the "yt-dlp_macos" program, with a matching checksum.
        let junk = Data("not a zip at all".utf8)
        let file = s.box.root.appendingPathComponent("junk")
        try? junk.write(to: file)
        let hash = (try? YtDlpUpdater.sha256(of: file)) ?? ""
        let base = "https://github.com/yt-dlp/yt-dlp/releases/download/2099.01.01/"
        StubURLProtocol.responses[base + "yt-dlp_macos.zip"] = (200, junk)
        StubURLProtocol.responses[base + "SHA2-256SUMS"] = (200, Data("\(hash)  yt-dlp_macos.zip\n".utf8))

        guard case .failed = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("nothing is downloaded when already up to date")
    func upToDate() async {
        let s = setup(latest: "2026.01.01", current: "2026.01.01")
        defer { s.box.cleanUp() }
        #expect(await s.updater.checkAndUpdate() == .upToDate(version: "2026.01.01"))
        #expect(!StubURLProtocol.requested.contains { $0.hasSuffix("yt-dlp_macos.zip") })
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a file whose checksum does not match is never installed")
    func badChecksum() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01", checksumMatches: false)
        defer { s.box.cleanUp() }
        guard case .failed(let message) = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(message.contains("checksum"))
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a download that does not run is never installed")
    func brokenProgram() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01", assetPrints: "this is not a version")
        defer { s.box.cleanUp() }
        guard case .failed = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a program that reports a different version than the release is never installed")
    func wrongVersion() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01", assetPrints: "2000.01.01")
        defer { s.box.cleanUp() }
        guard case .failed = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a download link that is not on GitHub is refused without being requested")
    func untrustedHost() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01", assetHost: "evil.example")
        defer { s.box.cleanUp() }
        guard case .failed = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(!StubURLProtocol.requested.contains { $0.contains("evil.example") })
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a GitHub error leaves everything as it was")
    func githubDown() async {
        let s = setup(latest: "2099.01.01", current: "2026.01.01")
        defer { s.box.cleanUp() }
        StubURLProtocol.responses[releaseAPI.absoluteString] = (503, Data())
        guard case .failed = await s.updater.checkAndUpdate() else { Issue.record("expected failure"); return }
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("with no yt-dlp at all, the latest is installed")
    func installsWhenNothingExists() async {
        let s = setup(latest: "2099.01.01", current: nil)
        defer { s.box.cleanUp() }
        #expect(await s.updater.checkAndUpdate() == .updated(from: nil, to: "2099.01.01"))
    }

    @Test("a downloaded copy older than the one now inside the app is removed")
    func removesStaleUpdate() async {
        let s = setup(latest: "2026.05.01", current: "2026.05.01", bundled: "2026.05.01")
        defer { s.box.cleanUp() }
        try? FileManager.default.createDirectory(at: s.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ToolSandbox.script(printing: "2026.01.01").write(to: s.installed)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.installed.path)

        _ = await s.updater.checkAndUpdate()
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }

    @Test("a downloaded copy that no longer runs is removed")
    func removesBrokenUpdate() async {
        let s = setup(latest: "2026.05.01", current: "2026.05.01", bundled: "2026.05.01")
        defer { s.box.cleanUp() }
        try? FileManager.default.createDirectory(at: s.installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? ToolSandbox.script(printing: "garbage").write(to: s.installed)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: s.installed.path)

        _ = await s.updater.checkAndUpdate()
        #expect(!FileManager.default.fileExists(atPath: s.installed.path))
    }
}

// MARK: - When the check runs

@Suite("Update schedule")
struct UpdateScheduleTests {
    private func defaults() -> UserDefaults { UserDefaults(suiteName: "MacDMSchedule-\(UUID().uuidString)")! }

    @Test("the first launch checks, and records the time")
    func firstLaunch() {
        let d = defaults(); var ran = 0
        YtDlpUpdater.checkIfDue(defaults: d, perform: { ran += 1 })
        #expect(ran == 1)
        #expect(d.object(forKey: YtDlpUpdater.lastCheckKey) != nil)
    }

    @Test("no second check within a day")
    func onceADay() {
        let d = defaults(); var ran = 0
        let now = Date()
        YtDlpUpdater.checkIfDue(defaults: d, now: now, perform: { ran += 1 })
        YtDlpUpdater.checkIfDue(defaults: d, now: now.addingTimeInterval(3600), perform: { ran += 1 })
        #expect(ran == 1)
        YtDlpUpdater.checkIfDue(defaults: d, now: now.addingTimeInterval(25 * 3600), perform: { ran += 1 })
        #expect(ran == 2)
    }

    @Test("turning updates off in Settings stops the check")
    func optOut() {
        let d = defaults(); var ran = 0
        d.set(false, forKey: YtDlpUpdater.autoUpdateKey)
        YtDlpUpdater.checkIfDue(defaults: d, perform: { ran += 1 })
        #expect(ran == 0)
        #expect(d.object(forKey: YtDlpUpdater.lastCheckKey) == nil)
    }
}

// MARK: - Stream names and summaries

@Suite("Detected streams: names and details")
struct StreamTests {
    private func task(url: String, fileName name: String) -> DownloadTask {
        DownloadTask(url: URL(string: url)!, fileName: name, destinationFolder: FileManager.default.temporaryDirectory)
    }

    @Test("a bare playlist keeps the name the page gave, instead of yt-dlp's \"video\"")
    func nameFromPage() {
        let t = task(url: "https://cdn.test/hls/playlist.m3u8", fileName: "English Sub NKKD-280.mp4")
        #expect(MediaDownloadJob.outputTemplate(for: t, selector: "b/bv*+ba") == "English Sub NKKD-280.%(ext)s")
    }

    @Test("a percent sign in the page's name is not read as a yt-dlp field")
    func percentEscaped() {
        let t = task(url: "https://cdn.test/a.m3u8", fileName: "100% Real %(title)s.mp4")
        #expect(MediaDownloadJob.outputTemplate(for: t, selector: "b").hasPrefix("100%% Real %%(title)s"))
    }

    @Test("a page address still uses yt-dlp's own title, and a quality is added to the name")
    func pageUsesYtDlpTitle() {
        let t = task(url: "https://site.test/watch?v=1", fileName: "Whatever - Site.mp4")
        #expect(MediaDownloadJob.outputTemplate(for: t, selector: "bv*[height<=720]+ba") == "%(title).150B [720p].%(ext)s")
    }

    @Test("the sharpest version in a master playlist is chosen, with relative addresses resolved")
    func bestVariant() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720
        720/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=1400000,RESOLUTION=842x480
        480/index.m3u8
        """
        let best = StreamInspector.bestVariant(inMaster: master, base: URL(string: "https://cdn.test/v/master.m3u8")!)
        #expect(best?.height == 720)
        #expect(best?.bandwidth == 2_800_000)
        #expect(best?.url.absoluteString == "https://cdn.test/v/720/index.m3u8")
    }

    @Test("a plain playlist has no variants, and its length is the sum of its pieces")
    func mediaPlaylist() {
        let media = "#EXTM3U\n#EXTINF:10.0,\na.ts\n#EXTINF:10.5,\nb.ts\n#EXT-X-ENDLIST"
        #expect(StreamInspector.bestVariant(inMaster: media, base: URL(string: "https://cdn.test/a.m3u8")!) == nil)
        #expect(StreamInspector.totalDuration(ofMedia: media) == 20.5)
    }

    @Test("the summary combines the resolution, length and a rough size")
    func summary() async {
        let pages = [
            "https://cdn.test/m.m3u8": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=8000000,RESOLUTION=1920x1080\nhd.m3u8",
            "https://cdn.test/hd.m3u8": "#EXTM3U\n#EXTINF:100,\na.ts\n#EXTINF:100,\nb.ts"
        ]
        let summary = await StreamInspector.summary(of: URL(string: "https://cdn.test/m.m3u8")!, headers: [:]) { pages[$0.absoluteString] }
        #expect(summary?.height == 1080)
        #expect(summary?.duration == 200)
        #expect(summary?.estimatedBytes == 200_000_000)
    }

    @Test("something that is not a playlist gives no summary")
    func notAPlaylist() async {
        let summary = await StreamInspector.summary(of: URL(string: "https://cdn.test/x")!, headers: [:]) { _ in "<html></html>" }
        #expect(summary == nil)
    }
}
