import Foundation
import Testing
@testable import MacDM

/// The stable copy of the Chrome extension that survives app updates and ejected disk images.
@Suite("Chrome extension copy")
struct ChromeExtensionInstallerTests {
    private func folder(_ name: String, files: [String: String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMExt-\(UUID().uuidString)-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for (file, text) in files { try Data(text.utf8).write(to: url.appendingPathComponent(file)) }
        return url
    }
    private func text(_ folder: URL, _ file: String) -> String? {
        (try? Data(contentsOf: folder.appendingPathComponent(file))).map { String(decoding: $0, as: UTF8.self) }
    }
    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    private let files = ["manifest.json": "{}", "background.js": "bg", "content.js": "ct", "popup.html": "<html>"]

    @Test("the first install copies every file")
    func firstInstall() throws {
        let source = try folder("src", files: files)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMExt-\(UUID().uuidString)-dest")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        #expect(try ChromeExtensionInstaller.sync(from: source, to: dest) == true)
        #expect(names(dest) == names(source))
        #expect(text(dest, "popup.html") == "<html>")
    }

    @Test("running it again changes nothing")
    func idempotent() throws {
        let source = try folder("src", files: files)
        let dest = try folder("dest", files: [:])
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }

        try ChromeExtensionInstaller.sync(from: source, to: dest)
        #expect(try ChromeExtensionInstaller.sync(from: source, to: dest) == false)
    }

    @Test("an updated file is replaced, in the same folder")
    func updatesInPlace() throws {
        let source = try folder("src", files: files)
        let dest = try folder("dest", files: [:])
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        try ChromeExtensionInstaller.sync(from: source, to: dest)

        try Data("new background".utf8).write(to: source.appendingPathComponent("background.js"))
        #expect(try ChromeExtensionInstaller.sync(from: source, to: dest) == true)
        #expect(text(dest, "background.js") == "new background")
        #expect(FileManager.default.fileExists(atPath: dest.path), "the folder Chrome points at must stay")
    }

    @Test("files that are no longer part of the extension are removed")
    func removesStale() throws {
        let source = try folder("src", files: files)
        let dest = try folder("dest", files: ["old-file.js": "x"])
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: dest) }
        try ChromeExtensionInstaller.sync(from: source, to: dest)
        #expect(!names(dest).contains("old-file.js"))
    }

    @Test("the copy lives in Application Support, not inside the app or a disk image")
    func stableLocation() {
        let path = ChromeExtensionInstaller.installedFolder.path
        #expect(path.hasSuffix("Application Support/MacDM/ChromeExtension"))
        #expect(!path.contains(".app/"))
        #expect(!path.hasPrefix("/Volumes/"))
    }

    @Test("the shipped extension has the files Chrome needs, including the popup")
    func projectExtensionIsComplete() throws {
        // Walk up from this test file to the project's ChromeExtension folder.
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var found: URL?
        for _ in 0..<4 {
            let candidate = dir.appendingPathComponent("ChromeExtension")
            if FileManager.default.fileExists(atPath: candidate.path) { found = candidate; break }
            dir = dir.deletingLastPathComponent()
        }
        let source = try #require(found, "ChromeExtension folder not found")
        for file in ["manifest.json", "background.js", "content.js", "popup.html"] {
            #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent(file).path), "\(file) is missing")
        }
    }
}
