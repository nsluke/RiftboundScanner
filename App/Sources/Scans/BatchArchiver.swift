import Foundation

/// Zips a batch folder for the share sheet. `NSFileCoordinator`'s upload option
/// produces the archive, so no compression library is needed.
nonisolated enum BatchArchiver {
    enum Failure: Error {
        case coordination(String)
    }

    @concurrent
    static func archive(_ directory: URL, named name: String) async throws -> URL {
        let destination = URL.temporaryDirectory.appending(path: "\(name).zip")
        let fileManager = FileManager()
        try? fileManager.removeItem(at: destination)
        var coordinationError: NSError?
        var copyError: (any Error)?
        NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: directory, options: .forUploading, error: &coordinationError) { zipped in
            do {
                try fileManager.copyItem(at: zipped, to: destination)
            } catch {
                copyError = error
            }
        }
        if let coordinationError { throw Failure.coordination(coordinationError.localizedDescription) }
        if let copyError { throw copyError }
        return destination
    }
}
