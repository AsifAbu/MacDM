import Foundation
import Testing
@testable import MacDM

/// Queue, pause, cancel and relaunch behavior of the download manager.
/// These include regression tests for the "cancel doesn't work / download restarts
/// after reopening" bugs.
@MainActor
@Suite("DownloadManager", .serialized)
struct DownloadManagerTests {
    private let unreachable = URL(string: "http://127.0.0.1:9/never.bin")!

    // MARK: Persistence

    @Test("tasks are saved and reloaded on the next launch")
    func persistsAndReloads() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.addDownload(url: unreachable, suggestedName: "keep.zip", startImmediately: false)

        let reloaded = env.relaunch()
        #expect(reloaded.tasks.count == 1)
        #expect(reloaded.tasks.first?.fileName == "keep.zip")
    }

    @Test("statuses after relaunch: running resumes, everything else stays")
    func relaunchStatuses() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        let expectations: [(DownloadStatus, DownloadStatus)] = [
            (.downloading, .queued), (.queued, .queued), (.paused, .paused),
            (.cancelled, .cancelled), (.failed, .failed), (.completed, .completed)
        ]
        for (index, pair) in expectations.enumerated() {
            let task = env.manager.addDownload(url: unreachable, suggestedName: "f\(index).bin", startImmediately: false)
            task.status = pair.0
        }
        env.manager.persistTasks()

        let reloaded = env.relaunch()
        // Tasks are stored newest first, so compare in reverse insertion order.
        let loaded = reloaded.tasks.map(\.status)
        #expect(loaded == expectations.reversed().map(\.1))
    }

    // MARK: Cancel / pause of tasks that have no engine yet

    @Test("cancelling a queued task keeps it cancelled and the queue never starts it")
    func cancelQueuedTask() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0 // hold everything in the queue
        let task = env.manager.addDownload(url: unreachable, suggestedName: "q.bin")
        #expect(task.status == .queued)

        env.manager.cancel(task)
        #expect(task.status == .cancelled)
        #expect(env.persistedStatuses() == ["cancelled"])

        env.manager.maxConcurrentDownloads = 3
        env.manager.processQueue()
        #expect(task.status == .cancelled)
        #expect(env.relaunch().tasks.first?.status == .cancelled)
    }

    @Test("pausing a queued task keeps it paused and the queue never starts it")
    func pauseQueuedTask() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let task = env.manager.addDownload(url: unreachable, suggestedName: "q.bin")

        env.manager.pause(task)
        env.manager.maxConcurrentDownloads = 3
        env.manager.processQueue()
        #expect(task.status == .paused)
        #expect(env.persistedStatuses() == ["paused"])
    }

    @Test("a paused task is not restarted by the next launch")
    func pausedStaysPausedAfterRelaunch() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let task = env.manager.addDownload(url: unreachable, suggestedName: "p.bin")
        env.manager.pause(task)

        let reloaded = env.relaunch()
        reloaded.processQueue() // what the app does at launch
        #expect(reloaded.tasks.first?.status == .paused)
    }

    // MARK: Cancel of a running download

    @Test("cancel is saved as cancelled immediately, not as downloading")
    func cancelPersistsImmediately() async {
        let server = try! TestHTTPServer(.init(bodySize: 4_000_000, chunkSize: 16 * 1024, chunkDelay: 0.05))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "slow.bin")
        #expect(await waitUntil { task.downloadedBytes > 0 })

        env.manager.cancel(task)
        // Read straight away: this is the moment the old code saved "downloading".
        #expect(env.persistedStatuses() == ["cancelled"])
        #expect(task.status == .cancelled)
        #expect(env.relaunch().tasks.first?.status == .cancelled)
    }

    @Test("cancel during the server probe is not undone when the probe replies")
    func cancelDuringProbe() async {
        let server = try! TestHTTPServer(.init(bodySize: 2_000_000, headDelay: 1.0))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "probe.bin")
        #expect(task.status == .downloading)
        env.manager.cancel(task)

        // Let the delayed HEAD answer arrive; nothing may restart.
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(task.status == .cancelled)
        #expect(server.getCount == 0)
        #expect(!FileManager.default.fileExists(atPath: task.partFileURL.path))
    }

    @Test("cancel removes the partial file")
    func cancelRemovesPartFile() async {
        let server = try! TestHTTPServer(.init(bodySize: 4_000_000, chunkSize: 16 * 1024, chunkDelay: 0.05))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "partial.bin")
        #expect(await waitUntil { task.downloadedBytes > 0 })
        env.manager.cancel(task)
        #expect(!FileManager.default.fileExists(atPath: task.partFileURL.path))
        #expect(!FileManager.default.fileExists(atPath: task.finalDestinationURL.path))
    }

    // MARK: Queue

    @Test("only maxConcurrentDownloads run at once; the rest wait")
    func concurrencyLimit() async {
        let server = try! TestHTTPServer(.init(bodySize: 4_000_000, chunkSize: 16 * 1024, chunkDelay: 0.05))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 1

        let first = env.manager.addDownload(url: server.url, suggestedName: "one.bin")
        let second = env.manager.addDownload(url: server.url, suggestedName: "two.bin")
        #expect(await waitUntil { first.downloadedBytes > 0 })

        let running = env.manager.tasks.filter { $0.status == .downloading }
        #expect(running.count == 1)
        #expect(second.status == .queued)

        env.manager.cancel(first)
        env.manager.cancel(second)
    }

    @Test("cancelling the running download lets the next queued one start")
    func nextStartsAfterCancel() async {
        let server = try! TestHTTPServer(.init(bodySize: 4_000_000, chunkSize: 16 * 1024, chunkDelay: 0.05))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 1

        let first = env.manager.addDownload(url: server.url, suggestedName: "one.bin")
        let second = env.manager.addDownload(url: server.url, suggestedName: "two.bin")
        #expect(await waitUntil { first.downloadedBytes > 0 })

        env.manager.cancel(first)
        #expect(await waitUntil { second.status == .downloading })
        env.manager.cancel(second)
    }

    @Test("higher priority starts first")
    func priorityOrder() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let low = env.manager.addDownload(url: unreachable, suggestedName: "low.bin")
        let high = env.manager.addDownload(url: unreachable, suggestedName: "high.bin")
        env.manager.setPriority(high, priority: 5)

        env.manager.maxConcurrentDownloads = 1
        env.manager.processQueue()
        #expect(high.status == .downloading)
        #expect(low.status == .queued)
        env.manager.cancel(high)
        env.manager.cancel(low)
    }

    // MARK: Remove / history

    @Test("removing a task deletes it from the list and from disk")
    func removeTask() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let task = env.manager.addDownload(url: unreachable, suggestedName: "gone.bin")
        env.manager.remove(task)
        #expect(env.manager.tasks.isEmpty)
        #expect(env.relaunch().tasks.isEmpty)
    }

    @Test("search matches file name and URL, clearCompleted keeps the rest")
    func searchAndClear() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        let done = env.manager.addDownload(url: URL(string: "https://a.example/report.pdf")!, suggestedName: "report.pdf")
        env.manager.addDownload(url: URL(string: "https://b.example/movie.mp4")!, suggestedName: "movie.mp4")
        done.status = .completed

        #expect(env.manager.searchTasks("REPORT").count == 1)
        #expect(env.manager.searchTasks("b.example").count == 1)
        #expect(env.manager.searchTasks("").count == 2)

        env.manager.clearCompleted()
        #expect(env.manager.tasks.map(\.fileName) == ["movie.mp4"])
    }
}

/// End-to-end downloads against the in-process test server.
@MainActor
@Suite("Download engine", .serialized)
struct DownloadEngineTests {
    @Test("a large file downloads in segments and matches byte for byte")
    func segmentedDownload() async throws {
        let server = try TestHTTPServer(.init(bodySize: 3_000_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "big.bin")
        #expect(await waitUntil { task.status == .completed })

        let data = try Data(contentsOf: task.finalDestinationURL)
        #expect(data == server.expectedBody)
        #expect(task.segments.count > 1)
        #expect(!FileManager.default.fileExists(atPath: task.partFileURL.path))
    }

    /// Segments write into one shared file from different threads. If a seek and the
    /// write that follows it can interleave, bytes land at the wrong offset and the
    /// file is silently corrupted. Repeating makes such a race show up reliably.
    @Test("concurrent segments never corrupt the file", arguments: Array(1...6))
    func segmentsDoNotInterleave(round: Int) async throws {
        let server = try TestHTTPServer(.init(bodySize: 6_000_000, chunkSize: 8 * 1024))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "race-\(round).bin")
        #expect(await waitUntil(timeout: 30) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }

    @Test("never more connections at once than the setting allows, and the file is still exact")
    func connectionLimit() async throws {
        let server = try TestHTTPServer(.init(bodySize: 12_000_000, chunkSize: 32 * 1024, chunkDelay: 0.003))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.connectionsPerDownload = 3

        let task = env.manager.addDownload(url: server.url, suggestedName: "limited.bin")
        #expect(await waitUntil(timeout: 60) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
        #expect(server.maxConcurrentGets <= 3, "\(server.maxConcurrentGets) connections were open at once")
        #expect(server.maxConcurrentGets >= 2, "it should really download in parallel")
        #expect(task.segments.count > 3, "more pieces than connections, so a quick connection can take more work")
    }

    @Test("a single connection still downloads the whole file correctly")
    func oneConnection() async throws {
        let server = try TestHTTPServer(.init(bodySize: 4_000_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.connectionsPerDownload = 1

        let task = env.manager.addDownload(url: server.url, suggestedName: "one.bin")
        #expect(await waitUntil(timeout: 60) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
        #expect(server.maxConcurrentGets == 1)
    }

    @Test("many connections on a mid-sized file stay exact (stress)", arguments: Array(1...4))
    func manyConnections(round: Int) async throws {
        let server = try TestHTTPServer(.init(bodySize: 9_000_000, chunkSize: 8 * 1024))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.connectionsPerDownload = 32

        let task = env.manager.addDownload(url: server.url, suggestedName: "many-\(round).bin")
        #expect(await waitUntil(timeout: 60) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }

    @Test("pausing and resuming works with many pieces")
    func pauseResumeManyPieces() async throws {
        let server = try TestHTTPServer(.init(bodySize: 8_000_000, chunkSize: 16 * 1024, chunkDelay: 0.01))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.connectionsPerDownload = 4

        let task = env.manager.addDownload(url: server.url, suggestedName: "pieces.bin")
        #expect(await waitUntil { task.downloadedBytes > 300_000 })
        env.manager.pause(task)
        env.manager.start(task)
        #expect(await waitUntil(timeout: 90) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }

    @Test("the connection setting is remembered, stays between 1 and 32, and applies after a relaunch")
    func connectionSetting() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        #expect(env.manager.connectionsPerDownload == 8, "default")
        env.manager.connectionsPerDownload = 24
        #expect(env.relaunch().connectionsPerDownload == 24)
        env.manager.connectionsPerDownload = 99
        #expect(env.manager.connectionsPerDownload == 32)
        env.manager.connectionsPerDownload = 0
        #expect(env.manager.connectionsPerDownload == 1)
    }

    @Test("pieces: one for small files or no resume support, several per connection for big files")
    func pieceCounts() {
        func pieces(_ size: Int64, _ connections: Int, ranges: Bool = true) -> Int {
            DownloadEngine.pieceCount(fileSize: size, connections: connections, acceptsRanges: ranges)
        }
        #expect(pieces(500_000, 16) == 1)
        #expect(pieces(50_000_000, 16, ranges: false) == 1)
        #expect(pieces(3_000_000, 16) == 5, "pieces are at least 512 KB")
        #expect(pieces(200_000_000, 16) == 48, "three pieces per connection")
        #expect(pieces(200_000_000, 4) == 12)
        #expect(pieces(200_000_000, 1) == 3)
        #expect(pieces(200_000_000, 32) == 96)
    }

    @Test("a server without range support downloads as a single piece")
    func noRangeSupport() async throws {
        let server = try TestHTTPServer(.init(bodySize: 3_000_000, acceptRanges: false))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "single.bin")
        #expect(await waitUntil { task.status == .completed })
        #expect(task.segments.count == 1)
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }

    @Test("the browser's Referer and cookie are sent on every request, so protected servers accept the download")
    func sendsBrowserHeaders() async throws {
        let server = try TestHTTPServer(.init(bodySize: 3_000_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let headers = ["Referer": "https://site.example/watch", "Cookie": "session=abc123", "User-Agent": "TestBrowser/1.0"]
        let task = env.manager.addDownload(url: server.url, suggestedName: "protected.bin", headers: headers)
        #expect(await waitUntil { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)

        let seen = server.requests
        #expect(seen.contains { $0.method == "HEAD" }, "the size check")
        #expect(seen.contains { $0.method == "GET" }, "the download")
        for request in seen {
            #expect(request.headers["referer"] == "https://site.example/watch", "\(request.method) lacked the Referer")
            #expect(request.headers["cookie"] == "session=abc123", "\(request.method) lacked the cookie")
            #expect(request.headers["user-agent"] == "TestBrowser/1.0", "\(request.method) lacked the User-Agent")
        }
    }

    @Test("without browser headers nothing extra is sent")
    func noHeadersByDefault() async throws {
        let server = try TestHTTPServer(.init(bodySize: 20_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }
        let task = env.manager.addDownload(url: server.url, suggestedName: "plain.bin")
        #expect(await waitUntil { task.status == .completed })
        for request in server.requests {
            #expect(request.headers["cookie"] == nil)
            #expect(request.headers["referer"] == nil)
        }
    }

    @Test("a download's headers survive quitting and reopening, so a resumed download still works")
    func headersSurviveRelaunch() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        env.manager.maxConcurrentDownloads = 0
        env.manager.addDownload(url: URL(string: "http://127.0.0.1:9/x.bin")!, suggestedName: "x.bin",
                                headers: ["Referer": "https://site.example/", "Cookie": "a=1"])
        #expect(env.relaunch().tasks.first?.requestHeaders == ["Referer": "https://site.example/", "Cookie": "a=1"])
    }

    @Test("a small file completes")
    func smallFile() async throws {
        let server = try TestHTTPServer(.init(bodySize: 20_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "small.bin")
        #expect(await waitUntil { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }

    @Test("files are sorted into category folders")
    func categoryFolder() async throws {
        let server = try TestHTTPServer(.init(bodySize: 20_000))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "clip.mp4")
        #expect(task.destinationFolder.lastPathComponent == "Video")
        #expect(await waitUntil { task.status == .completed })
    }

    @Test("pause then resume finishes with the correct bytes")
    func pauseAndResume() async throws {
        let server = try TestHTTPServer(.init(bodySize: 3_000_000, chunkSize: 16 * 1024, chunkDelay: 0.02))
        defer { server.stop() }
        let env = IsolatedManager()
        defer { env.cleanUp() }

        let task = env.manager.addDownload(url: server.url, suggestedName: "resume.bin")
        #expect(await waitUntil { task.downloadedBytes > 200_000 })

        env.manager.pause(task)
        #expect(task.status == .paused)
        #expect(env.persistedStatuses() == ["paused"])

        env.manager.start(task)
        #expect(await waitUntil(timeout: 30) { task.status == .completed })
        #expect(try Data(contentsOf: task.finalDestinationURL) == server.expectedBody)
    }
}
