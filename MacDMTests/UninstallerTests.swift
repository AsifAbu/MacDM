import Foundation
import Testing
@testable import MacDM

/// "Uninstall MacDM…": what it removes, and, just as important, what it must never touch.
@Suite("Uninstaller")
struct UninstallerTests {
    private let bundleID = "com.example.MacDM"

    /// A pretend user Library folder, plus a pretend Downloads folder holding a downloaded file.
    private struct FakeHome {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMHome-\(UUID().uuidString)", isDirectory: true)
        var library: URL { root.appendingPathComponent("Library") }
        var downloadedFile: URL { root.appendingPathComponent("Downloads/MacDM/Video/movie.mp4") }
        var otherAppData: URL { library.appendingPathComponent("Application Support/SomeOtherApp/data.json") }

        init(bundleID: String) throws {
            let fm = FileManager.default
            for path in Uninstaller.dataPaths(library: library, bundleID: bundleID) {
                if path.pathExtension.isEmpty {
                    try fm.createDirectory(at: path, withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: path.appendingPathComponent("file.txt"))
                } else {
                    try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: path)
                }
            }
            for file in [downloadedFile, otherAppData] {
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("keep me".utf8).write(to: file)
            }
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test("all of MacDM's data lives inside the user's Library folder")
    func pathsAreInsideLibrary() {
        let library = URL(fileURLWithPath: "/Users/someone/Library")
        let paths = Uninstaller.dataPaths(library: library, bundleID: bundleID)
        #expect(paths.count >= 5)
        for path in paths { #expect(path.path.hasPrefix("/Users/someone/Library/"), "\(path.path)") }
    }

    @Test("history, settings and caches are removed")
    func removesData() throws {
        let home = try FakeHome(bundleID: bundleID); defer { home.cleanUp() }
        let paths = Uninstaller.dataPaths(library: home.library, bundleID: bundleID)
        #expect(Uninstaller.removeData(at: paths).isEmpty)
        for path in paths { #expect(!FileManager.default.fileExists(atPath: path.path), "\(path.lastPathComponent) still exists") }
    }

    @Test("downloaded files are never deleted")
    func keepsDownloads() throws {
        let home = try FakeHome(bundleID: bundleID); defer { home.cleanUp() }
        Uninstaller.removeData(at: Uninstaller.dataPaths(library: home.library, bundleID: bundleID))
        #expect(FileManager.default.fileExists(atPath: home.downloadedFile.path))
    }

    @Test("other apps' data is never touched")
    func keepsOtherApps() throws {
        let home = try FakeHome(bundleID: bundleID); defer { home.cleanUp() }
        Uninstaller.removeData(at: Uninstaller.dataPaths(library: home.library, bundleID: bundleID))
        #expect(FileManager.default.fileExists(atPath: home.otherAppData.path))
    }

    @Test("running it twice, or on a Mac with no MacDM data, is harmless")
    func idempotent() throws {
        let home = try FakeHome(bundleID: bundleID); defer { home.cleanUp() }
        let paths = Uninstaller.dataPaths(library: home.library, bundleID: bundleID)
        Uninstaller.removeData(at: paths)
        #expect(Uninstaller.removeData(at: paths).isEmpty)
    }

    // MARK: The clean-up script that runs after MacDM quits

    @Test("the script waits for MacDM to exit before removing anything")
    func scriptWaitsFirst() {
        let script = Uninstaller.cleanupScript(appPID: 4242, paths: [URL(fileURLWithPath: "/tmp/a")], bundleID: bundleID)
        let wait = script.range(of: "kill -0 4242")
        let remove = script.range(of: "rm -rf")
        #expect(wait != nil && remove != nil)
        if let wait, let remove { #expect(wait.lowerBound < remove.lowerBound) }
    }

    @Test("paths with spaces and quotes are quoted safely")
    func scriptQuoting() {
        let script = Uninstaller.cleanupScript(appPID: 1, paths: [URL(fileURLWithPath: "/tmp/My Data/it's here")], bundleID: bundleID)
        #expect(script.contains("'/tmp/My Data/it'\\''s here'"))
    }

    @Test("the script only removes the paths it was given, and resets the settings")
    func scriptScope() {
        let paths = [URL(fileURLWithPath: "/tmp/one"), URL(fileURLWithPath: "/tmp/two")]
        let script = Uninstaller.cleanupScript(appPID: 1, paths: paths, bundleID: bundleID)
        #expect(script.components(separatedBy: "rm -rf").count - 1 == 2)
        #expect(script.contains("defaults delete '\(bundleID)'"))
        #expect(!script.contains("rm -rf /\n"))
    }

    @Test("a script with no paths (keep my data) removes nothing")
    func scriptKeepsDataWhenAsked() {
        let script = Uninstaller.cleanupScript(appPID: 1, paths: [], bundleID: bundleID)
        #expect(!script.contains("rm -rf"))
    }

    @Test("run for real: nothing is removed while MacDM is still running, everything after it quits")
    func scriptRunsInOrder() async throws {
        let box = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMScript-\(UUID().uuidString)")
        let data = box.appendingPathComponent("data"); let keep = box.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: data.appendingPathComponent("history.json"))
        try Data("downloaded file".utf8).write(to: keep)
        defer { try? FileManager.default.removeItem(at: box) }

        // A stand-in for the MacDM app: a process that quits after 2 seconds.
        let app = Process(); app.executableURL = URL(fileURLWithPath: "/bin/sleep"); app.arguments = ["2"]
        try app.run()

        let helper = Process(); helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", Uninstaller.cleanupScript(appPID: app.processIdentifier, paths: [data], bundleID: bundleID, resetPreferences: false)]
        try helper.run()

        try await Task.sleep(nanoseconds: 800_000_000)
        #expect(FileManager.default.fileExists(atPath: data.path), "removed while the app was still running")

        app.waitUntilExit(); helper.waitUntilExit()
        #expect(!FileManager.default.fileExists(atPath: data.path), "not removed after the app quit")
        #expect(FileManager.default.fileExists(atPath: keep.path), "removed something it was not asked to")
    }

    @Test("uninstall is only offered for the installed copy")
    func onlyInstalledCopy() {
        // The test host runs from a build folder, not /Applications.
        #expect(!Uninstaller.canUninstall)
    }
}
