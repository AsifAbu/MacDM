import Foundation
import Network
@testable import MacDM

/// A tiny HTTP file server running inside the test process (127.0.0.1, free port).
///
/// Serves a deterministic body of `bodySize` bytes at any path. Supports HEAD and
/// GET with `Range`, plus optional delays so tests can pause/cancel a download
/// while it is still in flight.
final class TestHTTPServer: @unchecked Sendable {
    struct Config {
        var bodySize = 1_000_000
        var headDelay: TimeInterval = 0      // delay before answering HEAD (the probe)
        var chunkSize = 64 * 1024
        var chunkDelay: TimeInterval = 0     // pause between body chunks (slow download)
        var acceptRanges = true
    }

    let config: Config
    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestHTTPServer")
    private let lock = NSLock()
    private var _headCount = 0
    private var _getCount = 0
    private var _requests: [(method: String, headers: [String: String])] = []
    private var _activeGets = Set<ObjectIdentifier>()   // connections currently downloading a body
    private var _maxActiveGets = 0
    private(set) var port: UInt16 = 0

    var headCount: Int { lock.lock(); defer { lock.unlock() }; return _headCount }
    var getCount: Int { lock.lock(); defer { lock.unlock() }; return _getCount }

    /// The most body downloads that were ever open at the same moment.
    var maxConcurrentGets: Int { lock.lock(); defer { lock.unlock() }; return _maxActiveGets }

    private func beginGet(_ connection: NWConnection) {
        lock.lock(); _activeGets.insert(ObjectIdentifier(connection)); _maxActiveGets = max(_maxActiveGets, _activeGets.count); lock.unlock()
    }
    private func endGet(_ connection: NWConnection) {
        lock.lock(); _activeGets.remove(ObjectIdentifier(connection)); lock.unlock()
    }

    /// Every request received so far: the method and the headers (names in lower case).
    var requests: [(method: String, headers: [String: String])] { lock.lock(); defer { lock.unlock() }; return _requests }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/file.bin")! }

    /// The exact bytes the server returns for the whole file.
    var expectedBody: Data { Self.bytes(0, config.bodySize - 1) }

    init(_ config: Config = Config()) throws {
        self.config = config
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: self?.queue ?? .main)
            self?.receive(on: connection, buffer: Data())
        }

        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port else {
            throw URLError(.cannotConnectToHost)
        }
        port = bound.rawValue
    }

    func stop() { listener.cancel() }

    // MARK: - Request handling

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if buffer.range(of: Data("\r\n\r\n".utf8)) != nil {
                self.respond(to: buffer, on: connection)
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: Data, on connection: NWConnection) {
        let text = String(decoding: request, as: UTF8.self)
        let lines = text.components(separatedBy: "\r\n")
        let method = lines.first?.split(separator: " ").first.map(String.init) ?? "GET"
        let total = config.bodySize

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        lock.lock(); _requests.append((method, headers)); lock.unlock()

        var rangeStart = 0
        var rangeEnd = total - 1
        var isRange = false
        if let header = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
           let spec = header.split(separator: "=").last {
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            if let start = parts.first.flatMap({ Int($0) }) {
                rangeStart = start
                if parts.count > 1, let end = Int(parts[1]) { rangeEnd = min(end, total - 1) }
                isRange = true
            }
        }

        if method == "HEAD" {
            lock.lock(); _headCount += 1; lock.unlock()
            var head = "HTTP/1.1 200 OK\r\nContent-Length: \(total)\r\n"
            if config.acceptRanges { head += "Accept-Ranges: bytes\r\n" }
            head += "Connection: close\r\n\r\n"
            queue.asyncAfter(deadline: .now() + config.headDelay) {
                connection.send(content: Data(head.utf8), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
            return
        }

        lock.lock(); _getCount += 1; lock.unlock()
        beginGet(connection)
        if !config.acceptRanges { isRange = false; rangeStart = 0; rangeEnd = total - 1 }
        let length = max(rangeEnd - rangeStart + 1, 0)
        var head = isRange ? "HTTP/1.1 206 Partial Content\r\n" : "HTTP/1.1 200 OK\r\n"
        if isRange { head += "Content-Range: bytes \(rangeStart)-\(rangeEnd)/\(total)\r\n" }
        head += "Content-Length: \(length)\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { self?.endGet(connection); connection.cancel(); return }
            self?.sendBody(on: connection, from: rangeStart, to: rangeEnd)
        })
    }

    private func sendBody(on connection: NWConnection, from offset: Int, to end: Int) {
        guard offset <= end else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { [weak self] _ in self?.endGet(connection); connection.cancel() })
            return
        }
        let upper = min(offset + config.chunkSize - 1, end)
        // The download is over for counting purposes once the last byte is handed over: the client cannot
        // finish (and start another piece) before that, so a delayed callback can't make us over-count.
        if upper >= end { endGet(connection) }
        connection.send(content: Self.bytes(offset, upper), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { self?.endGet(connection); connection.cancel(); return }
            if self.config.chunkDelay > 0 {
                self.queue.asyncAfter(deadline: .now() + self.config.chunkDelay) {
                    self.sendBody(on: connection, from: upper + 1, to: end)
                }
            } else {
                self.sendBody(on: connection, from: upper + 1, to: end)
            }
        })
    }

    /// Deterministic file content, so tests can verify downloaded bytes exactly.
    static func bytes(_ lower: Int, _ upper: Int) -> Data {
        guard upper >= lower else { return Data() }
        return Data((lower...upper).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ ($0 >> 8)) })
    }
}

// MARK: - Helpers

/// Polls `condition` until it is true or the timeout passes. Returns whether it became true.
@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return condition()
}

/// A manager that stores everything under a fresh temp directory.
struct IsolatedManager {
    let directory: URL
    let manager: DownloadManager
    /// Settings live in a throwaway suite, never in the real user defaults.
    let defaults: UserDefaults
    private let suiteName: String

    init() {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacDMTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        suiteName = "MacDMTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        manager = DownloadManager(storageDirectory: directory, defaults: defaults)
    }

    /// A second manager reading the same storage and settings, like the app after a relaunch.
    func relaunch() -> DownloadManager {
        DownloadManager(storageDirectory: directory, defaults: defaults)
    }

    /// Raw status strings exactly as they are on disk right now (not run through
    /// the model's decoder, which rewrites "downloading" to "queued").
    func persistedStatuses() -> [String] {
        let url = directory.appendingPathComponent("tasks.json")
        guard let data = try? Data(contentsOf: url),
              let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return list.compactMap { $0["status"] as? String }
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
