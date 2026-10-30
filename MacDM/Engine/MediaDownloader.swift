import Foundation
import CryptoKit

// MARK: - Errors

enum MediaError: LocalizedError {
    case ytDlpMissing
    case extractionFailed(String)
    case badOutput

    /// Wraps a yt-dlp stderr line, replacing known cookie/bot-check failures with actionable advice.
    static func fromYtDlp(_ line: String) -> MediaError {
        let cleaned = line.replacingOccurrences(of: "ERROR: ", with: "")
        if cleaned.contains("not a bot") {
            // YouTube's own check. The extension sends the page's sign-in with every request, so what helps is being
            // signed in to YouTube in Chrome (and passing any check YouTube shows there), then trying again.
            return .extractionFailed("YouTube is asking to confirm you're not a bot. Make sure you are signed in to YouTube in Chrome (and pass any check it shows), reload the page, and try again. If it keeps happening, wait a few minutes.")
        }
        return .extractionFailed(cleaned)
    }

    var errorDescription: String? {
        switch self {
        case .ytDlpMissing:
            return "yt-dlp was not found. Install it with: brew install yt-dlp ffmpeg"
        case .extractionFailed(let message):
            return message
        case .badOutput:
            return "yt-dlp returned data MacDM could not read."
        }
    }
}

// MARK: - Tool discovery

/// Finds yt-dlp and ffmpeg. GUI apps don't inherit the shell PATH, so the locations are explicit.
///
/// Order (first match wins):
///   1. a newer yt-dlp the app downloaded itself (Application Support/MacDM/bin)
///   2. the copies shipped inside the app (Contents/Resources/yt-dlp and Contents/Helpers)
///   3. Homebrew / user installs (mainly useful when running from Xcode)
enum MediaTools {
    /// Where the app keeps a yt-dlp newer than the bundled one.
    static var updatedDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacDM/bin", isDirectory: true)
    }

    /// ffmpeg, shipped inside the app bundle.
    static var bundledDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    /// yt-dlp, shipped inside the app bundle. It is a program plus a folder of libraries, which
    /// live in Resources because macOS only allows signed code files in Helpers.
    static var bundledYtDlpDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/yt-dlp", isDirectory: true)
    }

    private static let systemDirs: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        "/usr/bin"
    ]

    static var searchDirs: [String] {
        [updatedDirectory.path, bundledYtDlpDirectory.path, bundledDirectory.path] + systemDirs
    }

    static func find(_ name: String, in dirs: [String]? = nil) -> URL? {
        for dir in dirs ?? searchDirs {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// Environment for child processes so yt-dlp can find ffmpeg, python, etc.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (searchDirs + [existing]).joined(separator: ":")
        return env
    }

    static var hasFFmpeg: Bool { find("ffmpeg") != nil }

    /// Runs each bundled tool once in the background at launch. The first run of a program
    /// that macOS hasn't seen yet is slow (it checks every file); doing it now means the
    /// first video lookup the user asks for is already fast.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            for (name, flag) in [("yt-dlp", "--version"), ("ffmpeg", "-version")] {
                guard let tool = find(name) else { continue }
                let process = Process()
                process.executableURL = tool
                process.arguments = [flag]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                process.waitUntilExit()
            }
        }
    }

}

// MARK: - The browser's sign-in, handed over by the extension

/// Writes cookies in the Netscape cookies.txt format that yt-dlp reads. The file is private to the owner and is
/// deleted when the lookup or download ends.
enum CookieFile {
    static let fileName = "cookies.txt"

    static func text(for cookies: [BrowserCookie]) -> String {
        var lines = ["# Netscape HTTP Cookie File"]
        for cookie in cookies {
            let includeSubdomains = cookie.domain.hasPrefix(".") ? "TRUE" : "FALSE"
            let prefix = cookie.httpOnly ? "#HttpOnly_" : ""
            lines.append([prefix + cookie.domain, includeSubdomains, cookie.path, cookie.secure ? "TRUE" : "FALSE",
                          String(cookie.expires), cookie.name, cookie.value].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Creates the file readable by the owner only.
    static func write(_ cookies: [BrowserCookie], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let made = FileManager.default.createFile(atPath: url.path, contents: Data(text(for: cookies).utf8),
                                                  attributes: [.posixPermissions: 0o600])
        if !made { throw CocoaError(.fileWriteUnknown) }
    }

    /// `--cookies <file>` when the download has its cookie file, otherwise nothing.
    static func arguments(for task: DownloadTask) -> [String] {
        guard let work = task.workFolder else { return [] }
        let file = work.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: file.path) ? ["--cookies", file.path] : []
    }
}

// MARK: - Format discovery

struct MediaFormatOption {
    let label: String
    let selector: String
    let sizeBytes: Int64?
    let audioOnly: Bool
    /// Picture size in pixels, when the site says it. Only shown to the user; the download uses `selector`.
    var width: Int? = nil
    var height: Int? = nil
    /// A short description shown under the name, for audio: "AAC · 129 kbps", "FLAC · lossless".
    var detail: String? = nil

    var dictionary: [String: Any] {
        var dict: [String: Any] = ["label": label, "selector": selector, "audioOnly": audioOnly]
        if let sizeBytes { dict["sizeBytes"] = sizeBytes }
        if let width { dict["width"] = width }
        if let height { dict["height"] = height }
        if let detail { dict["detail"] = detail }
        return dict
    }
}

struct MediaInfo {
    let title: String
    let thumbnail: String?
    let duration: Double?
    let options: [MediaFormatOption]
}

/// Collects a child process's pipe output without risking a full-pipe deadlock.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ newData: Data) { lock.lock(); data = newData; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

/// Keeps the `yt-dlp -J` result from the format lookup so the download can reuse it
/// (`--load-info-json`) instead of asking the site again. Some sites throttle or
/// reject a second extraction made seconds after the first.
enum MediaInfoCache {
    private static let maxAge: TimeInterval = 3600 // stream URLs expire eventually

    private static var directory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("MacDM/media-info", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".json")
    }

    static func store(_ data: Data, for url: URL) {
        purgeExpired()
        let file = fileURL(for: url)
        try? scrubbed(data).write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)   // owner only
    }

    /// The lookup result without anything that carries a sign-in: "cookies" fields and Cookie or Authorization
    /// headers, wherever they appear. The download gets its sign-in from its own private cookie file instead.
    static func scrubbed(_ data: Data) -> Data {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { return data }
        func clean(_ value: Any) -> Any {
            if let dictionary = value as? [String: Any] {
                var result: [String: Any] = [:]
                for (key, inner) in dictionary {
                    if key.lowercased() == "cookies" || ["cookie", "authorization"].contains(key.lowercased()) { continue }
                    result[key] = clean(inner)
                }
                return result
            }
            if let list = value as? [Any] { return list.map(clean) }
            return value
        }
        return (try? JSONSerialization.data(withJSONObject: clean(object))) ?? data
    }

    /// The cached file for this page, if it exists and is still fresh.
    static func freshFile(for url: URL) -> URL? {
        let file = fileURL(for: url)
        guard let modified = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.modificationDate] as? Date,
              Date().timeIntervalSince(modified) < maxAge else { return nil }
        return file
    }

    static func remove(for url: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: url))
    }

    private static func purgeExpired() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, Date().timeIntervalSince(modified) > maxAge {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }
}

/// Remembers recent video lookups so opening the quality list again is instant, and so two
/// identical requests at the same moment share one yt-dlp run. Failures are never remembered.
actor MediaInfoStore {
    static let shared = MediaInfoStore()

    private let ttl: TimeInterval
    private let now: () -> Date
    private var cache: [String: (info: MediaInfo, date: Date)] = [:]
    private var inFlight: [String: Task<MediaInfo, Error>] = [:]

    init(ttl: TimeInterval = 600, now: @escaping () -> Date = { Date() }) {
        self.ttl = ttl
        self.now = now
    }

    func info(for key: String, load: @escaping @Sendable () async throws -> MediaInfo) async throws -> MediaInfo {
        if let hit = cache[key], now().timeIntervalSince(hit.date) < ttl { return hit.info }
        if let running = inFlight[key] { return try await running.value }

        let task = Task { try await load() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let info = try await task.value
        cache[key] = (info, now())
        return info
    }

    func clear() { cache = [:] }
}

enum MediaExtractor {
    /// Like `fetchInfo`, but reuses a result from the last few minutes for the same page.
    /// Whether a sign-in was sent is part of the key, so a lookup that failed without one is retried with one.
    static func fetchInfoCached(url: URL, referer: String?, cookies: [BrowserCookie] = []) async throws -> MediaInfo {
        let key = [url.absoluteString, referer ?? "", cookies.isEmpty ? "anonymous" : "signed-in"].joined(separator: "|")
        return try await MediaInfoStore.shared.info(for: key) {
            try await fetchInfo(url: url, referer: referer, cookies: cookies)
        }
    }

    /// Runs `yt-dlp -J` for the page and condenses the result into quality choices.
    static func fetchInfo(url: URL, referer: String?, cookies: [BrowserCookie] = []) async throws -> MediaInfo {
        guard let ytDlp = MediaTools.find("yt-dlp") else { throw MediaError.ytDlpMissing }

        var args = ["-J", "--no-playlist", "--no-warnings"]
        if !cookies.isEmpty {
            // A private one-off file for this lookup; removed as soon as yt-dlp has finished.
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("macdm-cookies-\(UUID().uuidString).txt")
            try CookieFile.write(cookies, to: file)
            defer { try? FileManager.default.removeItem(at: file) }
            args += ["--cookies", file.path]
            return try await runLookup(ytDlp, args: args, url: url, referer: referer)
        }
        return try await runLookup(ytDlp, args: args, url: url, referer: referer)
    }

    private static func runLookup(_ ytDlp: URL, args: [String], url: URL, referer: String?) async throws -> MediaInfo {
        var args = args
        if let referer, !referer.isEmpty { args += ["--referer", referer] }
        args += ["--", url.absoluteString]

        let (stdout, stderr, status) = try await run(ytDlp, arguments: args)
        guard status == 0 else {
            let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? "yt-dlp failed."
            throw MediaError.fromYtDlp(lastLine)
        }
        guard let json = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] else {
            throw MediaError.badOutput
        }
        MediaInfoCache.store(stdout, for: url)
        return buildInfo(from: json)
    }

    /// What the "Audio only" download will fetch, in words: the codec and bitrate of the stream it prefers
    /// (the best m4a, otherwise the best audio there is). Nil when the site says nothing about it.
    static func audioDetail(of audioStreams: [[String: Any]]) -> String? {
        func bitrate(_ f: [String: Any]) -> Double {
            (f["abr"] as? NSNumber)?.doubleValue ?? (f["tbr"] as? NSNumber)?.doubleValue ?? 0
        }
        let m4a = audioStreams.filter { ($0["ext"] as? String) == "m4a" }
        let pool = m4a.isEmpty ? audioStreams : m4a
        guard let best = pool.max(by: { bitrate($0) < bitrate($1) }) else { return nil }

        let codec = ((best["acodec"] as? String) ?? "").lowercased()
        let ext = ((best["ext"] as? String) ?? (best["audio_ext"] as? String) ?? "").lowercased()
        let names: [(prefix: String, name: String)] = [("mp4a", "AAC"), ("opus", "Opus"), ("flac", "FLAC"), ("alac", "ALAC"),
                                                       ("mp3", "MP3"), ("vorbis", "Vorbis"), ("ec-3", "E-AC-3"), ("ac-3", "AC-3")]
        let name = names.first(where: { codec.hasPrefix($0.prefix) })?.name
            ?? (["m4a", "aac"].contains(ext) ? "AAC" : (ext.isEmpty || ext == "none" ? nil : ext.uppercased()))

        var parts: [String] = []
        if let name { parts.append(name) }
        if ["FLAC", "ALAC"].contains(name ?? "") { parts.append("lossless") }
        else if bitrate(best) >= 1 { parts.append("\(Int(bitrate(best).rounded())) kbps") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Condenses yt-dlp's `-J` output into quality choices. `canMerge` says whether
    /// ffmpeg is available to join separate video and audio streams.
    static func buildInfo(from json: [String: Any], canMerge: Bool = MediaTools.hasFFmpeg) -> MediaInfo {
        let title = (json["title"] as? String) ?? "video"
        let thumbnail = json["thumbnail"] as? String
        let duration = json["duration"] as? Double
        let formats = (json["formats"] as? [[String: Any]]) ?? []

        func size(_ f: [String: Any]) -> Int64? {
            if let n = f["filesize"] as? NSNumber { return n.int64Value }
            if let n = f["filesize_approx"] as? NSNumber { return n.int64Value }
            return nil
        }
        // Many sites do not say which codecs a format uses. A missing value means "unknown", so it is
        // treated as present; only an explicit "none" means the stream is absent.
        func hasVideo(_ f: [String: Any]) -> Bool { (f["vcodec"] as? String) != "none" }
        func hasAudio(_ f: [String: Any]) -> Bool { (f["acodec"] as? String) != "none" }
        /// A stream that is known to be audio only.
        func isAudioOnly(_ f: [String: Any]) -> Bool { (f["vcodec"] as? String) == "none" && hasAudio(f) }

        // Without ffmpeg only pre-merged (video+audio) formats are usable.
        let videoFormats = formats.filter { f in
            hasVideo(f) && (f["height"] as? Int) != nil && (canMerge || hasAudio(f))
        }
        let bestAudioSize = formats.filter(isAudioOnly).compactMap(size).max() ?? 0

        var options: [MediaFormatOption] = []
        let heights = Set(videoFormats.compactMap { $0["height"] as? Int }).sorted(by: >)
        for height in heights.prefix(8) {
            let videoSize = videoFormats.filter { ($0["height"] as? Int) == height }.compactMap(size).max()
            let total = videoSize.map { $0 + (canMerge ? bestAudioSize : 0) }
            let selector = canMerge
                ? "bv*[height<=\(height)]+ba/b[height<=\(height)]"
                : "b[height<=\(height)]/b"
            // The widest picture offered at this height, so the list can show "1920 × 1080".
            let width = videoFormats.filter { ($0["height"] as? Int) == height }.compactMap { $0["width"] as? Int }.max()
            options.append(MediaFormatOption(label: "\(height)p", selector: selector, sizeBytes: total, audioOnly: false,
                                             width: width, height: height))
        }

        let hasVideoOptions = !options.isEmpty

        // "Audio only" needs a real audio-only stream; a source of ready-made video files has none.
        if formats.contains(where: isAudioOnly) {
            let audioSize = bestAudioSize > 0 ? bestAudioSize : nil
            options.append(MediaFormatOption(label: "Audio only", selector: "ba[ext=m4a]/ba/b", sizeBytes: audioSize, audioOnly: true,
                                             detail: audioDetail(of: formats.filter(isAudioOnly))))
        }

        // Sources that expose no sizes (direct links, some HLS, sites that don't describe their formats):
        // offer "Best available" first so the video itself can still be downloaded.
        // The one exception is a source that is audio only.
        let isAudioOnlySource = !formats.isEmpty && formats.allSatisfy { !hasVideo($0) }
        if !hasVideoOptions && !isAudioOnlySource {
            options.insert(MediaFormatOption(label: "Best available", selector: "b/bv*+ba", sizeBytes: nil, audioOnly: false), at: 0)
        }
        // Never show an empty list: the user can always try the best version yt-dlp can find.
        if options.isEmpty {
            options.append(MediaFormatOption(label: "Best available", selector: "b/bv*+ba", sizeBytes: nil, audioOnly: false))
        }
        return MediaInfo(title: title, thumbnail: thumbnail, duration: duration, options: options)
    }

    private static func run(_ executable: URL, arguments: [String]) async throws -> (Data, String, Int32) {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = MediaTools.environment
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            let outBox = DataBox()
            let errBox = DataBox()
            let group = DispatchGroup()

            process.terminationHandler = { finished in
                group.notify(queue: .global()) {
                    let stderr = String(decoding: errBox.value, as: UTF8.self)
                    continuation.resume(returning: (outBox.value, stderr, finished.terminationStatus))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Drain both pipes on background threads so large JSON can't block the child.
            DispatchQueue.global().async(group: group) {
                outBox.set(outPipe.fileHandleForReading.readDataToEndOfFile())
            }
            DispatchQueue.global().async(group: group) {
                errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
            }
        }
    }
}

// MARK: - Download job

/// Runs one yt-dlp download and mirrors its progress onto a DownloadTask.
/// Pause/cancel terminate the process; yt-dlp resumes from its .part file on restart.
final class MediaDownloadJob {
    private let task: DownloadTask
    private var process: Process?
    private var stopRequested = false

    var speedLimitBytesPerSec: Double = 0
    /// How many pieces of an HLS/DASH stream yt-dlp fetches at the same time (it does one by one unless told).
    var concurrentFragments = 8
    var onFinished: ((Result<Void, Error>) -> Void)?

    init(task: DownloadTask) {
        self.task = task
    }

    func start() {
        launch(useCache: true, attempt: 0)
    }

    private func launch(useCache: Bool, attempt: Int) {
        guard let selector = task.mediaFormat else { return }
        guard let ytDlp = MediaTools.find("yt-dlp") else {
            fail(MediaError.ytDlpMissing)
            return
        }

        // yt-dlp keeps its unfinished and fragment files in this download's own hidden folder; only the finished
        // file is placed in the download folder.
        if let work = task.workFolder { try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }

        var args = [
            "--newline", "--no-playlist", "--no-warnings", "--continue", "--progress",
            "--progress-template",
            "download:MACDMPROGRESS %(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s",
            "--print", "after_move:MACDMFILE %(filepath)s",
            "-f", selector,
            "-N", String(max(1, concurrentFragments)),
            // A new download finishes inside its own hidden folder and is then moved into the download folder under
            // a free name (see complete). Older downloads write straight into the download folder.
            "-P", (task.workFolder ?? task.destinationFolder).path,
            "-o", Self.outputTemplate(for: task, selector: selector)
        ]
        args += CookieFile.arguments(for: task)
        if selector.contains("+") { args += ["--merge-output-format", "mp4"] }
        if let ffmpeg = MediaTools.find("ffmpeg") {
            args += ["--ffmpeg-location", ffmpeg.deletingLastPathComponent().path]
        }
        if let referer = task.mediaReferer, !referer.isEmpty { args += ["--referer", referer] }
        // The browser's identity and cookies, so protected streams open for yt-dlp as they did for the browser.
        for name in ["Cookie", "User-Agent", "Origin"] {
            if let value = task.requestHeaders?[name] { args += ["--add-header", "\(name):\(value)"] }
        }
        if speedLimitBytesPerSec > 0 { args += ["--limit-rate", String(Int(speedLimitBytesPerSec))] }
        // Reuse the format lookup's result when we have it: no second hit on the site.
        let cachedInfo = useCache ? MediaInfoCache.freshFile(for: task.url) : nil
        if let cachedInfo {
            args += ["--load-info-json", cachedInfo.path]
        } else {
            args += ["--", task.url.absoluteString]
        }

        let process = Process()
        process.executableURL = ytDlp
        process.arguments = args
        process.environment = MediaTools.environment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let errBox = DataBox()
        let outputGroup = DispatchGroup()
        var finalPath: String?
        let pathLock = NSLock()

        process.terminationHandler = { [weak self] finished in
            outputGroup.notify(queue: .main) {
                guard let self, !self.stopRequested else { return }
                self.process = nil
                if finished.terminationStatus == 0 {
                    pathLock.lock(); let path = finalPath; pathLock.unlock()
                    self.complete(finalPath: path)
                } else {
                    let stderr = String(decoding: errBox.value, as: UTF8.self)
                    let lastLine = stderr.split(separator: "\n").last.map(String.init) ?? "yt-dlp exited with an error."
                    if cachedInfo != nil {
                        // Cached info may be stale (expired stream URLs): retry with a fresh extraction.
                        MediaInfoCache.remove(for: self.task.url)
                        self.launch(useCache: false, attempt: attempt)
                    } else if lastLine.contains("Failed to parse JSON"), attempt < 2 {
                        // The site is throttling repeated requests; wait and try again.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                            guard let self, !self.stopRequested else { return }
                            self.launch(useCache: false, attempt: attempt + 1)
                        }
                    } else {
                        self.fail(MediaError.fromYtDlp(lastLine))
                    }
                }
            }
        }

        do {
            try process.run()
        } catch {
            fail(error)
            return
        }
        self.process = process

        task.status = .downloading
        task.errorMessage = nil

        // Read stdout line by line for progress and the final file path.
        DispatchQueue.global().async(group: outputGroup) { [weak self] in
            var buffer = Data()
            let handle = outPipe.fileHandleForReading
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<newline)
                    buffer.removeSubrange(buffer.startIndex...newline)
                    let line = String(decoding: lineData, as: UTF8.self)
                    if line.hasPrefix("MACDMFILE ") {
                        pathLock.lock(); finalPath = String(line.dropFirst("MACDMFILE ".count)); pathLock.unlock()
                    } else if line.hasPrefix("MACDMPROGRESS ") {
                        self?.applyProgress(String(line.dropFirst("MACDMPROGRESS ".count)))
                    }
                }
            }
        }
        DispatchQueue.global().async(group: outputGroup) {
            errBox.set(errPipe.fileHandleForReading.readDataToEndOfFile())
        }
    }

    /// Filename suffix like " [1080p]" so different qualities of one video don't
    /// share a filename (yt-dlp would skip the download as "already downloaded").
    fileprivate static func qualitySuffix(for selector: String) -> String {
        if let range = selector.range(of: "height<=") {
            let digits = selector[range.upperBound...].prefix { $0.isNumber }
            if !digits.isEmpty { return " [\(digits)p]" }
        }
        if selector.hasPrefix("ba") { return " [audio]" }
        return ""
    }

    /// Stops the process and sets the task to `.paused` or `.cancelled`.
    func stop(as status: DownloadStatus) {
        stopRequested = true
        let running = process
        running?.terminate()
        process = nil
        task.status = status
        task.speedBytesPerSec = 0
        if status == .cancelled {
            // yt-dlp may write a little more before it exits, so delete once it has really stopped.
            let task = self.task
            DispatchQueue.global().async {
                running?.waitUntilExit()
                task.deleteUnfinishedFiles()
            }
        }
    }

    // MARK: - Helpers

    private func applyProgress(_ payload: String) {
        let parts = payload.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 4 else { return }
        func number(_ text: String) -> Double? { Double(text) }
        let downloaded = number(parts[0]).map { Int64($0) }
        let total = number(parts[1]).map { Int64($0) } ?? number(parts[2]).map { Int64($0) }
        let speed = number(parts[3])

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.stopRequested else { return }
            if let total { self.task.totalBytes = total }
            if let downloaded { self.task.downloadedBytes = downloaded }
            self.task.speedBytesPerSec = speed ?? 0
        }
    }

    private func complete(finalPath: String?) {
        MediaInfoCache.remove(for: task.url)
        if let finalPath {
            var url = URL(fileURLWithPath: finalPath)
            if task.workFolder != nil, FileManager.default.fileExists(atPath: finalPath) {
                // Never replace a file that is already in the download folder: a repeat becomes "name (1)".
                do {
                    url = try FileNaming.moveWithoutReplacing(url, as: url.lastPathComponent, into: task.destinationFolder)
                } catch {
                    fail(error)   // the finished file stays safe in the hidden folder
                    return
                }
            }
            task.fileName = url.lastPathComponent
            task.category = DownloadCategory.categorize(fileName: task.fileName)
            let size = (try? FileManager.default.attributesOfItem(atPath: finalPath)[.size] as? Int64) ?? nil
            if let size {
                task.totalBytes = size
                task.downloadedBytes = size
            }
        }
        task.deleteUnfinishedFiles()   // yt-dlp has moved the finished file out; nothing else stays
        task.status = .completed
        task.dateCompleted = Date()
        task.speedBytesPerSec = 0
        onFinished?(.success(()))
    }

    private func fail(_ error: Error) {
        task.status = .failed
        task.errorMessage = error.localizedDescription
        task.speedBytesPerSec = 0
        onFinished?(.failure(error))
    }
}

// MARK: - Naming and describing detected streams

extension MediaDownloadJob {
    /// The yt-dlp output template. A bare stream address (playlist.m3u8) has no real title of its own, so yt-dlp
    /// would call the file "video" or "playlist"; for those the name the page gave is used instead.
    static func outputTemplate(for task: DownloadTask, selector: String) -> String {
        let suffix = qualitySuffix(for: selector)
        let isBareStream = ["m3u8", "mpd"].contains(task.url.pathExtension.lowercased())
        let stem = (task.fileName as NSString).deletingPathExtension
        if isBareStream, !stem.isEmpty, stem != "video" {
            // "%" starts a yt-dlp template field, so a literal one is doubled.
            let literal = String(stem.prefix(120)).replacingOccurrences(of: "%", with: "%%")
            return "\(literal)\(suffix).%(ext)s"
        }
        return "%(title).150B\(suffix).%(ext)s"
    }
}

/// What a detected HLS stream is, read from its playlist: how sharp, how long and roughly how big.
struct StreamSummary: Equatable {
    var width: Int?
    var height: Int?
    var duration: Double?
    var bandwidth: Int64?        // bits per second of the best version

    var estimatedBytes: Int64? {
        guard let duration, let bandwidth, duration > 0 else { return nil }
        return Int64(duration * Double(bandwidth) / 8)
    }
}

enum StreamInspector {
    struct Variant: Equatable {
        var url: URL
        var width: Int?
        var height: Int?
        var bandwidth: Int64?
    }

    /// The sharpest version listed in a master playlist, or nil when the text is a plain (media) playlist.
    static func bestVariant(inMaster text: String, base: URL) -> Variant? {
        var best: Variant?
        var pending: [String: String]?
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(of: String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            } else if let attrs = pending, !line.isEmpty, !line.hasPrefix("#") {
                pending = nil
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                var variant = Variant(url: url, bandwidth: (attrs["BANDWIDTH"] ?? attrs["AVERAGE-BANDWIDTH"]).flatMap { Int64($0) })
                if let size = attrs["RESOLUTION"]?.lowercased().split(separator: "x"), size.count == 2 {
                    variant.width = Int(size[0]); variant.height = Int(size[1])
                }
                if best == nil || (variant.height ?? 0, variant.bandwidth ?? 0) > (best?.height ?? 0, best?.bandwidth ?? 0) {
                    best = variant
                }
            }
        }
        return best
    }

    /// Total playing time of a media playlist (the sum of its #EXTINF pieces).
    static func totalDuration(ofMedia text: String) -> Double? {
        var total = 0.0
        for rawLine in text.split(whereSeparator: \.isNewline) where rawLine.hasPrefix("#EXTINF:") {
            let value = rawLine.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init) ?? ""
            total += Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return total > 0 ? total : nil
    }

    /// Splits `BANDWIDTH=800000,RESOLUTION=1280x720,CODECS="a,b"` into a dictionary, respecting quotes.
    static func attributes(of text: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = "", value = "", inKey = true, inQuotes = false
        func flush() { if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }; key = ""; value = ""; inKey = true }
        for character in text {
            if character == "\"" { inQuotes.toggle() }
            else if character == "=", inKey, !inQuotes { inKey = false }
            else if character == ",", !inQuotes { flush() }
            else if inKey { key.append(character) } else { value.append(character) }
        }
        flush()
        return result
    }

    /// Reads the playlist (and the best version's playlist, for its length). Nil when it can't be read.
    static func summary(of url: URL, headers: [String: String], fetch: ((URL) async -> String?)? = nil) async -> StreamSummary? {
        let load = fetch ?? { await download($0, headers: headers) }
        guard let text = await load(url), text.contains("#EXTM3U") else { return nil }
        guard let best = bestVariant(inMaster: text, base: url) else {
            return StreamSummary(duration: totalDuration(ofMedia: text))
        }
        var summary = StreamSummary(width: best.width, height: best.height, bandwidth: best.bandwidth)
        if let mediaText = await load(best.url) { summary.duration = totalDuration(ofMedia: mediaText) }
        return summary
    }

    private static func download(_ url: URL, headers: [String: String]) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count < 8_000_000 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
