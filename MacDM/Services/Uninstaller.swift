import AppKit
import Security

/// "Uninstall MacDM…" in Settings.
///
/// Dragging an app to the Trash leaves its history and settings behind in the Library folder.
/// This removes the app the normal way (to the Trash, so it can be restored) and, if the user
/// wants, the data too. Downloaded files are never touched.
enum Uninstaller {
    // MARK: - What belongs to MacDM

    /// MacDM's data folders and files, given the user's Library folder.
    static func dataPaths(library: URL, bundleID: String) -> [URL] {
        [
            "Application Support/MacDM",                      // download history, Chrome extension copy, updated yt-dlp
            "Preferences/\(bundleID).plist",                  // settings, including the download folder
            "Caches/MacDM",
            "Caches/\(bundleID)",
            "HTTPStorages/\(bundleID)",
            "Saved Application State/\(bundleID).savedState"
        ].map { library.appendingPathComponent($0) }
    }

    static var libraryFolder: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    }

    /// Removes the given files and folders. Returns the ones that could not be removed.
    @discardableResult
    static func removeData(at paths: [URL]) -> [URL] {
        var failed: [URL] = []
        for path in paths where FileManager.default.fileExists(atPath: path.path) {
            do { try FileManager.default.removeItem(at: path) } catch { failed.append(path) }
        }
        return failed
    }

    /// Uninstalling only makes sense for the installed app, not for a copy run from Xcode or a disk image.
    static var canUninstall: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        let userApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        return path.hasPrefix("/Applications/") || path.hasPrefix(userApplications + "/")
    }

    // MARK: - The helper that finishes the job after MacDM has quit

    /// A running app keeps rewriting its own data while it quits, so the clean-up is done by a
    /// small script that waits until MacDM has really exited.
    static func cleanupScript(appPID: Int32, paths: [URL], bundleID: String, resetPreferences: Bool = true) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let removals = paths.map { "/bin/rm -rf \(quoted($0.path))" }.joined(separator: "\n")
        // Settings are cached by a macOS service, so they are reset through it. (Tests skip this.)
        let preferences = resetPreferences
            ? "/usr/bin/defaults delete \(quoted(bundleID)) 2>/dev/null\n/usr/bin/killall cfprefsd 2>/dev/null"
            : ""
        return """
        for i in $(/usr/bin/seq 1 150); do /bin/kill -0 \(appPID) 2>/dev/null || break; /bin/sleep 0.2; done
        /bin/sleep 0.5
        \(removals)
        \(preferences)
        exit 0
        """
    }

    /// Deletes everything MacDM saved in the Keychain (proxy and site passwords).
    static func removeKeychainItems(service: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - The button

    @MainActor
    static func confirmAndUninstall() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall MacDM?"
        alert.informativeText = """
        MacDM will quit and be moved to the Trash. Downloads in progress are stopped. \
        The files you downloaded are not touched.

        Safari: the MacDM extension goes away with the app.
        Chrome: remove the MacDM extension yourself at chrome://extensions.
        """
        let checkbox = NSButton(checkboxWithTitle: "Also delete my download history and settings", target: nil, action: nil)
        checkbox.state = .on
        checkbox.sizeToFit()
        alert.accessoryView = checkbox
        let uninstall = alert.addButton(withTitle: "Uninstall")
        uninstall.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(deleteData: checkbox.state == .on)
    }

    @MainActor
    static func perform(deleteData: Bool) {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.yourcompany.MacDM"

        // Stop everything first so nothing is writing while we remove it.
        DownloadManager.shared.pauseAll()
        NativeMessagingHost.shared.stop()
        LocalHTTPServer.shared.stop()

        if deleteData {
            removeKeychainItems(service: bundleID)
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let paths = deleteData ? dataPaths(library: libraryFolder, bundleID: bundleID) : []

        // Move the app to the Trash (so "Put Back" works), then quit.
        NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, error in
            DispatchQueue.main.async {
                if let error {
                    let failure = NSAlert()
                    failure.alertStyle = .warning
                    failure.messageText = "MacDM could not be moved to the Trash"
                    failure.informativeText = error.localizedDescription
                    failure.runModal()
                    return
                }
                if !paths.isEmpty {
                    let helper = Process()
                    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
                    helper.arguments = ["-c", cleanupScript(appPID: pid, paths: paths, bundleID: bundleID)]
                    helper.standardInput = FileHandle.nullDevice
                    helper.standardOutput = FileHandle.nullDevice
                    helper.standardError = FileHandle.nullDevice
                    try? helper.run()
                }
                NSApp.terminate(nil)
            }
        }
    }
}
