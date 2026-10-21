import Foundation

// MARK: - What kind of file a link is

enum GrabKind: String, CaseIterable, Identifiable {
    case video, audio, image, document, archive, program, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .image: return "Images"
        case .document: return "Documents"
        case .archive: return "Archives"
        case .program: return "Programs"
        case .other: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .image: return "photo"
        case .document: return "doc.text"
        case .archive: return "doc.zipper"
        case .program: return "app.badge"
        case .other: return "doc"
        }
    }

    private static let table: [GrabKind: Set<String>] = [
        .video: ["mp4", "m4v", "mov", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "m3u8", "mpd", "3gp"],
        .audio: ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "wma"],
        .image: ["jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "svg", "heic", "avif"],
        .document: ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "csv", "epub", "rtf", "odt"],
        .archive: ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz"],
        .program: ["dmg", "pkg", "exe", "msi", "apk", "deb", "iso"]
    ]

    /// Every extension that counts as a downloadable file.
    static let knownExtensions: Set<String> = table.values.reduce(into: Set<String>()) { $0.formUnion($1) }

    static func of(extension ext: String) -> GrabKind {
        let lower = ext.lowercased()
        return table.first { $0.value.contains(lower) }?.key ?? .other
    }

    /// Refines the kind using the server's Content-Type once it is known.
    static func of(contentType: String?, fallback: GrabKind) -> GrabKind {
        guard let type = contentType?.lowercased() else { return fallback }
        if type.hasPrefix("video/") || type.contains("mpegurl") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        if type.hasPrefix("image/") { return .image }
        return fallback
    }
}

// MARK: - A link found on a page

struct GrabbedLink: Identifiable, Hashable {
    let url: URL
    var name: String
    var kind: GrabKind
    var size: Int64?
    var sourcePage: URL?

    var id: URL { url }

    init(url: URL, sourcePage: URL? = nil, size: Int64? = nil) {
        self.url = url
        self.sourcePage = sourcePage
        self.size = size
        let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        self.name = (last.isEmpty || last == "/") ? (url.host ?? url.absoluteString) : last
        self.kind = GrabKind.of(extension: url.pathExtension)
    }
}

// MARK: - Filtering what was found

struct GrabFilter: Equatable {
    var kinds: Set<GrabKind> = Set(GrabKind.allCases)
    var nameContains = ""
    var minSizeBytes: Int64?

    func matches(_ link: GrabbedLink) -> Bool {
        guard kinds.contains(link.kind) else { return false }
        let needle = nameContains.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty, !link.name.localizedCaseInsensitiveContains(needle) { return false }
        // A size we haven't learned yet can't rule a file out.
        if let minimum = minSizeBytes, let size = link.size, size < minimum { return false }
        return true
    }
}

// MARK: - Reading links out of a page

enum LinkExtractor {
    /// Every web address in the page's HTML, in the order found: normal links, media tags, lazy-loaded
    /// `data-src` attributes, `srcset` lists, social-sharing video tags, and media addresses written
    /// inside scripts. Relative addresses are resolved against `baseURL`.
    static func extract(html: String, baseURL: URL) -> [URL] {
        var found: [URL] = []
        var seen = Set<URL>()

        func add(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\\/", with: "/")
            guard !text.isEmpty, !text.hasPrefix("#") else { return }
            text = text.replacingOccurrences(of: " ", with: "%20")
            guard var url = URL(string: text, relativeTo: baseURL)?.absoluteURL,
                  let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = url.host, !host.isEmpty else { return }
            if var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.fragment != nil {
                parts.fragment = nil
                url = parts.url ?? url
            }
            if seen.insert(url).inserted { found.append(url) }
        }

        func matches(_ pattern: String, in text: String, _ body: (NSTextCheckingResult) -> Void) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return }
            regex.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
                if let match { body(match) }
            }
        }
        func group(_ match: NSTextCheckingResult, _ indexes: [Int], in text: String) -> String? {
            for index in indexes where match.range(at: index).location != NSNotFound {
                if let range = Range(match.range(at: index), in: text) { return String(text[range]) }
            }
            return nil
        }

        // Plain attributes that hold an address.
        matches(#"\b(?:href|src|data-src|data-url|data-video|data-video-url|data-file|poster)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: html) {
            if let value = group($0, [1, 2], in: html) { add(value) }
        }
        // srcset="a.jpg 1x, b.jpg 2x": the address is the first word of each entry.
        matches(#"\bsrcset\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: html) {
            guard let list = group($0, [1, 2], in: html) else { return }
            for entry in list.split(separator: ",") {
                if let first = entry.split(whereSeparator: { $0 == " " || $0 == "\n" }).first { add(String(first)) }
            }
        }
        // <meta property="og:video" content="…">, in either attribute order.
        matches(#"<meta\b[^>]*>"#, in: html) { tag in
            guard let range = Range(tag.range, in: html) else { return }
            let text = String(html[range])
            guard text.range(of: #"og:(video|audio)|twitter:player:stream"#, options: [.regularExpression, .caseInsensitive]) != nil else { return }
            matches(#"\bcontent\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: text) {
                if let value = group($0, [1, 2], in: text) { add(value) }
            }
        }
        // Media addresses written inside scripts (players built with JavaScript), possibly with \/ escapes.
        let unescaped = html.replacingOccurrences(of: "\\/", with: "/")
        matches(#"https?://[^\s"'<>\\]+?\.(?:mp4|m3u8|mpd|webm|m4v|mov|mkv|mp3|m4a)(?:\?[^\s"'<>\\]*)?"#, in: unescaped) {
            if let range = Range($0.range, in: unescaped) { add(String(unescaped[range])) }
        }
        return found
    }

    /// True for a link that leads to another web page rather than to a file.
    static func looksLikePage(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty || ["html", "htm", "php", "asp", "aspx", "jsp", "cgi", "shtml"].contains(ext)
    }
}

// MARK: - Crawling a site

struct GrabProgress: Equatable {
    var pagesScanned = 0
    var filesFound = 0
}

/// Reads a page, and optionally the pages it links to on the same site, collecting file links.
final class SiteCrawler {
    private let session: URLSession
    private let headers: [String: String]
    let maxPages: Int
    let maxFiles: Int

    init(session: URLSession = .shared, headers: [String: String] = [:], maxPages: Int = 30, maxFiles: Int = 3000) {
        self.session = session
        self.headers = headers
        self.maxPages = maxPages
        self.maxFiles = maxFiles
    }

    /// `depth` 0 reads only `start`; 1 also reads pages it links to on the same site; 2 goes one further.
    func crawl(start: URL, depth: Int, onProgress: ((GrabProgress) -> Void)? = nil) async -> [GrabbedLink] {
        var files: [GrabbedLink] = []
        var seenFiles = Set<URL>()
        var visited = Set<URL>([normalized(start)])
        var queue: [(url: URL, depth: Int)] = [(start, 0)]
        var progress = GrabProgress()

        while !queue.isEmpty, progress.pagesScanned < maxPages, files.count < maxFiles, !Task.isCancelled {
            let (page, level) = queue.removeFirst()
            guard let html = await fetchHTML(page) else { continue }
            progress.pagesScanned += 1

            for link in LinkExtractor.extract(html: html, baseURL: page) {
                if GrabKind.knownExtensions.contains(link.pathExtension.lowercased()) {
                    if files.count < maxFiles, seenFiles.insert(link).inserted { files.append(GrabbedLink(url: link, sourcePage: page)) }
                } else if level < depth, LinkExtractor.looksLikePage(link), sameSite(link, start), visited.insert(normalized(link)).inserted {
                    queue.append((link, level + 1))
                }
            }
            progress.filesFound = files.count
            onProgress?(progress)
        }
        return files
    }

    private func fetchHTML(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return nil }
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? "text/html"
        guard type.contains("html") || type.contains("xml") || type.contains("text/plain") else { return nil }
        let body = data.prefix(3_000_000)
        return String(data: body, encoding: .utf8) ?? String(data: body, encoding: .isoLatin1)
    }

    /// The same address without a #fragment, so a page isn't read twice.
    private func normalized(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.fragment = nil
        return parts.url ?? url
    }

    private func sameSite(_ a: URL, _ b: URL) -> Bool {
        func bare(_ url: URL) -> String { (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "", options: .anchored) }
        return bare(a) == bare(b)
    }
}

// MARK: - Learning file sizes

enum SizeProber {
    /// Asks the server for each file's size and type with a HEAD request, a few at a time.
    static func probe(_ urls: [URL], session: URLSession = .shared, headers: [URL: [String: String]] = [:],
                      concurrency: Int = 6, onResult: @escaping @Sendable (URL, Int64?, String?) -> Void) async {
        var iterator = urls.makeIterator()
        await withTaskGroup(of: Void.self) { group in
            func addNext() -> Bool {
                guard let url = iterator.next() else { return false }
                let extra = headers[url] ?? [:]
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 8)
                    request.httpMethod = "HEAD"
                    for (name, value) in extra { request.setValue(value, forHTTPHeaderField: name) }
                    guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse,
                          (200...299).contains(http.statusCode) else { return }
                    let length = http.expectedContentLength
                    onResult(url, length > 0 ? length : nil, http.value(forHTTPHeaderField: "Content-Type"))
                }
                return true
            }
            for _ in 0..<max(1, concurrency) { if !addNext() { break } }
            for await _ in group { _ = addNext() }
        }
    }
}

// MARK: - Links sent from the browser

/// A page's links as the user sees them in their browser (after scripts ran, and while logged in).
struct GrabSession: Equatable {
    let id = UUID()
    let pageURL: URL
    let title: String
    let links: [GrabbedLink]
    let headers: [String: String]?

    /// Headers for downloading `link`. The page's cookies go only to that site (and its sub-domains),
    /// never to other hosts the page happens to link to.
    func headers(for link: URL) -> [String: String] {
        var result = ["Referer": pageURL.absoluteString]
        guard let all = headers else { return result }
        if let agent = all["User-Agent"] { result["User-Agent"] = agent }
        if let cookie = all["Cookie"], Self.sameSite(link, pageURL) { result["Cookie"] = cookie }
        return result
    }

    static func sameSite(_ a: URL, _ b: URL) -> Bool {
        guard let hostA = a.host?.lowercased(), let hostB = b.host?.lowercased() else { return false }
        return hostA == hostB || hostA.hasSuffix("." + hostB) || hostB.hasSuffix("." + hostA)
    }
}

@MainActor
final class SiteGrabberStore: ObservableObject {
    static let shared = SiteGrabberStore()
    @Published var session: GrabSession?

    /// Shows the Site Grabber with these links. (Under the test runner nothing is brought to the screen.)
    func present(_ session: GrabSession) {
        self.session = session
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { AppActions.showMainWindow() }
    }
}
