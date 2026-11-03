import Foundation

@Observable
final class HistoryModel {
    private(set) var batches: Loadable<[ScanBatch], ScanProblem> = .idle
    private let store: any ScanStoring

    init(store: any ScanStoring) {
        self.store = store
    }

    func load() async {
        if case .loaded = batches {} else {
            batches = .loading
        }
        do {
            batches = .loaded(try await store.batches())
        } catch {
            batches = .failed(.storage(String(describing: error)))
        }
    }

    func delete(_ batch: ScanBatch) async {
        do {
            try await store.deleteBatch(batch.id)
            await load()
        } catch {
            batches = .failed(.storage(String(describing: error)))
        }
    }
}

@Observable
final class BatchDetailModel {
    let batch: ScanBatch
    private(set) var records: Loadable<[ScanRecord], ScanProblem> = .idle
    private(set) var archive: Loadable<URL, ScanProblem> = .idle
    private let store: any ScanStoring
    private let now: @Sendable () -> Date

    init(batch: ScanBatch, store: any ScanStoring, now: @escaping @Sendable () -> Date) {
        self.batch = batch
        self.store = store
        self.now = now
    }

    var summary: BatchSummary? {
        records.value.map { BatchSummary(records: $0) }
    }

    func load() async {
        records = .loading
        do {
            records = .loaded(try await store.records(in: batch.id).sorted { $0.capturedAt > $1.capturedAt })
        } catch {
            records = .failed(.storage(String(describing: error)))
        }
    }

    func update(_ record: ScanRecord, verdict: Verdict) async {
        var changed = record
        changed.verdict = verdict
        changed.verdictAt = now()
        do {
            try await store.update(changed)
            if var list = records.value, let position = list.firstIndex(where: { $0.id == record.id }) {
                list[position] = changed
                records = .loaded(list)
            }
        } catch {
            records = .failed(.storage(String(describing: error)))
        }
    }

    func prepareArchive() async {
        archive = .loading
        do {
            let name = "riftbound-scans-\(batch.id.rawValue.uuidString.prefix(8))"
            archive = .loaded(try await BatchArchiver.archive(store.batchDirectory(for: batch.id), named: name))
        } catch {
            archive = .failed(.storage(String(describing: error)))
        }
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    func rectifiedURL(for record: ScanRecord) -> URL? {
        store.rectifiedURL(for: record)
    }
}
