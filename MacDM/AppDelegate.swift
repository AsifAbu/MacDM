import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosting unit tests, don't resume the user's queue or open the local servers.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        UNUserNotificationCenter.current().delegate = self
        if Bundle.main.url(forResource: "AppIcon", withExtension: "icns") == nil {
            NSApp.applicationIconImage = AppIcon.make() // fallback for builds run from Xcode
        }

        // Resume downloads that were in-flight (queued) when the app last quit.
        // Paused, failed and cancelled ones stay as they were.
        DownloadManager.shared.processQueue()
        ClipboardMonitor.shared.start()
        NativeMessagingHost.shared.start()
        // Get the bundled tools through macOS's first-run check now, so the first video lookup is fast.
        MediaTools.warmUp()
        // Keep the video downloader (yt-dlp) current; at most once a day, can be turned off in Settings.
        YtDlpUpdater.checkIfDue()
        // Keep the Chrome extension copy in Application Support current (see ChromeExtensionInstaller).
        ChromeExtensionInstaller.installOrUpdate()

        // Launch quietly: close the main window SwiftUI opens at startup.
        // It is reopened from the menu bar icon or by clicking the app's Dock icon.
        DispatchQueue.main.async {
            NSApp.windows.filter { AppWindows.isAppWindow($0) }.forEach { $0.close() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // keep running in the menu bar
    }

    /// Clicking MacDM's icon (Dock, Finder, Spotlight) while it only lives in the menu bar opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppActions.showMainWindow() }
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                 withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

enum AppWindows {
    /// A real MacDM window (main window, Settings), not the menu bar item's own window or a panel.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.canBecomeMain && !(window is NSPanel) && window.level == .normal
    }
}

/// Things the menu bar item and the app menu can ask the app to do.
enum AppActions {
    /// Brings MacDM to the front. MacDM is a normal app: its Dock icon and menu bar are always there.
    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Shows the main window (used when the app is clicked while only in the menu bar).
    static func showMainWindow() {
        bringToFront()
        if let window = NSApp.windows.first(where: { $0.title == "MacDM" && AppWindows.isAppWindow($0) }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            NotificationCenter.default.post(name: .openMainWindow, object: nil)
        }
    }
}

extension Notification.Name {
    static let openMainWindow = Notification.Name("openMainWindow")
}

/// The app icon shown in the Dock, drawn in code until a designed icon is added.
enum AppIcon {
    static func make(size: CGFloat = 512) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let body = rect.insetBy(dx: size * 0.06, dy: size * 0.06)
            let shape = NSBezierPath(roundedRect: body, xRadius: size * 0.22, yRadius: size * 0.22)
            NSGradient(starting: NSColor(calibratedRed: 0.35, green: 0.62, blue: 1.0, alpha: 1),
                       ending: NSColor(calibratedRed: 0.06, green: 0.33, blue: 0.85, alpha: 1))?
                .draw(in: shape, angle: -90)

            let config = NSImage.SymbolConfiguration(pointSize: size * 0.5, weight: .semibold)
            if let symbol = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil)?
                .withSymbolConfiguration(config) {
                let white = symbol.copy() as! NSImage
                white.lockFocus()
                NSColor.white.set()
                NSRect(origin: .zero, size: white.size).fill(using: .sourceAtop)
                white.unlockFocus()
                let s = white.size
                white.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }
}
