import Foundation
import Observation

@MainActor @Observable public final class LibraryStore {
    public private(set) var recordings: [Recording] = []
    public private(set) var errorMessage: String?
    private let root: URL
    private var indexURL: URL { root.appendingPathComponent("library.json") }
    private var removedPaths: Set<String> = []
    private struct Index: Codable {
        var recordings: [Recording]
        var removedPaths: Set<String>
    }

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReKap", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: indexURL.path) {
                let data = try Data(contentsOf: indexURL)
                if let index = try? JSONDecoder().decode(Index.self, from: data) {
                    recordings = index.recordings
                    removedPaths = index.removedPaths
                } else {
                    recordings = try JSONDecoder().decode([Recording].self, from: data)
                }
            }
        } catch {
            errorMessage = "Could not load recording history: \(error.localizedDescription)"
        }
    }

    public func add(url: URL, title: String? = nil, recovered: Bool = false) throws {
        let path = url.standardizedFileURL.path
        if recovered && removedPaths.contains(path) { return }
        guard !recordings.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        let recording = Recording(url: url, title: title ?? url.deletingPathExtension().lastPathComponent)
        let updated = [recording] + recordings
        var paths = removedPaths
        paths.remove(path)
        try persist(updated, removed: paths)
        recordings = updated
    }

    /// Removes history entries only. Source videos always remain on disk.
    public func remove(_ ids: Set<UUID>) throws {
        let updated = recordings.filter { !ids.contains($0.id) }
        let paths = removedPaths.union(recordings.filter { ids.contains($0.id) }.map { $0.url.standardizedFileURL.path })
        try persist(updated, removed: paths)
        recordings = updated
    }

    private func persist(_ recordings: [Recording], removed: Set<String>) throws {
        // Preserve an unreadable index for diagnosis before replacing it.
        if errorMessage != nil, FileManager.default.fileExists(atPath: indexURL.path) {
            let backup = root.appendingPathComponent("library-unreadable-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: indexURL, to: backup)
        }
        try JSONEncoder().encode(Index(recordings: recordings, removedPaths: removed)).write(to: indexURL, options: .atomic)
        removedPaths = removed
        errorMessage = nil
    }
}
