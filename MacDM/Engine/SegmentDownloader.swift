import Foundation

/// Downloads a single byte-range segment of a file using URLSession,
/// writing bytes directly into the shared destination file at the right offset.
final class SegmentDownloader: NSObject {
    let segmentIndex: Int
    let url: URL
    let startByte: Int64
    let endByte: Int64
    private(set) var downloadedInSession: Int64 = 0

    private var fileHandle: FileHandle?
    /// Shared by every segment of one download. The segments write into the same
    /// file from different threads, and a seek followed by a write is two steps:
    /// without this lock, another segment can move the file position in between
    /// and the bytes land at the wrong offset (a silently corrupted file).
    private let writeLock: NSLock
    /// Browser headers (Referer, Cookie…) sent with the request; servers that check them refuse a bare request.
    private let extraHeaders: [String: String]
    private var session: URLSession!
    private var dataTask: URLSessionDataTask?
    private var currentOffset: Int64

    var onProgress: ((Int64) -> Void)?       // bytes written this tick
    var onComplete: ((Result<Void, Error>) -> Void)?
    var speedLimitBytesPerSec: Double = 0     // 0 = unlimited
    private var bucketTokens: Double = 0
    private var lastRefill = Date()

    init(segmentIndex: Int, url: URL, startByte: Int64, endByte: Int64, alreadyDownloaded: Int64, fileHandle: FileHandle, writeLock: NSLock,
         headers: [String: String] = [:]) {
        self.segmentIndex = segmentIndex
        self.url = url
        self.startByte = startByte
        self.endByte = endByte
        self.currentOffset = startByte + alreadyDownloaded
        self.fileHandle = fileHandle
        self.writeLock = writeLock
        self.extraHeaders = headers
        super.init()
        self.session = URLSession(configuration: NetworkConfig.sessionConfiguration(), delegate: self, delegateQueue: nil)
    }

    func start() {
        guard currentOffset <= endByte else {
            // Already fully downloaded.
            onComplete?(.success(()))
            return
        }
        var request = URLRequest(url: url)
        for (name, value) in extraHeaders { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("bytes=\(currentOffset)-\(endByte)", forHTTPHeaderField: "Range")
        dataTask = session.dataTask(with: request)
        dataTask?.resume()
    }

    func pause() {
        dataTask?.cancel()
        session.invalidateAndCancel()
    }

    func cancel() {
        dataTask?.cancel()
        session.invalidateAndCancel()
    }

    private func throttleIfNeeded(bytes: Int) {
        guard speedLimitBytesPerSec > 0 else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(lastRefill)
        bucketTokens += elapsed * speedLimitBytesPerSec
        bucketTokens = min(bucketTokens, speedLimitBytesPerSec) // cap burst to 1s worth
        lastRefill = now
        bucketTokens -= Double(bytes)
        if bucketTokens < 0 {
            let waitTime = -bucketTokens / speedLimitBytesPerSec
            Thread.sleep(forTimeInterval: min(waitTime, 1.0))
            bucketTokens = 0
        }
    }
}

extension SegmentDownloader: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                     didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            onComplete?(.failure(DownloadError.badResponse))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        throttleIfNeeded(bytes: data.count)
        do {
            writeLock.lock()
            defer { writeLock.unlock() }
            try fileHandle?.seek(toOffset: UInt64(currentOffset))
            try fileHandle?.write(contentsOf: data)
            currentOffset += Int64(data.count)
            downloadedInSession += Int64(data.count)
            onProgress?(Int64(data.count))
        } catch {
            dataTask.cancel()
            onComplete?(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                     completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = NetworkConfig.credential(for: challenge)
        completionHandler(disposition, credential)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()   // this piece is done; free its connection and session
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                return // paused/cancelled intentionally, no completion callback needed here
            }
            onComplete?(.failure(error))
        } else {
            onComplete?(.success(()))
        }
    }
}

enum DownloadError: LocalizedError {
    case badResponse
    case noContentLength
    case rangeNotSupported
    case fileSystemError(String)
    case tooManyRetries

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Server returned an error response."
        case .noContentLength: return "Server did not provide a file size."
        case .rangeNotSupported: return "Server does not support resumable downloads."
        case .fileSystemError(let msg): return "File system error: \(msg)"
        case .tooManyRetries: return "Download failed after multiple retries."
        }
    }
}
