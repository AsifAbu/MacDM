import Foundation
import CryptoKit

/// Keeps yt-dlp current.
///
/// Video sites change often and yt-dlp is updated every few weeks to keep up, so the
/// copy shipped inside the app goes stale. This checks GitHub for a newer official
/// release and, if there is one, installs it into Application Support/MacDM/bin
/// (MediaTools prefers that copy over the bundled one).
///
/// It uses yt-dlp's multi-file build (yt-dlp_macos.zip). The single-file build unpacks itself
/// on every run, which made each video lookup take about 9 seconds; the multi-file build
/// starts in a quarter of a second.
///
/// A downloaded file is only used after three checks: it comes from github.com over
/// https, its SHA-256 matches the release's published checksums, and it actually runs
/// and reports the expected version. Anything else leaves the current copy untouched.
final class YtDlpUpdater {
    enum Outcome: Equatable {
        case upToDate(version: String)
        case updated(from: String?, to: String)
        case failed(String)
    }

    struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static let shared = YtDlpUpdater()
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest")!
    static let assetName = "yt-dlp_macos.zip"
    static let checksumsName = "SHA2-256SUMS"

    static let autoUpdateKey = "autoUpdateYtDlp"
    static let lastCheckKey = "ytDlpLastCheck"

    private let session: URLSession
    private let releaseURL: URL
    private let installDirectory: URL
    private let currentTool: () -> URL?
    private let bundledTool: () -> URL?

    /// The parameters exist so tests can run the whole flow without the network.
    init(session: URLSession = .shared,
         releaseURL: URL = YtDlpUpdater.latestReleaseURL,
         installDirectory: URL = MediaTools.updatedDirectory,
         currentTool: @escaping () -> URL? = { MediaTools.find("yt-dlp") },
         bundledTool: @escaping () -> URL? = { MediaTools.find("yt-dlp", in: [MediaTools.bundledYtDlpDirectory.path]) }) {
        self.session = session
        self.releaseURL = releaseURL
        self.installDirectory = installDirectory
        self.currentTool = currentTool
        self.bundledTool = bundledTool
    }

    private var installedTool: URL { installDirectory.appendingPathComponent("yt-dlp") }

    // MARK: - Scheduling

    /// Called at launch: checks at most once a day, and only if the user hasn't turned it off.
    static func checkIfDue(defaults: UserDefaults = .standard, now: Date = Date(),
                           perform: () -> Void = {
                               Task.detached(priority: .utility) { _ = await YtDlpUpdater.shared.checkAndUpdate() }
                           }) {
        guard defaults.object(forKey: autoUpdateKey) as? Bool ?? true else { return }
        if let last = defaults.object(forKey: lastCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 3600 { return }
        defaults.set(now, forKey: lastCheckKey)
        perform()
    }

    // MARK: - Update

    func checkAndUpdate() async -> Outcome {
        do {
            removeOutdatedOrBrokenUpdate()

            let release = try await fetchLatestRelease()
            let current = currentTool().flatMap { Self.version(of: $0) }
            if let current, !Self.isNewer(release.version, than: current) {
                return .upToDate(version: current)
            }

            let checksums = try await fetchText(release.checksumsURL)
            guard let expected = Self.checksum(for: Self.assetName, in: checksums) else {
                throw UpdateError("The release has no checksum for \(Self.assetName).")
            }

            let (downloaded, response) = try await session.download(from: release.assetURL)
            defer { try? FileManager.default.removeItem(at: downloaded) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw UpdateError("Could not download the new yt-dlp.")
            }
            guard try Self.sha256(of: downloaded) == expected else {
                throw UpdateError("The downloaded yt-dlp did not match its checksum, so it was not installed.")
            }

            // Unpack next to the install folder, test it there, then swap the whole folder in.
            let parent = installDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let staging = parent.appendingPathComponent("bin.new", isDirectory: true)
            try? FileManager.default.removeItem(at: staging)
            defer { try? FileManager.default.removeItem(at: staging) }

            try Self.unzip(downloaded, to: staging)
            let unpacked = staging.appendingPathComponent("yt-dlp_macos")
            let program = staging.appendingPathComponent("yt-dlp")
            guard FileManager.default.fileExists(atPath: unpacked.path) else {
                throw UpdateError("The downloaded yt-dlp archive was not what was expected, so it was not installed.")
            }
            try FileManager.default.moveItem(at: unpacked, to: program)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: program.path)
            guard Self.version(of: program) == release.version else {
                throw UpdateError("The downloaded yt-dlp did not run correctly, so it was not installed.")
            }

            _ = try FileManager.default.replaceItemAt(installDirectory, withItemAt: staging)
            return .updated(from: current, to: release.version)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// If the app was updated and now ships a yt-dlp at least as new as the downloaded one
    /// (or the downloaded one no longer runs), drop the downloaded copy.
    private func removeOutdatedOrBrokenUpdate() {
        guard FileManager.default.isExecutableFile(atPath: installedTool.path) else { return }
        guard let installedVersion = Self.version(of: installedTool) else {
            try? FileManager.default.removeItem(at: installDirectory)
            return
        }
        if let bundled = bundledTool(), let bundledVersion = Self.version(of: bundled),
           !Self.isNewer(installedVersion, than: bundledVersion) {
            try? FileManager.default.removeItem(at: installDirectory)
        }
    }

    // MARK: - GitHub release

    private struct Release {
        let version: String
        let assetURL: URL
        let checksumsURL: URL
    }

    private func fetchLatestRelease() async throws -> Release {
        var request = URLRequest(url: releaseURL, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MacDM", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw UpdateError("Could not read the latest yt-dlp release from GitHub.")
        }

        func assetURL(_ name: String) throws -> URL {
            guard let asset = assets.first(where: { $0["name"] as? String == name }),
                  let string = asset["browser_download_url"] as? String,
                  let url = URL(string: string), Self.isTrustedDownloadURL(url) else {
                throw UpdateError("The latest release has no usable \(name).")
            }
            return url
        }
        return Release(version: tag, assetURL: try assetURL(Self.assetName), checksumsURL: try assetURL(Self.checksumsName))
    }

    private func fetchText(_ url: URL) async throws -> String {
        let (data, response) = try await session.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Could not download \(url.lastPathComponent).")
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Helpers (internal so tests can reach them)

    /// Only https downloads from GitHub are accepted.
    static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// Compares dotted version numbers such as "2026.08.19" and "2026.08.19.232103".
    static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = latest.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Finds the SHA-256 for `file` in a "SHA2-256SUMS" style listing ("<hash>  <name>").
    static func checksum(for file: String, in listing: String) -> String? {
        for line in listing.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }
            let name = parts[1].hasPrefix("*") ? String(parts[1].dropFirst()) : String(parts[1])
            let hash = parts[0].lowercased()
            if name == file, hash.count == 64, hash.allSatisfy(\.isHexDigit) { return hash }
        }
        return nil
    }

    /// Unpacks a zip with the system's `ditto` (the same tool Finder uses).
    static func unzip(_ archive: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError("Could not unpack the downloaded yt-dlp.") }
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Runs `tool --version` (30 second limit) and returns the version, or nil if it
    /// fails or prints something that doesn't look like a version.
    static func version(of tool: URL) -> String? {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["--version"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        guard process.terminationStatus == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = text.first, first.isNumber, text.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        return text
    }
}
