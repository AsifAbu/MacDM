import SwiftUI

@main
struct MacDMApp: App {
    @StateObject private var manager = DownloadManager.shared
    @StateObject private var clipboardMonitor = ClipboardMonitor.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu()
        } label: {
            MenuBarIcon()
        }

        Window("MacDM", id: "main") {
            ContentView()
                .environmentObject(manager)
                .environmentObject(clipboardMonitor)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Download…") {
                    NotificationCenter.default.post(name: .showAddDownloadSheet, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }

        // The standard Mac Settings window: MacDM ▸ Settings… (Cmd+,).
        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

/// The menu bar icon. It is always alive, so it is also what opens the main window
/// when the app is clicked in the Dock or Finder while no window exists.
private struct MenuBarIcon: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "arrow.down.circle")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: "main")
            }
    }
}

/// Menu shown when the menu bar icon is clicked.
private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open MacDM") {
            AppActions.bringToFront()
            openWindow(id: "main")
        }
        Divider()
        Button("Quit MacDM") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

extension Notification.Name {
    static let showAddDownloadSheet = Notification.Name("showAddDownloadSheet")
}
