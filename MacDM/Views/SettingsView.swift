import SwiftUI
import AppKit

/// MacDM ▸ Settings… (Cmd+,). Four plain tabs in the standard Mac style.
struct SettingsView: View {
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DownloadsSettingsTab()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            BrowserSettingsTab()
                .tabItem { Label("Browser", systemImage: "safari") }
            NetworkSettingsTab()
                .tabItem { Label("Network", systemImage: "network") }
        }
        .frame(width: 540, height: 430)
        .environmentObject(manager)
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @EnvironmentObject var manager: DownloadManager

    private var isDefaultLocation: Bool {
        manager.defaultDownloadFolder.standardizedFileURL.path
            == DownloadManager.systemDefaultFolder.standardizedFileURL.path
    }

    var body: some View {
        Form {
            Section("Download location") {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(DownloadManager.displayPath(manager.defaultDownloadFolder))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(manager.defaultDownloadFolder.path)
                    Spacer()
                    Button("Browse…", action: browse)
                }
                HStack {
                    Button("Show in Finder") { NSWorkspace.shared.open(manager.defaultDownloadFolder) }
                    Button("Use Default") { manager.resetDownloadFolder() }
                        .disabled(isDefaultLocation)
                }
                Text("New downloads are saved here. Until you change it, this is a “MacDM” folder inside your Downloads folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Organizing") {
                Toggle("Sort downloads into folders by type (Video, Music, Documents…)", isOn: $manager.organizeByCategory)
            }

            Section("History") {
                Button("Clear Completed Downloads from List") { manager.clearCompleted() }
                Text("Removes finished downloads from the list. The files stay in your download folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Uninstall") {
                Button("Uninstall MacDM…", role: .destructive) { Uninstaller.confirmAndUninstall() }
                    .disabled(!Uninstaller.canUninstall)
                Text(Uninstaller.canUninstall
                     ? "Moves MacDM to the Trash and, if you choose, removes its history and settings. Your downloaded files are never deleted."
                     : "Available in the installed copy of MacDM (the one in your Applications folder).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose where MacDM saves new downloads"
        panel.directoryURL = manager.defaultDownloadFolder
        if panel.runModal() == .OK, let url = panel.url {
            manager.defaultDownloadFolder = url
        }
    }
}

// MARK: - Downloads

struct DownloadsSettingsTab: View {
    @EnvironmentObject var manager: DownloadManager

    var body: some View {
        Form {
            Section("Speed") {
                Stepper("Downloads at the same time: \(manager.maxConcurrentDownloads)",
                        value: $manager.maxConcurrentDownloads, in: 1...10)
                    .onChange(of: manager.maxConcurrentDownloads) { _ in manager.processQueue() }
                Stepper("Connections per download: \(manager.connectionsPerDownload)",
                        value: $manager.connectionsPerDownload, in: DownloadManager.connectionsRange)
                Text("More connections can be faster on sites that limit each one (up to about 3×), but past 8 there is rarely any gain and some sites slow down. 8 suits most.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Speed limit") {
                    HStack {
                        TextField("0", value: $manager.globalSpeedLimitKBs, format: .number)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text("KB/s")
                    }
                }
                Text("Enter 0 for no limit.").font(.caption).foregroundStyle(.secondary)
            }

            Section("Schedule") {
                Toggle("Only download during these hours", isOn: $manager.scheduleEnabled)
                DatePicker("From", selection: $manager.scheduleStart, displayedComponents: .hourAndMinute)
                    .disabled(!manager.scheduleEnabled)
                DatePicker("Until", selection: $manager.scheduleEnd, displayedComponents: .hourAndMinute)
                    .disabled(!manager.scheduleEnabled)
                Text("Outside these hours downloads wait in the queue and continue automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Browser

struct BrowserSettingsTab: View {
    @AppStorage("cookiesBrowser") private var cookiesBrowser = "none"
    @AppStorage(YtDlpUpdater.autoUpdateKey) private var autoUpdate = true
    @State private var ytDlpVersion: String?
    @State private var updateStatus = ""
    @State private var isChecking = false
    @State private var copiedExtensionPath: String?

    /// The stable copy of the Chrome extension (refreshed from the app each time).
    private var chromeExtensionFolder: URL? {
        if let installed = ChromeExtensionInstaller.installOrUpdate() { return installed }
        let existing = ChromeExtensionInstaller.installedFolder
        return FileManager.default.fileExists(atPath: existing.path) ? existing : nil
    }

    private var chromeAppURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome")
    }

    var body: some View {
        Form {
            Section("Browser extensions") {
                LabeledContent("Chrome") {
                    HStack {
                        Button("Copy Extension Folder") { copyExtensionFolderPath() }
                        .disabled(chromeExtensionFolder == nil)
                        Button("Open Chrome…") { openChromeExtensions() }
                            .disabled(chromeAppURL == nil)
                    }
                }
                if let path = copiedExtensionPath {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Copied the extension folder path", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text(path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Click “Open Chrome…”, turn on Developer mode, click “Load unpacked”, press ⌘ + Shift + G, paste the copied path, press Return, then click “Select”.")
                    }
                    .font(.caption)
                }
                Text("Chrome: use “Copy Extension Folder”, then load that folder with “Load unpacked”. MacDM keeps the folder up to date; after updating MacDM, press Reload on the extension in Chrome.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Video downloads") {
                Toggle("Keep the video downloader (yt-dlp) up to date", isOn: $autoUpdate)
                LabeledContent("Version") {
                    HStack {
                        Text(ytDlpVersion ?? "not found").foregroundStyle(.secondary)
                        if isChecking { ProgressView().controlSize(.small) }
                        Button("Check Now", action: checkForUpdate).disabled(isChecking)
                    }
                }
                if !updateStatus.isEmpty {
                    Text(updateStatus).font(.caption).foregroundStyle(.secondary)
                }
                Picker("Use cookies from", selection: $cookiesBrowser) {
                    Text("None").tag("none")
                    Text("Safari").tag("safari")
                    Text("Chrome").tag("chrome")
                    Text("Firefox").tag("firefox")
                    Text("Edge").tag("edge")
                    Text("Brave").tag("brave")
                }
                Text("Only needed if a site such as YouTube says “Sign in to confirm you’re not a bot”. Safari also needs Full Disk Access for MacDM.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshVersion() }
    }

    /// Puts the extension folder's path on the clipboard, for the “Go to folder” box of Chrome's file chooser.
    private func copyExtensionFolderPath() {
        guard let folder = chromeExtensionFolder else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(folder.path, forType: .string)
        copiedExtensionPath = folder.path
    }

    private func openChromeExtensions() {
        guard let chrome = chromeAppURL else { return }
        NSWorkspace.shared.open([URL(string: "chrome://extensions")!], withApplicationAt: chrome,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    private func refreshVersion() async {
        ytDlpVersion = await Task.detached { MediaTools.find("yt-dlp").flatMap { YtDlpUpdater.version(of: $0) } }.value
    }

    private func checkForUpdate() {
        isChecking = true
        updateStatus = "Checking…"
        Task {
            switch await YtDlpUpdater.shared.checkAndUpdate() {
            case .upToDate(let version): updateStatus = "yt-dlp is up to date (\(version))."
            case .updated(_, let version): updateStatus = "Updated to yt-dlp \(version)."
            case .failed(let message): updateStatus = "Could not update: \(message)"
            }
            await refreshVersion()
            isChecking = false
        }
    }
}

// MARK: - Network

struct NetworkSettingsTab: View {
    @AppStorage("proxyEnabled") private var proxyEnabled = false
    @AppStorage("proxyHost") private var proxyHost = ""
    @AppStorage("proxyPort") private var proxyPort = ""
    @AppStorage("proxyUsername") private var proxyUsername = ""
    @State private var proxyPassword: String = ""

    var body: some View {
        Form {
            Section("Proxy server") {
                Toggle("Use a proxy server", isOn: $proxyEnabled)
                TextField("Host", text: $proxyHost).disabled(!proxyEnabled)
                TextField("Port", text: $proxyPort).disabled(!proxyEnabled)
                TextField("Username (optional)", text: $proxyUsername).disabled(!proxyEnabled)
                SecureField("Password (optional)", text: $proxyPassword)
                    .disabled(!proxyEnabled)
                    .onChange(of: proxyPassword) { newValue in
                        CredentialStore.saveProxyPassword(newValue)
                    }
                Text("Logins for password-protected downloads are asked for per download and stored in your Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
