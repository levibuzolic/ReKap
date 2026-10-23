import Foundation
import Testing
@testable import ReKapCore

@MainActor struct LibraryStoreTests {
    @Test func historyPersistsWithoutDeletingSourceMedia() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let video = root.appendingPathComponent("video.mp4")
        try Data("source".utf8).write(to: video)
        try store.add(url: video)
        try store.add(url: video)
        #expect(store.recordings.count == 1)
        let id = try #require(store.recordings.first?.id)
        try store.rename(id, to: "Demo")
        let reloaded = LibraryStore(root: root)
        #expect(reloaded.recordings.first?.title == "Demo")
        try reloaded.remove([id])
        #expect(LibraryStore(root: root).recordings.isEmpty)
        #expect(FileManager.default.fileExists(atPath: video.path))
    }

    @Test func unreadableHistoryIsPreservedOnNextWrite() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let corrupt = Data("broken json".utf8)
        try corrupt.write(to: root.appendingPathComponent("library.json"))
        let store = LibraryStore(root: root)
        #expect(store.errorMessage != nil)
        try store.add(url: root.appendingPathComponent("clip.mp4"))
        let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("library-unreadable-") })
        #expect(try Data(contentsOf: backup) == corrupt)
        #expect(store.errorMessage == nil)
    }

    @Test func recoveryDoesNotRestoreRemovedEntriesButExplicitImportDoes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root)
        let url = root.appendingPathComponent("Recording.mp4")
        try store.add(url: url, recovered: true)
        try store.remove([try #require(store.recordings.first?.id)])
        let reloaded = LibraryStore(root: root)
        try reloaded.add(url: url, recovered: true)
        #expect(reloaded.recordings.isEmpty)
        try reloaded.add(url: url)
        #expect(reloaded.recordings.count == 1)
    }

    @Test func settingsRoundTripAndCaptureOptions() throws {
        let suite = "ReKap-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        #expect(settings.captureOptions.fps == 30)
        #expect(settings.captureOptions.showsCursor)
        settings.fps = 60
        settings.capturesMicrophone = true
        settings.microphoneID = "test-device"
        let originalDirectory = settings.recordingDirectory
        settings.recordingDirectory = "/tmp/ReKap-test-recordings"
        let loaded = AppSettings(defaults: defaults)
        #expect(loaded.captureOptions.fps == 60)
        #expect(loaded.captureOptions.capturesMicrophone)
        #expect(loaded.captureOptions.microphoneID == "test-device")
        #expect(loaded.recordingDirectories.contains(originalDirectory))
        #expect(loaded.recordingDirectories.contains("/tmp/ReKap-test-recordings"))
    }
}
