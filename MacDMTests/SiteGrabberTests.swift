import Foundation
import Testing
@testable import MacDM

private let base = URL(string: "https://site.test/section/page.html")!
private func urls(_ html: String, base: URL = base) -> [String] { LinkExtractor.extract(html: html, baseURL: base).map(\.absoluteString) }

// MARK: - Reading links out of a page

@Suite("Site Grabber: reading links")
struct LinkExtractorTests {
    @Test("normal links: absolute, relative, parent-folder and protocol-relative")
    func normalLinks() {
        let html = """
        <a href="https://other.test/a.zip">a</a> <a href="/root.pdf">r</a> <a href="rel.mp3">x</a>
        <a href="../up.mp4">u</a> <a href="//cdn.test/p.png">p</a>
        """
        #expect(urls(html) == [
            "https://other.test/a.zip", "https://site.test/root.pdf", "https://site.test/section/rel.mp3",
            "https://site.test/up.mp4", "https://cdn.test/p.png"
        ])
    }

    @Test("media tags, lazy-loaded images and poster images are found")
    func mediaTags() {
        let html = """
        <video src="/v/main.mp4" poster="/v/poster.jpg"><source src="/v/alt.webm"></video>
        <audio src="/a/song.mp3"></audio>
        <img data-src="/lazy/photo.jpg">
        <div data-video-url="https://cdn.test/clip.m3u8"></div>
        """
        let found = urls(html)
        for expected in ["https://site.test/v/main.mp4", "https://site.test/v/poster.jpg", "https://site.test/v/alt.webm",
                         "https://site.test/a/song.mp3", "https://site.test/lazy/photo.jpg", "https://cdn.test/clip.m3u8"] {
            #expect(found.contains(expected), "missing \(expected)")
        }
    }

    @Test("srcset lists give every address, without the size descriptors")
    func srcset() {
        let html = #"<img srcset="/i/small.jpg 480w, /i/big.jpg 1080w, //cdn.test/huge.jpg 2x">"#
        #expect(urls(html) == ["https://site.test/i/small.jpg", "https://site.test/i/big.jpg", "https://cdn.test/huge.jpg"])
    }

    @Test("social-sharing video tags are found, whichever order their attributes are in")
    func metaVideo() {
        let html = """
        <meta property="og:video" content="https://cdn.test/share.mp4">
        <meta content="https://cdn.test/other.mp4" property="og:video:url">
        <meta property="og:title" content="https://cdn.test/just-a-page-title">
        """
        let found = urls(html)
        #expect(found.contains("https://cdn.test/share.mp4"))
        #expect(found.contains("https://cdn.test/other.mp4"))
        #expect(!found.contains("https://cdn.test/just-a-page-title"), "only video and audio tags are read")
    }

    @Test("media addresses written inside scripts are found, including \\\\/ escapes")
    func scripts() {
        let html = #"<script>player.load({"hls":"https:\/\/cdn.test\/live\/master.m3u8?t=5","mp4":"https://cdn.test/v.mp4"});</script>"#
        let found = urls(html)
        #expect(found.contains("https://cdn.test/live/master.m3u8?t=5"))
        #expect(found.contains("https://cdn.test/v.mp4"))
    }

    @Test("things that aren't web files are ignored", arguments: [
        #"<a href="mailto:a@b.test">"#, #"<a href="javascript:void(0)">"#, #"<a href="tel:123">"#,
        ##"<a href="#top">"##, #"<img src="data:image/png;base64,AAAA">"#, #"<a href="">"#
    ])
    func ignored(html: String) {
        #expect(urls(html).isEmpty)
    }

    @Test("&amp; is decoded, fragments are dropped, and repeats are listed once")
    func cleanUp() {
        let html = ##"<a href="/f.zip?a=1&amp;b=2#part">x</a> <a href="/f.zip?a=1&b=2">y</a> <a href="/f.zip?a=1&amp;b=2#other">z</a>"##
        #expect(urls(html) == ["https://site.test/f.zip?a=1&b=2"])
    }

    @Test("spaces in an address are encoded, single-quoted and upper-case attributes work")
    func formats() {
        #expect(urls(#"<a HREF='/my file.pdf'>"#) == ["https://site.test/my%20file.pdf"])
    }

    @Test("a link to another page is told apart from a link to a file")
    func pageOrFile() {
        #expect(LinkExtractor.looksLikePage(URL(string: "https://s.test/about")!))
        #expect(LinkExtractor.looksLikePage(URL(string: "https://s.test/a/b.html")!))
        #expect(LinkExtractor.looksLikePage(URL(string: "https://s.test/index.php?id=3")!))
        #expect(!LinkExtractor.looksLikePage(URL(string: "https://s.test/a.zip")!))
        #expect(!LinkExtractor.looksLikePage(URL(string: "https://s.test/a.mp4")!))
    }
}

// MARK: - Kinds, names and filters

@Suite("Site Grabber: kinds and filters")
struct GrabFilterTests {
    @Test("a file's kind comes from its ending", arguments: [
        ("mp4", GrabKind.video), ("MKV", .video), ("m3u8", .video), ("mp3", .audio), ("flac", .audio),
        ("png", .image), ("JPG", .image), ("pdf", .document), ("zip", .archive), ("dmg", .program), ("xyz", .other), ("", .other)
    ])
    func kinds(ext: String, expected: GrabKind) {
        #expect(GrabKind.of(extension: ext) == expected)
    }

    @Test("the server's content type can correct the kind")
    func contentType() {
        #expect(GrabKind.of(contentType: "video/mp4", fallback: .other) == .video)
        #expect(GrabKind.of(contentType: "application/vnd.apple.mpegurl", fallback: .other) == .video)
        #expect(GrabKind.of(contentType: "audio/mpeg", fallback: .other) == .audio)
        #expect(GrabKind.of(contentType: "text/html", fallback: .document) == .document)
        #expect(GrabKind.of(contentType: nil, fallback: .archive) == .archive)
    }

    @Test("the name is the file name with escapes decoded, or the host for a bare address")
    func names() {
        #expect(GrabbedLink(url: URL(string: "https://s.test/a/My%20Movie.mp4")!).name == "My Movie.mp4")
        #expect(GrabbedLink(url: URL(string: "https://s.test/")!).name == "s.test")
        #expect(GrabbedLink(url: URL(string: "https://s.test/x.zip")!).kind == .archive)
    }

    private func link(_ name: String, size: Int64? = nil) -> GrabbedLink {
        GrabbedLink(url: URL(string: "https://s.test/\(name)")!, size: size)
    }

    @Test("the default filter shows everything")
    func showsAll() {
        #expect(GrabFilter().matches(link("a.mp4")))
        #expect(GrabFilter().matches(link("a.weird")))
    }

    @Test("filtering by type")
    func byKind() {
        var filter = GrabFilter(); filter.kinds = [.video, .audio]
        #expect(filter.matches(link("a.mp4")))
        #expect(filter.matches(link("a.mp3")))
        #expect(!filter.matches(link("a.pdf")))
    }

    @Test("filtering by name ignores letter case")
    func byName() {
        var filter = GrabFilter(); filter.nameContains = "  Season 2 "
        #expect(filter.matches(link("show-season 2-ep1.mp4")))
        #expect(!filter.matches(link("show-season 1-ep1.mp4")))
    }

    @Test("filtering by minimum size hides small files, but a size not yet known is kept")
    func bySize() {
        var filter = GrabFilter(); filter.minSizeBytes = 5_000_000
        #expect(filter.matches(link("big.mp4", size: 9_000_000)))
        #expect(filter.matches(link("exact.mp4", size: 5_000_000)))
        #expect(!filter.matches(link("small.mp4", size: 100)))
        #expect(filter.matches(link("unknown.mp4", size: nil)))
    }

    @Test("all filters apply together")
    func together() {
        var filter = GrabFilter(); filter.kinds = [.video]; filter.nameContains = "trailer"; filter.minSizeBytes = 1_000_000
        #expect(filter.matches(link("trailer.mp4", size: 5_000_000)))
        #expect(!filter.matches(link("trailer.mp3", size: 5_000_000)))
        #expect(!filter.matches(link("movie.mp4", size: 5_000_000)))
        #expect(!filter.matches(link("trailer.mp4", size: 10)))
    }
}

// MARK: - Crawling a small site (served from memory)

@Suite("Site Grabber: crawling", .serialized)
struct SiteCrawlerTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    /// A small site:  /  →  files + page2, page3.html, an off-site page;  page2 → more files + page4;  page4 links back to /.
    private func buildSite() {
        StubURLProtocol.reset()
        func page(_ url: String, _ body: String) { StubURLProtocol.responses["https://site.test\(url)"] = StubURLProtocol.html(body) }
        page("/", ##"<a href="/a.zip">a</a> <video src="/video.mp4"></video> <a href="/page2">2</a> <a href="/page3.html">3</a> <a href="https://other.test/off.html">off</a> <a href="#top">top</a>"##)
        page("/page2", #"<a href="/b.pdf">b</a> <a href="/page4">4</a> <a href="/">home</a>"#)
        page("/page3.html", #"<a href="/c.mp3">c</a> <a href="/page2">again</a>"#)
        page("/page4", #"<a href="/d.mkv">d</a> <a href="/">home</a> <a href="/page2">2</a>"#)
        StubURLProtocol.responses["https://other.test/off.html"] = StubURLProtocol.html(#"<a href="/off.zip">off</a>"#)
    }

    private func names(_ links: [GrabbedLink]) -> [String] { links.map(\.name).sorted() }
    private func pagesFetched() -> [String] { StubURLProtocol.requested.sorted() }

    @Test("depth 0 reads only the page itself")
    func depthZero() async {
        buildSite()
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 0)
        #expect(names(found) == ["a.zip", "video.mp4"])
        #expect(pagesFetched() == ["https://site.test/"])
    }

    @Test("depth 1 also reads the pages it links to on the same site")
    func depthOne() async {
        buildSite()
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 1)
        #expect(names(found) == ["a.zip", "b.pdf", "c.mp3", "video.mp4"])
        #expect(pagesFetched() == ["https://site.test/", "https://site.test/page2", "https://site.test/page3.html"])
    }

    @Test("depth 2 goes one level further, and never reads a page twice even when pages link in circles")
    func depthTwo() async {
        buildSite()
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 2)
        #expect(names(found) == ["a.zip", "b.pdf", "c.mp3", "d.mkv", "video.mp4"])
        #expect(Set(StubURLProtocol.requested).count == StubURLProtocol.requested.count, "a page was fetched twice")
    }

    @Test("other websites are never visited")
    func staysOnSite() async {
        buildSite()
        _ = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 2)
        #expect(!StubURLProtocol.requested.contains { $0.contains("other.test") })
    }

    @Test("www and the bare site name count as the same site")
    func wwwIsSameSite() async {
        StubURLProtocol.reset()
        StubURLProtocol.responses["https://www.site.test/"] = StubURLProtocol.html(#"<a href="https://site.test/inner">i</a>"#)
        StubURLProtocol.responses["https://site.test/inner"] = StubURLProtocol.html(#"<a href="/x.zip">x</a>"#)
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://www.site.test/")!, depth: 1)
        #expect(names(found) == ["x.zip"])
    }

    @Test("a limit on the number of pages is respected")
    func pageLimit() async {
        buildSite()
        _ = await SiteCrawler(session: session(), maxPages: 2).crawl(start: URL(string: "https://site.test/")!, depth: 2)
        #expect(StubURLProtocol.requested.count == 2)
    }

    @Test("a limit on the number of files is respected")
    func fileLimit() async {
        StubURLProtocol.reset()
        let many = (0..<50).map { #"<a href="/f\#($0).zip">x</a>"# }.joined()
        StubURLProtocol.responses["https://site.test/"] = StubURLProtocol.html(many)
        let found = await SiteCrawler(session: session(), maxFiles: 10).crawl(start: URL(string: "https://site.test/")!, depth: 0)
        #expect(found.count == 10)
    }

    @Test("a page that can't be read is skipped and the rest still works")
    func brokenPage() async {
        buildSite()
        StubURLProtocol.responses["https://site.test/page2"] = (500, Data())
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 1)
        #expect(names(found) == ["a.zip", "c.mp3", "video.mp4"])
    }

    @Test("something that isn't a web page is not read as one")
    func notHTML() async {
        StubURLProtocol.reset()
        StubURLProtocol.responses["https://site.test/"] = StubURLProtocol.html(#"<a href="/download">d</a>"#)
        StubURLProtocol.responses["https://site.test/download"] = (200, Data(#"<a href="/trap.zip">"#.utf8))
        StubURLProtocol.contentTypes["https://site.test/download"] = "application/octet-stream"
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 1)
        #expect(found.isEmpty)
    }

    @Test("each file remembers which page it was found on")
    func sourcePage() async {
        buildSite()
        let found = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 1)
        #expect(found.first { $0.name == "b.pdf" }?.sourcePage?.absoluteString == "https://site.test/page2")
    }

    @Test("the login headers are sent with every page request")
    func sendsHeaders() async {
        buildSite()
        _ = await SiteCrawler(session: session(), headers: ["Cookie": "s=1", "Referer": "https://site.test/"])
            .crawl(start: URL(string: "https://site.test/")!, depth: 1)
        #expect(!StubURLProtocol.seen.isEmpty)
        for request in StubURLProtocol.seen { #expect(request.headers["Cookie"] == "s=1") }
    }

    @Test("progress is reported as pages are read")
    func progress() async {
        buildSite()
        final class Box: @unchecked Sendable { var last = GrabProgress() }
        let box = Box()
        _ = await SiteCrawler(session: session()).crawl(start: URL(string: "https://site.test/")!, depth: 1) { box.last = $0 }
        #expect(box.last.pagesScanned == 3)
        #expect(box.last.filesFound == 4)
    }
}

// MARK: - Learning sizes

@Suite("Site Grabber: sizes", .serialized)
struct SizeProberTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [URL: (Int64?, String?)] = [:]
        func set(_ url: URL, _ size: Int64?, _ type: String?) { lock.lock(); map[url] = (size, type); lock.unlock() }
        subscript(_ url: URL) -> (Int64?, String?)? { lock.lock(); defer { lock.unlock() }; return map[url] }
        var count: Int { lock.lock(); defer { lock.unlock() }; return map.count }
    }

    @Test("sizes and types are read for every link, a few at a time")
    func readsSizes() async {
        StubURLProtocol.reset()
        let list = (0..<20).map { URL(string: "https://site.test/f\($0).mp4")! }
        for url in list {
            StubURLProtocol.responses[url.absoluteString] = (200, Data())
            StubURLProtocol.declaredSizes[url.absoluteString] = 1_000 + url.absoluteString.count
            StubURLProtocol.contentTypes[url.absoluteString] = "video/mp4"
        }
        let results = Results()
        await SizeProber.probe(list, session: session()) { results.set($0, $1, $2) }
        #expect(results.count == 20)
        #expect(results[list[3]]?.0 == Int64(1_000 + list[3].absoluteString.count))
        #expect(results[list[3]]?.1 == "video/mp4")
        #expect(StubURLProtocol.seen.allSatisfy { $0.method == "HEAD" }, "only HEAD requests, nothing downloaded")
    }

    @Test("a file the server refuses is simply left without a size")
    func skipsErrors() async {
        StubURLProtocol.reset()
        let good = URL(string: "https://site.test/good.mp4")!, bad = URL(string: "https://site.test/bad.mp4")!
        StubURLProtocol.responses[good.absoluteString] = (200, Data()); StubURLProtocol.declaredSizes[good.absoluteString] = 777
        StubURLProtocol.responses[bad.absoluteString] = (403, Data())
        let results = Results()
        await SizeProber.probe([good, bad], session: session()) { results.set($0, $1, $2) }
        #expect(results[good]?.0 == 777)
        #expect(results[bad] == nil)
    }

    @Test("each file gets its own headers")
    func ownHeaders() async {
        StubURLProtocol.reset()
        let a = URL(string: "https://a.test/x.mp4")!, b = URL(string: "https://b.test/y.mp4")!
        StubURLProtocol.responses[a.absoluteString] = (200, Data()); StubURLProtocol.responses[b.absoluteString] = (200, Data())
        await SizeProber.probe([a, b], session: session(), headers: [a: ["Cookie": "for-a"], b: ["Referer": "https://b.test/"]]) { _, _, _ in }
        let seenA = StubURLProtocol.seen.first { $0.url == a.absoluteString }
        let seenB = StubURLProtocol.seen.first { $0.url == b.absoluteString }
        #expect(seenA?.headers["Cookie"] == "for-a")
        #expect(seenB?.headers["Cookie"] == nil)
        #expect(seenB?.headers["Referer"] == "https://b.test/")
    }
}

// MARK: - Links sent from the browser

@Suite("Site Grabber: browser session")
struct GrabSessionTests {
    private let page = URL(string: "https://site.test/watch/1")!
    private func session(_ headers: [String: String]?) -> GrabSession { GrabSession(pageURL: page, title: "t", links: [], headers: headers) }

    @Test("the page's cookies go to that site and its sub-domains, never to other hosts")
    func cookiesStayOnSite() {
        let s = session(["Cookie": "login=1", "User-Agent": "TestBrowser/1.0"])
        #expect(s.headers(for: URL(string: "https://site.test/a.mp4")!)["Cookie"] == "login=1")
        #expect(s.headers(for: URL(string: "https://cdn.site.test/a.mp4")!)["Cookie"] == "login=1")
        #expect(s.headers(for: URL(string: "https://www.site.test/a.mp4")!)["Cookie"] == "login=1")
        #expect(s.headers(for: URL(string: "https://other.test/a.mp4")!)["Cookie"] == nil)
        #expect(s.headers(for: URL(string: "https://evilsite.test/a.mp4")!)["Cookie"] == nil, "a look-alike name is a different site")
        #expect(s.headers(for: URL(string: "https://site.test.evil.test/a.mp4")!)["Cookie"] == nil)
    }

    @Test("the page address is always the Referer, and the browser's User-Agent is always passed on")
    func refererAlways() {
        let s = session(["Cookie": "login=1", "User-Agent": "TestBrowser/1.0"])
        for host in ["site.test", "other.test"] {
            let headers = s.headers(for: URL(string: "https://\(host)/a.mp4")!)
            #expect(headers["Referer"] == "https://site.test/watch/1")
            #expect(headers["User-Agent"] == "TestBrowser/1.0")
        }
    }

    @Test("without browser headers only the Referer is sent")
    func onlyReferer() {
        #expect(session(nil).headers(for: URL(string: "https://site.test/a.mp4")!) == ["Referer": "https://site.test/watch/1"])
    }
}

@MainActor
@Suite("Site Grabber: window logic")
struct SiteGrabberModelTests {
    private func link(_ name: String, size: Int64? = nil) -> GrabbedLink {
        GrabbedLink(url: URL(string: "http://127.0.0.1:9/\(name)")!, size: size)
    }
    private func loaded(_ links: [GrabbedLink], headers: [String: String]? = nil) -> SiteGrabberModel {
        let model = SiteGrabberModel()
        model.load(GrabSession(pageURL: URL(string: "http://127.0.0.1:9/page")!, title: "t", links: links, headers: headers))
        return model
    }

    @Test("links from the browser fill the window and mark it as coming from the browser")
    func loadsSession() {
        let model = loaded([link("a.mp4"), link("b.pdf")])
        #expect(model.fromBrowser)
        #expect(model.links.count == 2)
        #expect(model.pageURLString == "http://127.0.0.1:9/page")
        #expect(model.selected.isEmpty)
        model.stop()
    }

    @Test("select all and deselect all act only on the links currently shown")
    func selectVisible() {
        let model = loaded([link("a.mp4"), link("b.mp4"), link("c.pdf")])
        model.toggleKind(.document)                    // hide documents
        #expect(model.visible.count == 2)
        model.selectAllVisible(true)
        #expect(model.selected.count == 2)
        model.toggleKind(.document)                    // show them again
        #expect(!model.selected.contains(link("c.pdf").url))
        model.selectAllVisible(false)
        #expect(model.selected.isEmpty)
        model.stop()
    }

    @Test("the minimum size field turns into a filter, and clearing it removes the filter")
    func minimumSize() {
        let model = loaded([link("big.mp4", size: 50_000_000), link("small.mp4", size: 1_000)])
        model.minSizeMB = "10"; model.applyMinimumSize()
        #expect(model.visible.map(\.name) == ["big.mp4"])
        model.minSizeMB = "1,5"; model.applyMinimumSize()
        #expect(model.filter.minSizeBytes == Int64(1.5 * 1_048_576))
        model.minSizeMB = ""; model.applyMinimumSize()
        #expect(model.visible.count == 2)
        model.stop()
    }

    @Test("downloading the selection queues each file with the right headers")
    func downloadsSelected() {
        let model = loaded([link("a.mp4"), link("b.mp4"), link("c.mp4")], headers: ["Cookie": "login=1", "User-Agent": "TB/1"])
        model.toggle(link("a.mp4")); model.toggle(link("c.mp4"))
        let env = IsolatedManager(); defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        model.downloadSelected(into: env.manager)
        #expect(env.manager.tasks.count == 2)
        #expect(Set(env.manager.tasks.map(\.fileName)) == ["a.mp4", "c.mp4"])
        for task in env.manager.tasks {
            #expect(task.requestHeaders?["Referer"] == "http://127.0.0.1:9/page")
            #expect(task.requestHeaders?["Cookie"] == "login=1")
        }
        model.stop()
    }

    @Test("a bad address shows a message and starts nothing")
    func badAddress() {
        let model = SiteGrabberModel()
        model.pageURLString = "file:///etc/passwd"
        model.scan()
        #expect(model.errorText != nil)
        #expect(!model.isScanning)
    }
}
