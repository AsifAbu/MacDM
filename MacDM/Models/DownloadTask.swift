import Foundation

enum DownloadStatus: String, Codable, CaseIterable {
    case queued
    case downloading
    case paused
    case completed
    case failed
    case cancelled
}

enum DownloadCategory: String, Codable, CaseIterable {
    case compressed, documents, music, video, programs, other

    static func categorize(fileName: String) -> DownloadCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "zip", "rar", "7z", "tar", "gz", "bz2": return .compressed
        case "pdf", "doc", "docx", "txt", "xls", "xlsx", "ppt", "pptx", "csv": return .documents
        case "mp3", "wav", "flac", "aac", "m4a", "ogg": return .music
        case "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m3u8", "ts": return .video
        case "dmg", "pkg", "app", "exe", "msi": return .programs
        default: return .other
        }
    }

    var folderName: String {
        switch self {
        case .compressed: return "Compressed"
        case .documents: return "Documents"
        case .music: return "Music"
        case .video: return "Video"
        case .programs: return "Programs"
        case .other: return "Other"
        }
    }
}

struct DownloadSegment: Codable, Identifiable {
    var id: UUID = UUID()
    var index: Int
    var startByte: Int64
    var endByte: Int64
    var downloadedBytes: Int64 = 0
    var isComplete: Bool = false
}

final class DownloadTask: Identifiable, ObservableObject, Codable, Hashable {
    static func == (lhs: DownloadTask, rhs: DownloadTask) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    let id: UUID
    @Published var url: URL
    @Published var fileName: String
    @Published var destinationFolder: URL
    @Published var category: DownloadCategory
    @Published var status: DownloadStatus = .queued
    @Published var totalBytes: Int64 = 0
    @Published var downloadedBytes: Int64 = 0
    @Published var speedBytesPerSec: Double = 0
    @Published var segments: [DownloadSegment] = []
    @Published var errorMessage: String?
    @Published var dateAdded: Date = Date()
    @Published var dateCompleted: Date?
    @Published var scheduledStart: Date?
    @Published var retryCount: Int = 0
    @Published var priority: Int = 0
    @Published var supportsResume: Bool = true
    @Published var eTag: String?
    @Published var lastModified: String?
    /// yt-dlp format selector; non-nil marks a media (video page / HLS) download.
    @Published var mediaFormat: String?
    @Published var mediaReferer: String?
    /// Headers from the browser (Referer, Cookie, User-Agent…) sent with every request for this file.
    @Published var requestHeaders: [String: String]?

    var progress: Double {
        guard totalBytes > 0 else { return 0 }
        return Double(downloadedBytes) / Double(totalBytes)
    }

    var finalDestinationURL: URL {
        destinationFolder.appendingPathComponent(fileName)
    }

    var partFileURL: URL {
        destinationFolder.appendingPathComponent(fileName + ".idmpart")
    }

    var metadataURL: URL {
        destinationFolder.appendingPathComponent(fileName + ".idmmeta")
    }

    init(url: URL, fileName: String, destinationFolder: URL) {
        self.id = UUID()
        self.url = url
        self.fileName = fileName
        self.destinationFolder = destinationFolder
        self.category = DownloadCategory.categorize(fileName: fileName)
    }

    // MARK: - Codable (for persistence across app restarts)
    enum CodingKeys: String, CodingKey {
        case id, url, fileName, destinationFolder, category, status,
             totalBytes, downloadedBytes, segments, dateAdded, dateCompleted,
             scheduledStart, retryCount, priority, supportsResume, eTag, lastModified,
             mediaFormat, mediaReferer, requestHeaders
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        url = try c.decode(URL.self, forKey: .url)
        fileName = try c.decode(String.self, forKey: .fileName)
        destinationFolder = try c.decode(URL.self, forKey: .destinationFolder)
        category = try c.decode(DownloadCategory.self, forKey: .category)
        status = try c.decode(DownloadStatus.self, forKey: .status)
        totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
        downloadedBytes = try c.decode(Int64.self, forKey: .downloadedBytes)
        segments = try c.decode([DownloadSegment].self, forKey: .segments)
        dateAdded = try c.decode(Date.self, forKey: .dateAdded)
        dateCompleted = try? c.decode(Date.self, forKey: .dateCompleted)
        scheduledStart = try? c.decode(Date.self, forKey: .scheduledStart)
        retryCount = try c.decode(Int.self, forKey: .retryCount)
        priority = try c.decode(Int.self, forKey: .priority)
        supportsResume = try c.decode(Bool.self, forKey: .supportsResume)
        eTag = try? c.decode(String.self, forKey: .eTag)
        lastModified = try? c.decode(String.self, forKey: .lastModified)
        mediaFormat = try? c.decode(String.self, forKey: .mediaFormat)
        mediaReferer = try? c.decode(String.self, forKey: .mediaReferer)
        requestHeaders = try? c.decode([String: String].self, forKey: .requestHeaders)
        // A download interrupted by quitting goes back to the queue and resumes on
        // launch. Paused, failed and cancelled tasks stay as the user left them.
        if status == .downloading { status = .queued }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(url, forKey: .url)
        try c.encode(fileName, forKey: .fileName)
        try c.encode(destinationFolder, forKey: .destinationFolder)
        try c.encode(category, forKey: .category)
        try c.encode(status, forKey: .status)
        try c.encode(totalBytes, forKey: .totalBytes)
        try c.encode(downloadedBytes, forKey: .downloadedBytes)
        try c.encode(segments, forKey: .segments)
        try c.encode(dateAdded, forKey: .dateAdded)
        try c.encodeIfPresent(dateCompleted, forKey: .dateCompleted)
        try c.encodeIfPresent(scheduledStart, forKey: .scheduledStart)
        try c.encode(retryCount, forKey: .retryCount)
        try c.encode(priority, forKey: .priority)
        try c.encode(supportsResume, forKey: .supportsResume)
        try c.encodeIfPresent(eTag, forKey: .eTag)
        try c.encodeIfPresent(lastModified, forKey: .lastModified)
        try c.encodeIfPresent(mediaFormat, forKey: .mediaFormat)
        try c.encodeIfPresent(mediaReferer, forKey: .mediaReferer)
        try c.encodeIfPresent(requestHeaders, forKey: .requestHeaders)
    }
}
