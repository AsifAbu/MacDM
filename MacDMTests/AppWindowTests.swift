import AppKit
import Testing
@testable import MacDM

/// Which windows count as "MacDM is open" (and so keep the Dock icon).
/// A menu or panel must not: the menu bar item's menu closes every time it is used,
/// and treating that as "all windows closed" removed the Dock icon right after it appeared.
@MainActor
@Suite("App windows")
struct AppWindowTests {
    private func window(level: NSWindow.Level = .normal) -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: true)
        w.level = level
        return w
    }

    // That a real, visible MacDM window does count is checked by running the app itself
    // (see the smoke test in the release steps): AppKit only reports a window as able to
    // become main once it is on screen, and showing windows inside the test runner crashes it.

    @Test("a panel does not count")
    func panel() {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                        styleMask: [.titled], backing: .buffered, defer: true)
        #expect(!AppWindows.isAppWindow(p))
    }

    @Test("a status-bar or menu level window does not count", arguments: [NSWindow.Level.statusBar, .popUpMenu, .mainMenu, .floating])
    func specialLevels(level: NSWindow.Level) {
        #expect(!AppWindows.isAppWindow(window(level: level)))
    }

    @Test("a borderless window that cannot become main does not count")
    func borderless() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 50, height: 50),
                         styleMask: [.borderless], backing: .buffered, defer: true)
        #expect(!AppWindows.isAppWindow(w))
    }
}

/// MacDM must show in the Dock (and have its own menu bar) whenever it is running.
/// That is simply how the app is configured; an earlier attempt to switch the Dock icon on and
/// off while windows opened and closed proved unreliable.
@Suite("Dock icon")
struct DockIconTests {
    @Test("the app is a normal app, not a menu-bar-only one")
    func isNormalApp() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool != true,
                "LSUIElement hides the Dock icon")
        #expect(Bundle.main.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true)
    }
}
