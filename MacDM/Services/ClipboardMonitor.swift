import AppKit
import Combine

extension Notification.Name {
    static let clipboardLinkDetected = Notification.Name("clipboardLinkDetected")
}

/// Polls the system pasteboard for newly copied download-looking URLs
/// and surfaces a prompt so the user can add them with one click.
final class ClipboardMonitor: ObservableObject {
    static let shared = ClipboardMonitor()

    @Published var isEnabled: Bool = true
    @Published var pendingURL: URL?
    @Published var showPrompt: Bool = false

    private var lastChangeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?

    private let downloadExtensions: Set<String> = [
        "zip", "rar", "7z", "tar", "gz", "dmg", "pkg", "exe", "msi",
        "mp3", "mp4", "mkv", "avi", "mov", "flac", "wav",
        "pdf", "docx", "xlsx", "pptx", "iso"
    ]

    private init() {}

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkPasteboard()
        }
    }

    func stop() {
        timer?.invalidate()
    }

    private func checkPasteboard() {
        guard isEnabled else { return }
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount

        guard let str = pb.string(forType: .string),
              let url = URL(string: str.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme, scheme == "http" || scheme == "https" else { return }

        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        guard downloadExtensions.contains(ext) else { return }

        NotificationCenter.default.post(name: .clipboardLinkDetected, object: url)
    }
}
