import Foundation
import Testing
@testable import MacDM

// MARK: - Task model

@Suite("DownloadTask model")
struct DownloadTaskTests {
    private func makeTask(status: DownloadStatus) -> DownloadTask {
        let task = DownloadTask(url: URL(string: "https://example.com/a.zip")!,
                                fileName: "a.zip",
                                destinationFolder: URL(fileURLWithPath: "/tmp/macdm-test"))
        task.status = status
        return task
    }

    private func roundTrip(_ task: DownloadTask) throws -> DownloadTask {
        try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
    }

    @Test("fields survive a save and load")
    func roundTripKeepsFields() throws {
        let task = makeTask(status: .paused)
        task.totalBytes = 1000
        task.downloadedBytes = 400
        task.priority = 2
        task.mediaFormat = "b/bv*+ba"
        task.mediaReferer = "https://example.com/page"
        task.segments = [DownloadSegment(index: 0, startByte: 0, endByte: 999, downloadedBytes: 400)]

        let loaded = try roundTrip(task)
        #expect(loaded.id == task.id)
        #expect(loaded.url == task.url)
        #expect(loaded.fileName == "a.zip")
        #expect(loaded.totalBytes == 1000)
        #expect(loaded.downloadedBytes == 400)
        #expect(loaded.priority == 2)
        #expect(loaded.mediaFormat == "b/bv*+ba")
        #expect(loaded.mediaReferer == "https://example.com/page")
        #expect(loaded.segments.first?.downloadedBytes == 400)
    }

    @Test("a download interrupted by quitting goes back to the queue")
    func downloadingBecomesQueued() throws {
        #expect(try roundTrip(makeTask(status: .downloading)).status == .queued)
    }

    @Test("paused, failed, cancelled and completed stay as they were",
          arguments: [DownloadStatus.paused, .failed, .cancelled, .completed, .queued])
    func otherStatusesAreKept(status: DownloadStatus) throws {
        #expect(try roundTrip(makeTask(status: status)).status == status)
    }
}

// MARK: - Categories

@Suite("Download categories")
struct DownloadCategoryTests {
    @Test("file extension picks the category", arguments: [
        ("a.zip", DownloadCategory.compressed), ("a.7z", .compressed),
        ("a.pdf", .documents), ("a.xlsx", .documents),
        ("a.mp3", .music), ("a.m4a", .music),
        ("a.mp4", .video), ("a.MKV", .video), ("a.m3u8", .video),
        ("a.dmg", .programs), ("a.pkg", .programs),
        ("a.unknown", .other), ("noextension", .other)
    ])
    func categorize(name: String, expected: DownloadCategory) {
        #expect(DownloadCategory.categorize(fileName: name) == expected)
    }
}
