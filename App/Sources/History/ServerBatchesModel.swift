import Foundation

/// The batches other devices put on the server that are not on this device,
/// and importing one so it can be reviewed here (ADR-003). The Mac shows
/// them in History under "On the server"; the iPhone does not offer them.
@Observable
final class ServerBatchesModel {
    /// Where one server batch stands on this device.
    enum ImportState: Hashable {
        case importing(done: Int, of: Int)
        case imported(ServerBatchImporter.Outcome)
        case failed(String)
    }

    /// Server batches with scans that this device does not hold.
    private(set) var batches: Loadable<[ServerScanBatch], ServerError> = .idle
    private(set) var imports: [ServerScanBatch.ID: ImportState] = [:]

    private let server: any ServerScanReading
    private let importer: ServerBatchImporter

    init(server: any ServerScanReading, importer: ServerBatchImporter) {
        self.server = server
        self.importer = importer
    }

    /// Lists the server's batches, leaving out the ones `local` already has
    /// (a batch imported earlier, or scanned here) and empty ones.
    func load(excluding local: Set<ScanBatch.ID>) async {
        if case .loaded = batches {} else {
            batches = .loading
        }
        do {
            let all = try await server.scanBatches()
            batches = .loaded(all.filter { $0.scanCount > 0 && (!local.contains(ScanBatch.ID(rawValue: $0.id)) || imports[$0.id] != nil) })
        } catch {
            batches = .failed(error)
        }
    }

    /// Copies the batch here. The outcome is also kept in `imports`, so the
    /// row can offer the review that follows.
    @discardableResult
    func importBatch(_ remote: ServerScanBatch) async -> ServerBatchImporter.Outcome? {
        if case .importing = imports[remote.id] { return nil }
        imports[remote.id] = .importing(done: 0, of: remote.scanCount)
        do {
            let outcome = try await importer.importBatch(remote) { done, total in
                await self.report(remote.id, done: done, of: total)
            }
            imports[remote.id] = .imported(outcome)
            return outcome
        } catch let error as ServerError {
            imports[remote.id] = .failed(error.message)
        } catch {
            imports[remote.id] = .failed(ScanProblem(error).message)
        }
        return nil
    }

    private func report(_ id: ServerScanBatch.ID, done: Int, of total: Int) {
        if case .importing = imports[id] {
            imports[id] = .importing(done: done, of: total)
        }
    }
}
