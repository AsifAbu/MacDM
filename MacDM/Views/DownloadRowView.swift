import SwiftUI
import AppKit

struct DownloadRowView: View {
    @ObservedObject var task: DownloadTask
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 22))
                .foregroundStyle(iconColor)
                .frame(width: 30)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if task.status == .downloading {
                        Text("•").foregroundStyle(.secondary)
                        Text(speedText).font(.caption).foregroundStyle(.secondary)
                        Text("•").foregroundStyle(.secondary)
                        Text(etaText).font(.caption).foregroundStyle(.secondary)
                    }
                }

                if task.status == .downloading || task.status == .paused {
                    ProgressView(value: task.progress)
                        .progressViewStyle(.linear)
                }
                if let error = task.errorMessage {
                    Text(error).font(.caption2).foregroundStyle(.red).lineLimit(1)
                }
            }

            Spacer()

            Text(sizeText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .trailing)

            controlButtons
        }
        .padding(.vertical, 6)
        .contextMenu {
            Button("Show in Finder") { revealInFinder() }
            Button("Copy URL") { copyURL() }
            Divider()
            Button("Remove from List", role: .destructive) { manager.remove(task) }
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            switch task.status {
            case .downloading:
                Button { manager.pause(task) } label: { Image(systemName: "pause.fill") }
            case .paused, .queued, .failed:
                Button { manager.start(task) } label: { Image(systemName: "play.fill") }
            case .completed:
                Button { revealInFinder() } label: { Image(systemName: "folder") }
            case .cancelled:
                Button { manager.retry(task) } label: { Image(systemName: "arrow.clockwise") }
            }
            // Cancels an active download; on a finished one it removes the entry from the list.
            Button { manager.cancelOrRemove(task) } label: { Image(systemName: "xmark") }
                .help(isActive ? "Cancel download" : "Remove from list (keeps the file)")
        }
        .buttonStyle(.borderless)
    }

    private var isActive: Bool {
        task.status == .downloading || task.status == .queued || task.status == .paused
    }

    private var statusText: String {
        switch task.status {
        case .downloading: return "\(Int(task.progress * 100))%"
        case .queued: return "Queued"
        case .paused: return "Paused — \(Int(task.progress * 100))%"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private var sizeText: String {
        guard task.totalBytes > 0 else { return "—" }
        return ByteFormatter.string(task.downloadedBytes) + " / " + ByteFormatter.string(task.totalBytes)
    }

    private var speedText: String {
        ByteFormatter.string(Int64(task.speedBytesPerSec)) + "/s"
    }

    private var etaText: String {
        guard task.speedBytesPerSec > 0 else { return "—" }
        let remaining = Double(task.totalBytes - task.downloadedBytes)
        let seconds = remaining / task.speedBytesPerSec
        return "ETA " + ByteFormatter.durationString(seconds)
    }

    private var iconName: String {
        switch task.category {
        case .compressed: return "doc.zipper"
        case .documents: return "doc.text"
        case .music: return "music.note"
        case .video: return "film"
        case .programs: return "app.badge"
        case .other: return "doc"
        }
    }

    private var iconColor: Color {
        switch task.status {
        case .completed: return .green
        case .failed: return .red
        case .downloading: return .accentColor
        default: return .secondary
        }
    }

    private func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([task.finalDestinationURL])
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.url.absoluteString, forType: .string)
    }
}

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    static func durationString(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
