import Foundation

/// Keeps a copy of the Chrome extension in a place that never moves.
///
/// Chrome loads an unpacked extension straight from the folder you pick. If that folder is
/// inside MacDM.app (which is replaced on every update) or on a mounted disk image (which
/// disappears when ejected), Chrome starts showing "ERR_FILE_NOT_FOUND". So MacDM keeps its own
/// copy in Application Support and that is the folder users load in Chrome.
///
/// Updating files in place (instead of deleting the folder) keeps the path valid; after an app
/// update the user only has to press Reload on the extension card.
enum ChromeExtensionInstaller {
    static var installedFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacDM/ChromeExtension", isDirectory: true)
    }

    /// The copy that ships inside the app, if this build has one (builds run from Xcode don't).
    static var bundledFolder: URL? {
        let url = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension", isDirectory: true)
        return url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Makes `destination` identical to `source`. Returns true if anything was changed.
    @discardableResult
    static func sync(from source: URL, to destination: URL) throws -> Bool {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        var changed = false

        let wanted = try fm.contentsOfDirectory(atPath: source.path).filter { !$0.hasPrefix(".") }
        for name in wanted {
            let from = source.appendingPathComponent(name)
            let to = destination.appendingPathComponent(name)
            let newData = try Data(contentsOf: from)
            if (try? Data(contentsOf: to)) != newData {
                try newData.write(to: to, options: .atomic)
                changed = true
            }
        }
        // Remove files that no longer belong to the extension.
        for name in (try? fm.contentsOfDirectory(atPath: destination.path)) ?? [] where !wanted.contains(name) {
            try? fm.removeItem(at: destination.appendingPathComponent(name))
            changed = true
        }
        return changed
    }

    /// Brings the stable copy up to date with the one in the app. Returns its folder, or nil if
    /// this build has no bundled extension.
    @discardableResult
    static func installOrUpdate() -> URL? {
        guard let source = bundledFolder else { return nil }
        do {
            try sync(from: source, to: installedFolder)
            return installedFolder
        } catch {
            print("Could not install the Chrome extension copy: \(error)")
            return nil
        }
    }
}
