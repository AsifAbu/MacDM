import Foundation
import Combine

/// Orchestrates a single DownloadTask: probes the server, cuts the file into pieces,
/// downloads them over several connections at once, merges progress, and handles retry.
///
/// There are more pieces than connections: whenever a connection finishes a piece it takes
/// the next waiting one, so no connection sits idle while a slower one catches up.
final class DownloadEngine {
    let task: DownloadTask
    private var segmentDownloaders: [SegmentDownloader] = []
    private var fileHandle: FileHandle?
    private let writeLock = NSLock() // shared with the segments, see SegmentDownloader
    /// How many connections may run at the same time.
    private let connections: Int
    /// Guards the scheduling state below, which pieces report back into from several threads.
    private let stateLock = NSLock()
    private var waiting: [SegmentDownloader] = []   // pieces not started yet
    private var running = 0                         // pieces downloading right now
    private var totalSegments = 0
    private var finishedSegments = 0
    private var hasFailed = false
    private var progressTimer: Timer?
    private var bytesSinceLastTick: Int64 = 0
    private let maxRetries = 5

    /// Set once the user pauses or cancels, so late callbacks (probe reply,
    /// segment retries, segment completions) can't restart or overwrite anything.
    private let stopLock = NSLock()
    private var _isStopped = false
    private var isStopped: Bool {
        get { stopLock.lock(); defer { stopLock.unlock() }; return _isStopped }
        set { stopLock.lock(); _isStopped = newValue; stopLock.unlock() }
    }

    /// The overall limit is shared by the connections that run at the same time.
    private var simultaneousConnections: Int { max(1, min(connections, totalSegments == 0 ? connections : totalSegments)) }

    var speedLimitBytesPerSec: Double = 0 {
        didSet { segmentDownloaders.forEach { $0.speedLimitBytesPerSec = speedLimitBytesPerSec / Double(simultaneousConnections) } }
    }

    var onFinished: ((Result<Void, Error>) -> Void)?

    init(task: DownloadTask, connections: Int = 8) {
        self.task = task
        self.connections = max(1, connections)
    }

    /// How many pieces to cut a file of this size into. Pieces are at least 512 KB; a large file gets
    /// about three pieces per connection so that faster connections take on more of the work.
    static func pieceCount(fileSize: Int64, connections: Int, acceptsRanges: Bool) -> Int {
        guard acceptsRanges, fileSize > 1_048_576 else { return 1 }
        let bySize = max(1, Int(fileSize / 524_288))
        return max(min(connections, bySize), min(connections * 3, bySize))
    }

    // MARK: - Start / probe

    func start() {
        task.status = .downloading
        task.errorMessage = nil

        probeServer { [weak self] result in
            guard let self = self, !self.isStopped else { return }
            switch result {
            case .failure(let error):
                self.finish(.failure(error))
            case .success(let (contentLength, acceptsRanges, etag, lastModified)):
                DispatchQueue.main.async {
                    guard !self.isStopped else { return }
                    self.task.totalBytes = contentLength
                    self.task.supportsResume = acceptsRanges
                    self.task.eTag = etag
                    self.task.lastModified = lastModified
                    self.beginSegmentedDownload(contentLength: contentLength, acceptsRanges: acceptsRanges)
                }
            }
        }
    }

    private func probeServer(completion: @escaping (Result<(Int64, Bool, String?, String?), Error>) -> Void) {
        var request = URLRequest(url: task.url)
        request.httpMethod = "HEAD"
        for (name, value) in task.requestHeaders ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let session = URLSession(configuration: NetworkConfig.sessionConfiguration(), delegate: ProbeAuthDelegate.shared, delegateQueue: nil)
        session.dataTask(with: request) { _, response, error in
            if let error = error { completion(.failure(error)); return }
            guard let http = response as? HTTPURLResponse else {
                completion(.failure(DownloadError.badResponse)); return
            }
            let length = http.expectedContentLength
            let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") == "bytes")
            let etag = http.value(forHTTPHeaderField: "ETag")
            let lastModified = http.value(forHTTPHeaderField: "Last-Modified")
            completion(.success((length > 0 ? length : 0, acceptsRanges, etag, lastModified)))
        }.resume()
    }

    private func beginSegmentedDownload(contentLength: Int64, acceptsRanges: Bool) {
        guard !isStopped else { return }
        let folder = task.destinationFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The unfinished file lives in this download's own hidden folder, not in the download folder.
        try? FileManager.default.createDirectory(at: task.partFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Pre-allocate the part file to full size so segments can seek-write concurrently.
        let partPath = task.partFileURL
        if !FileManager.default.fileExists(atPath: partPath.path) {
            FileManager.default.createFile(atPath: partPath.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: partPath) else {
            finish(.failure(DownloadError.fileSystemError("Could not open destination file.")))
            return
        }
        if contentLength > 0 {
            try? handle.truncate(atOffset: UInt64(contentLength))
        }
        self.fileHandle = handle

        let effectiveSegmentCount = Self.pieceCount(fileSize: contentLength, connections: connections, acceptsRanges: acceptsRanges)

        if task.segments.isEmpty {
            // Fresh download: split into even byte ranges.
            var segs: [DownloadSegment] = []
            let chunkSize = contentLength > 0 ? contentLength / Int64(effectiveSegmentCount) : 0
            for i in 0..<effectiveSegmentCount {
                let start = Int64(i) * chunkSize
                let end = (i == effectiveSegmentCount - 1) ? max(contentLength - 1, start) : (start + chunkSize - 1)
                segs.append(DownloadSegment(index: i, startByte: start, endByte: end))
            }
            task.segments = segs
        }

        finishedSegments = task.segments.filter { $0.isComplete }.count
        totalSegments = task.segments.count
        running = 0

        for seg in task.segments where !seg.isComplete {
            let downloader = SegmentDownloader(
                segmentIndex: seg.index,
                url: task.url,
                startByte: seg.startByte,
                endByte: seg.endByte,
                alreadyDownloaded: seg.downloadedBytes,
                fileHandle: handle,
                writeLock: writeLock,
                headers: task.requestHeaders ?? [:]
            )
            downloader.speedLimitBytesPerSec = speedLimitBytesPerSec / Double(simultaneousConnections)
            downloader.onProgress = { [weak self] bytes in
                self?.handleProgress(segmentIndex: seg.index, bytes: bytes)
            }
            downloader.onComplete = { [weak self] result in
                self?.handleSegmentComplete(segmentIndex: seg.index, result: result)
            }
            segmentDownloaders.append(downloader)
            waiting.append(downloader)
        }

        if segmentDownloaders.isEmpty {
            // Nothing left to download; already complete.
            finishMergeAndComplete()
            return
        }

        startProgressTimer()
        startWaitingPieces()
    }

    /// Starts waiting pieces until all the allowed connections are busy.
    private func startWaitingPieces() {
        var toStart: [SegmentDownloader] = []
        stateLock.lock()
        while running < connections, !waiting.isEmpty {
            toStart.append(waiting.removeFirst())
            running += 1
        }
        stateLock.unlock()
        guard !isStopped else { return }
        toStart.forEach { $0.start() }
    }

    // MARK: - Progress

    private func handleProgress(segmentIndex: Int, bytes: Int64) {
        bytesSinceLastTick += bytes
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let idx = self.task.segments.firstIndex(where: { $0.index == segmentIndex }) {
                self.task.segments[idx].downloadedBytes += bytes
            }
            self.task.downloadedBytes += bytes
        }
    }

    private func startProgressTimer() {
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            let speed = Double(self.bytesSinceLastTick)
            self.bytesSinceLastTick = 0
            DispatchQueue.main.async {
                self.task.speedBytesPerSec = speed
            }
        }
    }

    private func handleSegmentComplete(segmentIndex: Int, result: Result<Void, Error>) {
        guard !isStopped else { return }
        switch result {
        case .success:
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                if let idx = self.task.segments.firstIndex(where: { $0.index == segmentIndex }) {
                    self.task.segments[idx].isComplete = true
                }
            }
            stateLock.lock()
            running -= 1
            finishedSegments += 1
            let allDone = finishedSegments >= totalSegments
            stateLock.unlock()
            if allDone {
                finishMergeAndComplete()
            } else {
                startWaitingPieces()   // this connection is free: give it the next piece
            }
        case .failure(let error):
            guard !hasFailed else { return }
            stateLock.lock(); running -= 1; stateLock.unlock()
            if task.retryCount < maxRetries {
                DispatchQueue.main.async { [weak self] in self?.task.retryCount += 1 }
                let delay = pow(2.0, Double(task.retryCount))
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.retrySegment(segmentIndex: segmentIndex)
                }
            } else {
                hasFailed = true
                finish(.failure(error))
            }
        }
    }

    private func retrySegment(segmentIndex: Int) {
        guard !isStopped else { return }
        guard let seg = task.segments.first(where: { $0.index == segmentIndex }), let handle = fileHandle else { return }
        let downloader = SegmentDownloader(
            segmentIndex: seg.index, url: task.url, startByte: seg.startByte,
            endByte: seg.endByte, alreadyDownloaded: seg.downloadedBytes, fileHandle: handle,
            writeLock: writeLock, headers: task.requestHeaders ?? [:]
        )
        downloader.speedLimitBytesPerSec = speedLimitBytesPerSec / Double(simultaneousConnections)
        downloader.onProgress = { [weak self] bytes in self?.handleProgress(segmentIndex: seg.index, bytes: bytes) }
        downloader.onComplete = { [weak self] result in self?.handleSegmentComplete(segmentIndex: seg.index, result: result) }
        stateLock.lock()
        segmentDownloaders.append(downloader)
        waiting.insert(downloader, at: 0)   // a retried piece goes first
        stateLock.unlock()
        startWaitingPieces()
    }

    private func finishMergeAndComplete() {
        guard !isStopped else { return }
        progressTimer?.invalidate()
        closeFile()
        do {
            // A file with this name may already be there: keep it, and save this one as "name (1)".
            // Moving works across disks too (a copy, then the original is removed).
            let saved = try FileNaming.moveWithoutReplacing(task.partFileURL, as: task.fileName, into: task.destinationFolder)
            task.deleteUnfinishedFiles()   // nothing of this download stays behind
            let savedName = saved.lastPathComponent
            DispatchQueue.main.async { [task] in task.fileName = savedName }   // runs before finish() sets "completed"
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard !isStopped else { return }
        progressTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped else { return }
            switch result {
            case .success:
                self.task.status = .completed
                self.task.dateCompleted = Date()
                self.task.speedBytesPerSec = 0
            case .failure(let error):
                self.task.status = .failed
                self.task.errorMessage = error.localizedDescription
                self.task.speedBytesPerSec = 0
            }
            self.onFinished?(result)
        }
    }

    // MARK: - Pause / Cancel

    func pause() {
        isStopped = true
        progressTimer?.invalidate()
        segmentDownloaders.forEach { $0.pause() }
        closeFile()
        onMain { self.task.status = .paused; self.task.speedBytesPerSec = 0 }
    }

    func cancel() {
        isStopped = true
        progressTimer?.invalidate()
        segmentDownloaders.forEach { $0.cancel() }
        closeFile()
        task.deleteUnfinishedFiles()
        onMain { self.task.status = .cancelled; self.task.speedBytesPerSec = 0 }
    }

    /// Closes the shared file between writes, never in the middle of one.
    private func closeFile() {
        writeLock.lock()
        try? fileHandle?.close()
        writeLock.unlock()
    }

    /// Runs immediately when already on the main thread, so the new status is
    /// in place before the caller persists the task list.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

/// Minimal delegate so the HEAD probe request also honors proxy/site auth.
final class ProbeAuthDelegate: NSObject, URLSessionTaskDelegate {
    static let shared = ProbeAuthDelegate()
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = NetworkConfig.credential(for: challenge)
        completionHandler(disposition, credential)
    }
}
