import Foundation
import Testing
@testable import MacDM

/// The ✕ button on a download row, and how the download location is shown in Settings.
@MainActor
@Suite("History and download location")
struct HistoryAndLocationTests {
    private let unreachable = URL(string: "http://127.0.0.1:9/never.bin")!

    private func task(_ env: IsolatedManager, status: DownloadStatus) -> DownloadTask {
        env.manager.maxConcurrentDownloads = 0   // keep everything in the queue, nothing downloads
        let task = env.manager.addDownload(url: unreachable, suggestedName: "\(status.rawValue).zip")
        task.status = status
        return task
    }

    // MARK: ✕ on a row

    @Test("✕ removes a completed download from the history")
    func removesCompleted() {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let done = task(env, status: .completed)
        env.manager.cancelOrRemove(done)
        #expect(env.manager.tasks.isEmpty)
        #expect(env.relaunch().tasks.isEmpty, "the removal must be saved")
    }

    @Test("✕ removes failed and cancelled entries too", arguments: [DownloadStatus.failed, .cancelled])
    func removesFinishedStates(status: DownloadStatus) {
        let env = IsolatedManager(); defer { env.cleanUp() }
        env.manager.cancelOrRemove(task(env, status: status))
        #expect(env.manager.tasks.isEmpty)
    }

    @Test("✕ on an active download cancels it and keeps the entry; a second ✕ removes it")
    func cancelsThenRemoves() {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let active = task(env, status: .queued)
        env.manager.cancelOrRemove(active)
        #expect(active.status == .cancelled)
        #expect(env.manager.tasks.count == 1)

        env.manager.cancelOrRemove(active)
        #expect(env.manager.tasks.isEmpty)
    }

    @Test("✕ on a paused download cancels it")
    func cancelsPaused() {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let paused = task(env, status: .paused)
        env.manager.cancelOrRemove(paused)
        #expect(paused.status == .cancelled)
    }

    @Test("removing a finished download from the list keeps the file on disk")
    func keepsDownloadedFile() throws {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let done = task(env, status: .completed)
        try FileManager.default.createDirectory(at: done.destinationFolder, withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: done.finalDestinationURL)

        env.manager.cancelOrRemove(done)
        #expect(FileManager.default.fileExists(atPath: done.finalDestinationURL.path))
    }

    @Test("removing one entry leaves the others alone")
    func onlyThatEntry() {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let a = task(env, status: .completed)
        let b = task(env, status: .completed)
        env.manager.cancelOrRemove(a)
        #expect(env.manager.tasks.map(\.id) == [b.id])
    }

    // MARK: Download location label

    @Test("the location is shown in short form with ~ for the home folder")
    func displayPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let shown = DownloadManager.displayPath(home.appendingPathComponent("Downloads/MacDM", isDirectory: true))
        #expect(shown == "~/Downloads/MacDM")
    }

    @Test("a path outside the home folder is shown in full")
    func displayPathOutsideHome() {
        #expect(DownloadManager.displayPath(URL(fileURLWithPath: "/Volumes/Backup/Films", isDirectory: true)) == "/Volumes/Backup/Films")
    }

    @Test("a fresh install shows the default location; Browse picks a new one that sticks")
    func initialThenCustom() {
        let env = IsolatedManager(); defer { env.cleanUp() }
        let initial = env.manager.defaultDownloadFolder
        #expect(!DownloadManager.displayPath(initial).isEmpty)

        let custom = FileManager.default.temporaryDirectory.appendingPathComponent("MacDM-browse-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: custom) }

        env.manager.defaultDownloadFolder = custom           // what the Browse… button does
        #expect(env.manager.defaultDownloadFolder.standardizedFileURL.path == custom.standardizedFileURL.path)
        #expect(env.relaunch().defaultDownloadFolder.standardizedFileURL.path == custom.standardizedFileURL.path)
    }
}
