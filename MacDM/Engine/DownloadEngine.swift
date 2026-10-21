import Foundation
import Combine

/// Orchestrates a single DownloadTask: probes the server, splits it into
/// segments, runs them in parallel, merges progress, and handles retry.
final class DownloadEngine {
    let task: DownloadTask
    private var segmentDownloaders: [SegmentDownloader] = []
    private var fileHandle: FileHandle?
    private let writeLock = NSLock() // shared with the segments, see SegmentDownloader
    private let segmentCount: Int
    private var activeSegments = 0
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

    var speedLimitBytesPerSec: Double = 0 {
        didSet { segmentDownloaders.forEach { $0.speedLimitBytesPerSec = speedLimitBytesPerSec / Double(max(segmentDownloaders.count, 1)) } }
    }

    var onFinished: ((Result<Void, Error>) -> Void)?

    init(task: DownloadTask, segmentCount: Int = 8) {
        self.task = task
        self.segmentCount = segmentCount
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

        let effectiveSegmentCount = (acceptsRanges && contentLength > 1_048_576) ? segmentCount : 1

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
        activeSegments = 0

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
            downloader.speedLimitBytesPerSec = speedLimitBytesPerSec / Double(max(effectiveSegmentCount, 1))
            downloader.onProgress = { [weak self] bytes in
                self?.handleProgress(segmentIndex: seg.index, bytes: bytes)
            }
            downloader.onComplete = { [weak self] result in
                self?.handleSegmentComplete(segmentIndex: seg.index, result: result)
            }
            segmentDownloaders.append(downloader)
            activeSegments += 1
        }

        if segmentDownloaders.isEmpty {
            // Nothing left to download; already complete.
            finishMergeAndComplete()
            return
        }

        segmentDownloaders.forEach { $0.start() }
        startProgressTimer()
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
            finishedSegments += 1
            if finishedSegments >= segmentDownloaders.count + (task.segments.count - segmentDownloaders.count) {
                finishMergeAndComplete()
            }
        case .failure(let error):
            guard !hasFailed else { return }
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
        downloader.onProgress = { [weak self] bytes in self?.handleProgress(segmentIndex: seg.index, bytes: bytes) }
        downloader.onComplete = { [weak self] result in self?.handleSegmentComplete(segmentIndex: seg.index, result: result) }
        segmentDownloaders.append(downloader)
        downloader.start()
    }

    private func finishMergeAndComplete() {
        guard !isStopped else { return }
        progressTimer?.invalidate()
        closeFile()
        let dest = task.finalDestinationURL
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: task.partFileURL, to: dest)
            try? FileManager.default.removeItem(at: task.metadataURL)
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
        try? FileManager.default.removeItem(at: task.partFileURL)
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
