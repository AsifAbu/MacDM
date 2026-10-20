import Foundation
import Testing
@testable import MacDM

/// Where downloads are saved: the default on a fresh install, and the folder the user picks.
@MainActor
@Suite("Download folder")
struct DownloadFolderTests {
    private let unreachable = URL(string: "http://127.0.0.1:9/never.bin")!

    private func makeFolder(named name: String = UUID().uuidString) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MacDMFolder-\(name)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a fresh install defaults to a MacDM folder inside the user's Downloads folder")
    func systemDefault() {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
        #expect(DownloadManager.systemDefaultFolder.deletingLastPathComponent().standardizedFileURL.path
                == downloads.standardizedFileURL.path)
        #expect(DownloadManager.systemDefaultFolder.lastPathComponent == "MacDM")
    }

    @Test("with no saved choice the default folder is used and created")
    func freshInstallUsesDefault() {
        let env = IsolatedManager()
        defer { env.cleanUp() }
        #expect(DownloadManager.isUsableFolder(env.manager.defaultDownloadFolder))
        #expect(env.defaults.string(forKey: DownloadManager.folderKey) == nil)
    }

    @Test("a folder chosen in Settings is used for new downloads")
    func chosenFolderIsUsed() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp(); try? FileManager.default.removeItem(at: chosen) }
        env.manager.organizeByCategory = false
        env.manager.maxConcurrentDownloads = 0

        env.manager.defaultDownloadFolder = chosen
        let task = env.manager.addDownload(url: unreachable, suggestedName: "a.zip")
        #expect(task.destinationFolder.standardizedFileURL.path == chosen.standardizedFileURL.path)
    }

    @Test("category folders are created inside the chosen folder")
    func categoryInsideChosenFolder() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp(); try? FileManager.default.removeItem(at: chosen) }
        env.manager.maxConcurrentDownloads = 0
        env.manager.defaultDownloadFolder = chosen

        let task = env.manager.addDownload(url: unreachable, suggestedName: "movie.mp4")
        #expect(task.destinationFolder.standardizedFileURL.path
                == chosen.appendingPathComponent("Video").standardizedFileURL.path)
    }

    @Test("the chosen folder is remembered after relaunch")
    func choiceSurvivesRelaunch() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp(); try? FileManager.default.removeItem(at: chosen) }

        env.manager.defaultDownloadFolder = chosen
        let reloaded = env.relaunch()
        #expect(reloaded.defaultDownloadFolder.standardizedFileURL.path == chosen.standardizedFileURL.path)
    }

    @Test("if the chosen folder no longer exists, the default is used instead")
    func missingFolderFallsBack() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp() }
        env.manager.defaultDownloadFolder = chosen
        try? FileManager.default.removeItem(at: chosen) // e.g. an unplugged drive

        let reloaded = env.relaunch()
        #expect(reloaded.defaultDownloadFolder.standardizedFileURL.path != chosen.standardizedFileURL.path)
        #expect(DownloadManager.isUsableFolder(reloaded.defaultDownloadFolder))
        // The choice is kept, so it returns when the folder comes back.
        #expect(env.defaults.string(forKey: DownloadManager.folderKey) != nil)
    }

    @Test("Use Default forgets the chosen folder")
    func resetToDefault() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp(); try? FileManager.default.removeItem(at: chosen) }
        let original = env.manager.defaultDownloadFolder

        env.manager.defaultDownloadFolder = chosen
        env.manager.resetDownloadFolder()
        #expect(env.manager.defaultDownloadFolder.standardizedFileURL.path == original.standardizedFileURL.path)
        #expect(env.defaults.string(forKey: DownloadManager.folderKey) == nil)
        #expect(env.relaunch().defaultDownloadFolder.standardizedFileURL.path == original.standardizedFileURL.path)
    }

    @Test("a file or an unwritable path is not accepted as a folder")
    func usableFolderCheck() {
        #expect(!DownloadManager.isUsableFolder(URL(fileURLWithPath: "/definitely/not/here")))
        #expect(!DownloadManager.isUsableFolder(URL(fileURLWithPath: "/etc/hosts")))
        #expect(DownloadManager.isUsableFolder(FileManager.default.temporaryDirectory))
    }

    @Test("existing downloads keep their own folder when the setting changes")
    func existingTasksUnaffected() {
        let env = IsolatedManager()
        let chosen = makeFolder()
        defer { env.cleanUp(); try? FileManager.default.removeItem(at: chosen) }
        env.manager.maxConcurrentDownloads = 0
        let before = env.manager.addDownload(url: unreachable, suggestedName: "old.zip")
        let oldFolder = before.destinationFolder

        env.manager.defaultDownloadFolder = chosen
        #expect(before.destinationFolder == oldFolder)
    }
}
