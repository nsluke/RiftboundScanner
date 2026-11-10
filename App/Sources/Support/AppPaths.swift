import Foundation

/// Where the app keeps what is not the user's: sync acknowledgements,
/// learning artefacts and catalog caches under
/// `Library/Application Support/Riftbound/`, all excluded from backup because
/// each is rebuilt from the server or from `Documents/Scans`. `Documents/Scans`
/// stays the only file-shared tree.
nonisolated struct AppPaths: Hashable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// Per-batch `sync.json` and the rebuildable outbox.
    var sync: URL { root.appending(path: "Sync", directoryHint: .isDirectory) }
    /// Overlay store, policy and calibration print.
    var learning: URL { root.appending(path: "Learning", directoryHint: .isDirectory) }
    /// Catalog, holdings and price snapshots plus the conditional-response cache.
    var catalog: URL { root.appending(path: "Catalog", directoryHint: .isDirectory) }

    var all: [URL] { [root, sync, learning, catalog] }

    /// `Documents/Scans`: every batch's photos, records and verdicts. On the
    /// iPhone it is shared through the Files app; on the Mac it lives in the
    /// app's sandbox container.
    static var scans: URL {
        URL.documentsDirectory.appending(path: "Scans", directoryHint: .isDirectory)
    }

    /// The production location.
    static var live: AppPaths {
        AppPaths(root: URL.applicationSupportDirectory.appending(path: "Riftbound", directoryHint: .isDirectory))
    }

    /// Creates every directory and marks each excluded from backup. Safe to
    /// call on every launch; the flag is re-applied in case a restore lost it.
    @discardableResult
    func prepare(fileManager: FileManager = .default) throws -> AppPaths {
        for var directory in all {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return self
    }

    /// Bytes on disk under one of the directories, for the Settings storage line.
    func size(of directory: URL, fileManager: FileManager = .default) -> Int {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}
