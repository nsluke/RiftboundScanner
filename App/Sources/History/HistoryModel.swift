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
    /// What the batch can be shared as.
    enum ShareKind: Hashable {
        /// The whole batch folder: photos, records, batch metadata.
        case archive
        /// The confirmed cards as a list other programs import.
        case cards(CollectionExporter.Format)

        var label: String {
            switch self {
            case .archive: String(localized: "Full archive (zip)")
            case .cards(let format): format.label
            }
        }
    }

    struct ShareFile: Hashable {
        let kind: ShareKind
        let url: URL
    }

    let batch: ScanBatch
    let directory: CardDirectory
    private(set) var records: Loadable<[ScanRecord], ScanProblem> = .idle
    private(set) var share: Loadable<ShareFile, ScanProblem> = .idle
    private let store: any ScanStoring

    init(batch: ScanBatch, store: any ScanStoring, directory: CardDirectory) {
        self.batch = batch
        self.store = store
        self.directory = directory
    }

    /// The confirmed cards and what the list leaves out, once records are loaded.
    var cardExport: CollectionExporter.Export? {
        records.value.map { CollectionExporter.export($0, directory: directory) }
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

    /// Re-judging a stored scan is a `human` decision appended by the store;
    /// the copy shown here may be behind, and the store's answer replaces it.
    func update(_ record: ScanRecord, verdict: Verdict) async {
        do {
            let decided = try await store.decide(record.id, in: batch.id, DecisionInput(verdict, source: .human))
            if var list = records.value, let position = list.firstIndex(where: { $0.id == record.id }) {
                list[position] = decided
                records = .loaded(list)
            }
            resetShare()
        } catch {
            records = .failed(.storage(String(describing: error)))
        }
    }

    func prepareShare(_ kind: ShareKind) async {
        share = .loading
        let name = "riftbound-scans-\(batch.id.rawValue.uuidString.prefix(8))"
        do {
            switch kind {
            case .archive:
                share = .loaded(ShareFile(kind: kind, url: try await BatchArchiver.archive(store.batchDirectory(for: batch.id), named: name)))
            case .cards(let format):
                guard let cardExport else { return }
                share = .loaded(ShareFile(kind: kind, url: try await CollectionExporter.write(cardExport, as: format, named: name)))
            }
        } catch {
            share = .failed(.storage(String(describing: error)))
        }
    }

    /// Forgets a prepared file, e.g. after a verdict changes what it would hold.
    func resetShare() {
        share = .idle
    }

    func photoURL(for record: ScanRecord) -> URL {
        store.photoURL(for: record)
    }

    func rectifiedURL(for record: ScanRecord) -> URL? {
        store.rectifiedURL(for: record)
    }
}
