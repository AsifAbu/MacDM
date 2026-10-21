import Foundation
import Combine
#if canImport(AppKit)
import AppKit
import UserNotifications
#endif

/// Central coordinator: owns the task list, queue, scheduler, persistence,
/// and settings (concurrency limit, speed limit, schedule window).
final class DownloadManager: ObservableObject {
    static let shared: DownloadManager = {
        // Under the test runner, never touch the user's real task list or downloads.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MacDM-tests-shared-\(UUID().uuidString)")
            return DownloadManager(storageDirectory: dir)
        }
        return DownloadManager()
    }()

    @Published var tasks: [DownloadTask] = []
    @Published var maxConcurrentDownloads: Int = 3
    @Published var globalSpeedLimitKBs: Double = 0 // 0 = unlimited
    @Published var scheduleEnabled: Bool = false
    @Published var scheduleStart: Date = Calendar.current.date(bySettingHour: 2, minute: 0, second: 0, of: Date()) ?? Date()
    @Published var scheduleEnd: Date = Calendar.current.date(bySettingHour: 6, minute: 0, second: 0, of: Date()) ?? Date()
    /// Where new downloads are saved. The user picks this in Settings; the choice is
    /// remembered across launches. Until then it is the system default (see `systemDefaultFolder`).
    @Published var defaultDownloadFolder: URL {
        didSet {
            if defaultDownloadFolder.standardizedFileURL.path == fallbackFolder.standardizedFileURL.path {
                defaults.removeObject(forKey: Self.folderKey)
            } else {
                defaults.set(defaultDownloadFolder.path, forKey: Self.folderKey)
            }
        }
    }
    @Published var organizeByCategory: Bool = true

    static let connectionsKey = "connectionsPerDownload"
    static let connectionsRange = 1...32

    /// How many connections each download may use at once. Measured on real servers: going from 1 to 8 can
    /// roughly triple the speed where a server limits each connection, and beyond 8 there was no gain (and
    /// some servers get slower), so 8 is the default. Remembered across launches.
    @Published var connectionsPerDownload: Int = 8 {
        didSet {
            let clamped = min(max(connectionsPerDownload, Self.connectionsRange.lowerBound), Self.connectionsRange.upperBound)
            if clamped != connectionsPerDownload { connectionsPerDownload = clamped; return }
            defaults.set(clamped, forKey: Self.connectionsKey)
        }
    }

    private var engines: [UUID: DownloadEngine] = [:]
    private var mediaJobs: [UUID: MediaDownloadJob] = [:]
    private var schedulerTimer: Timer?
    private let persistenceURL: URL
    private let isIsolated: Bool
    private let defaults: UserDefaults
    private let fallbackFolder: URL
    /// Hidden home of every unfinished download (one folder each). Finished files are moved out of it.
    private let incompleteRoot: URL

    static let folderKey = "downloadFolderPath"

    /// What a fresh install uses: a "MacDM" folder inside the user's own Downloads folder.
    static var systemDefaultFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacDM", isDirectory: true)
    }

    /// True if `url` is an existing folder we are allowed to write into.
    static func isUsableFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isWritableFile(atPath: url.path)
    }

    /// A folder path as shown to the user, e.g. "~/Downloads/MacDM".
    static func displayPath(_ url: URL) -> String {
        (url.standardizedFileURL.path as NSString).abbreviatingWithTildeInPath
    }

    /// Goes back to the system default folder.
    func resetDownloadFolder() {
        try? FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
        defaultDownloadFolder = fallbackFolder
    }

    private convenience init() {
        self.init(storageDirectory: nil)
    }

    /// `storageDirectory` is for tests: tasks.json and downloads go under it, and the
    /// scheduler and notifications are left off. The app itself uses `shared`.
    /// `defaults` lets tests keep settings out of the real user defaults.
    init(storageDirectory: URL?, defaults: UserDefaults? = nil) {
        isIsolated = storageDirectory != nil
        self.defaults = defaults ?? (storageDirectory == nil
            ? .standard
            : UserDefaults(suiteName: "MacDM-isolated-\(UUID().uuidString)")!)

        if let storageDirectory {
            fallbackFolder = storageDirectory.appendingPathComponent("Downloads")
            self.persistenceURL = storageDirectory.appendingPathComponent("tasks.json")
        } else {
            fallbackFolder = Self.systemDefaultFolder

            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let myAppSupport = appSupport.appendingPathComponent("MacDM")
            try? FileManager.default.createDirectory(at: myAppSupport, withIntermediateDirectories: true)
            self.persistenceURL = myAppSupport.appendingPathComponent("tasks.json")
        }

        incompleteRoot = persistenceURL.deletingLastPathComponent().appendingPathComponent("Incomplete", isDirectory: true)

        // Use the folder the user chose earlier. If it is gone (e.g. an unplugged drive),
        // fall back to the default for this session but keep the saved choice.
        try? FileManager.default.createDirectory(at: fallbackFolder, withIntermediateDirectories: true)
        if let saved = self.defaults.string(forKey: Self.folderKey),
           Self.isUsableFolder(URL(fileURLWithPath: saved, isDirectory: true)) {
            self.defaultDownloadFolder = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            self.defaultDownloadFolder = fallbackFolder
        }

        if let saved = self.defaults.object(forKey: Self.connectionsKey) as? Int,
           Self.connectionsRange.contains(saved) {
            self.connectionsPerDownload = saved
        }

        loadTasks()
        removeOrphanedWorkFolders()
        if !isIsolated {
            startScheduler()
            requestNotificationPermission()
        }
    }

    // MARK: - Public API

    @discardableResult
    func addDownload(url: URL, suggestedName: String? = nil, startImmediately: Bool = true,
                     headers: [String: String]? = nil) -> DownloadTask {
        // The name can come from a web page, so reduce it to a safe single file name.
        let fileName = RequestSecurity.safeFileName(suggestedName ?? url.lastPathComponent)
        let category = DownloadCategory.categorize(fileName: fileName)
        let folder = organizeByCategory
            ? defaultDownloadFolder.appendingPathComponent(category.folderName)
            : defaultDownloadFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let task = DownloadTask(url: url, fileName: fileName, destinationFolder: folder)
        task.workFolder = incompleteRoot.appendingPathComponent(task.id.uuidString, isDirectory: true)
        task.requestHeaders = headers
        tasks.insert(task, at: 0)
        persistTasks()

        if startImmediately {
            enqueueAndProcess(task)
        }
        return task
    }

    /// Queues a video/stream download that yt-dlp resolves from a page or playlist URL.
    @discardableResult
    func addMediaDownload(pageURL: URL, title: String, formatSelector: String, audioOnly: Bool, referer: String?,
                          headers: [String: String]? = nil, cookies: [BrowserCookie] = []) -> DownloadTask {
        let safeTitle = title.replacingOccurrences(of: "/", with: "-")
        let fileName = safeTitle + (audioOnly ? ".m4a" : ".mp4")
        let task = addDownload(url: pageURL, suggestedName: fileName, startImmediately: false, headers: headers)
        task.mediaFormat = formatSelector
        task.mediaReferer = referer
        // The browser's sign-in goes in a private file inside this download's hidden folder, never into the saved
        // task list, and disappears with the folder when the download finishes or is cancelled.
        if !cookies.isEmpty, let work = task.workFolder {
            try? CookieFile.write(cookies, to: work.appendingPathComponent(CookieFile.fileName))
        }
        persistTasks()
        enqueueAndProcess(task)
        return task
    }

    func start(_ task: DownloadTask) {
        guard task.status != .downloading else { return }
        task.status = .queued
        processQueue()
    }

    func pause(_ task: DownloadTask) {
        engines[task.id]?.pause()
        engines.removeValue(forKey: task.id)
        mediaJobs.removeValue(forKey: task.id)?.stop(as: .paused)
        // A queued task has no engine yet; without this the queue would start it.
        if task.status == .queued || task.status == .downloading { task.status = .paused }
        persistTasks()
        processQueue()
    }

    func pauseAll() {
        for task in tasks where task.status == .downloading {
            pause(task)
        }
    }

    func resumeAll() {
        for task in tasks where task.status == .paused || task.status == .failed {
            start(task)
        }
    }

    func cancel(_ task: DownloadTask) {
        engines[task.id]?.cancel()
        engines.removeValue(forKey: task.id)
        mediaJobs.removeValue(forKey: task.id)?.stop(as: .cancelled)
        // Queued/paused tasks have no engine to do this; set it here so it is
        // saved as cancelled and the queue can't start it again.
        if task.status != .completed {
            task.deleteUnfinishedFiles()   // permanent, and only this download's own unfinished files
            task.status = .cancelled
            task.speedBytesPerSec = 0
        }
        persistTasks()
        processQueue()
    }

    /// What the ✕ button on a row does: stop a download that is still active,
    /// or take a finished/failed/cancelled one out of the history list.
    /// Removing never deletes the downloaded file from disk.
    /// After a crash, or for a download that no longer exists or can no longer resume, a work folder can be left
    /// behind. Only folders inside the hidden Incomplete folder are ever removed here.
    private func removeOrphanedWorkFolders() {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: incompleteRoot, includingPropertiesForKeys: nil) else { return }
        let resumable: Set<String> = Set(tasks
            .filter { [.queued, .paused, .downloading, .failed].contains($0.status) }
            .map { $0.id.uuidString })
        for folder in folders where !resumable.contains(folder.lastPathComponent) {
            try? fileManager.removeItem(at: folder)
        }
    }

    func cancelOrRemove(_ task: DownloadTask) {
        switch task.status {
        case .downloading, .queued, .paused:
            cancel(task)
        case .completed, .failed, .cancelled:
            remove(task)
        }
    }

    func remove(_ task: DownloadTask) {
        cancel(task)
        tasks.removeAll { $0.id == task.id }
        persistTasks()
    }

    func retry(_ task: DownloadTask) {
        task.status = .queued
        task.errorMessage = nil
        task.retryCount = 0
        processQueue()
    }

    func setPriority(_ task: DownloadTask, priority: Int) {
        task.priority = priority
        persistTasks()
        processQueue()
    }

    // MARK: - Queue processing

    private func enqueueAndProcess(_ task: DownloadTask) {
        task.status = .queued
        processQueue()
    }

    /// Call whenever task states or settings change: starts as many queued
    /// tasks as the concurrency limit and schedule window allow.
    func processQueue() {
        guard isWithinScheduleWindow() else { return }

        let runningCount = tasks.filter { $0.status == .downloading }.count
        guard runningCount < maxConcurrentDownloads else { return }

        let candidates = tasks
            .filter { $0.status == .queued }
            .sorted { $0.priority > $1.priority || ($0.priority == $1.priority && $0.dateAdded < $1.dateAdded) }

        let slotsAvailable = maxConcurrentDownloads - runningCount
        for task in candidates.prefix(slotsAvailable) {
            startEngine(for: task)
        }
        redistributeSpeedLimit()
    }

    private func startEngine(for task: DownloadTask) {
        if task.mediaFormat != nil {
            startMediaJob(for: task)
            return
        }
        let engine = DownloadEngine(task: task, connections: connectionsPerDownload)
        engine.speedLimitBytesPerSec = perTaskSpeedLimitBytes()
        engine.onFinished = { [weak self] result in
            guard let self = self else { return }
            self.engines.removeValue(forKey: task.id)
            self.persistTasks()
            if case .success = result {
                self.notifyCompletion(task)
            }
            self.processQueue()
        }
        engines[task.id] = engine
        engine.start()
    }

    private func startMediaJob(for task: DownloadTask) {
        let job = MediaDownloadJob(task: task)
        job.concurrentFragments = min(connectionsPerDownload, 16)
        job.speedLimitBytesPerSec = perTaskSpeedLimitBytes()
        job.onFinished = { [weak self] result in
            guard let self = self else { return }
            self.mediaJobs.removeValue(forKey: task.id)
            self.persistTasks()
            if case .success = result {
                self.notifyCompletion(task)
            }
            self.processQueue()
        }
        mediaJobs[task.id] = job
        job.start()
    }

    private func redistributeSpeedLimit() {
        let perTask = perTaskSpeedLimitBytes()
        engines.values.forEach { $0.speedLimitBytesPerSec = perTask }
    }

    private func perTaskSpeedLimitBytes() -> Double {
        guard globalSpeedLimitKBs > 0 else { return 0 }
        let runningCount = max(engines.count, 1)
        return (globalSpeedLimitKBs * 1024) / Double(runningCount)
    }

    // MARK: - Scheduler

    private func startScheduler() {
        schedulerTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.processQueue()
        }
    }

    private func isWithinScheduleWindow() -> Bool {
        guard scheduleEnabled else { return true }
        let now = Date()
        let cal = Calendar.current
        let nowMinutes = cal.component(.hour, from: now) * 60 + cal.component(.minute, from: now)
        let startMinutes = cal.component(.hour, from: scheduleStart) * 60 + cal.component(.minute, from: scheduleStart)
        let endMinutes = cal.component(.hour, from: scheduleEnd) * 60 + cal.component(.minute, from: scheduleEnd)
        if startMinutes <= endMinutes {
            return nowMinutes >= startMinutes && nowMinutes <= endMinutes
        } else {
            // window spans midnight
            return nowMinutes >= startMinutes || nowMinutes <= endMinutes
        }
    }

    // MARK: - Persistence

    func persistTasks() {
        do {
            let data = try JSONEncoder().encode(tasks)
            try data.write(to: persistenceURL, options: .atomic)
        } catch {
            print("Failed to persist tasks: \(error)")
        }
    }

    private func loadTasks() {
        guard let data = try? Data(contentsOf: persistenceURL) else { return }
        if let decoded = try? JSONDecoder().decode([DownloadTask].self, from: data) {
            self.tasks = decoded
        }
    }

    // MARK: - Notifications

    private func requestNotificationPermission() {
        #if canImport(AppKit)
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        #endif
    }

    private func notifyCompletion(_ task: DownloadTask) {
        #if canImport(AppKit)
        guard !isIsolated else { return }
        let content = UNMutableNotificationContent()
        content.title = "Download Complete"
        content.body = task.fileName
        content.sound = .default
        let request = UNNotificationRequest(identifier: task.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
        #endif
    }

    // MARK: - History / Search

    func searchTasks(_ query: String) -> [DownloadTask] {
        guard !query.isEmpty else { return tasks }
        return tasks.filter { $0.fileName.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query) }
    }

    func tasks(in category: DownloadCategory) -> [DownloadTask] {
        tasks.filter { $0.category == category }
    }

    func clearCompleted() {
        tasks.removeAll { $0.status == .completed }
        persistTasks()
    }
}
