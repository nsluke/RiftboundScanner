import SwiftUI

struct HistoryView: View {
    let model: HistoryModel
    let store: any ScanStoring
    let directory: CardDirectory
    let index: IndexSummary
    let now: @Sendable () -> Date

    @State private var batchToDelete: ScanBatch?

    var body: some View {
        Group {
            switch model.batches {
            case .idle, .loading:
                ProgressView()
            case .failed(let problem):
                ContentUnavailableView {
                    Label("History unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            case .loaded(let batches):
                if batches.isEmpty {
                    ContentUnavailableView("No scans yet", systemImage: "tray", description: Text("Scans you review appear here, grouped by batch."))
                } else {
                    List {
                        ForEach(batches) { batch in
                            NavigationLink(value: batch) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(batch.displayName)
                                        .font(.headline)
                                    Text("\(batch.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(batch.device.model)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    batchToDelete = batch
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Section {
                            LabeledContent("Card index", value: "\(index.entryCount) printings, built \(index.builtAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.footnote)
                        }
                    }
                }
            }
        }
        .navigationTitle("History")
        .navigationDestination(for: ScanBatch.self) { batch in
            BatchDetailView(model: BatchDetailModel(batch: batch, store: store, now: now), directory: directory)
        }
        .task { await model.load() }
        .refreshable { await model.load() }
        .confirmationDialog("Delete this batch and its photos?", isPresented: isConfirmingDelete, presenting: batchToDelete) { batch in
            Button("Delete \(batch.displayName)", role: .destructive) {
                Task { await model.delete(batch) }
            }
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { batchToDelete != nil }, set: { if !$0 { batchToDelete = nil } })
    }
}

struct BatchDetailView: View {
    @State private var model: BatchDetailModel
    let directory: CardDirectory

    @State private var selectedRecord: ScanRecord?

    init(model: @autoclosure @escaping () -> BatchDetailModel, directory: CardDirectory) {
        _model = State(wrappedValue: model())
        self.directory = directory
    }

    var body: some View {
        List {
            if let summary = model.summary {
                Section("Summary") {
                    LabeledContent("Scans", value: summary.total.formatted())
                    LabeledContent("Correct", value: summary.correct.formatted())
                    LabeledContent("Corrected", value: summary.corrected.formatted())
                    LabeledContent("Rejected", value: summary.rejected.formatted())
                    if summary.pending > 0 {
                        LabeledContent("Pending", value: summary.pending.formatted())
                    }
                    LabeledContent("Top-1 accuracy", value: summary.topOneAccuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "No verdicts yet"))
                    LabeledContent("Top-3 accuracy", value: summary.topThreeAccuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? String(localized: "No verdicts yet"))
                }
                Section("Setup") {
                    LabeledContent("Device", value: "\(model.batch.device.model), \(model.batch.device.systemVersion)")
                    LabeledContent("App", value: model.batch.device.appVersion)
                    LabeledContent("Index", value: "\(model.batch.index.entryCount) printings, built \(model.batch.index.builtAt.formatted(date: .abbreviated, time: .omitted))")
                }
            }
            switch model.records {
            case .idle, .loading:
                ProgressView()
            case .failed(let problem):
                Text(problem.message)
            case .loaded(let records):
                Section("Scans") {
                    if records.isEmpty {
                        Text("No scans in this batch yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(records) { record in
                        Button {
                            selectedRecord = record
                        } label: {
                            RecordRow(record: record, thumbnailURL: model.photoURL(for: record), directory: directory)
                        }
                        .tint(.primary)
                    }
                }
            }
        }
        .navigationTitle(model.batch.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                switch model.archive {
                case .loaded(let url):
                    ShareLink(item: url) {
                        Label("Share archive", systemImage: "square.and.arrow.up")
                    }
                case .loading:
                    ProgressView()
                case .idle, .failed:
                    Button {
                        Task { await model.prepareArchive() }
                    } label: {
                        Label("Export", systemImage: "archivebox")
                    }
                }
            }
        }
        .task { await model.load() }
        .sheet(item: $selectedRecord) { record in
            StoredScanReview(record: record, model: model, directory: directory)
        }
    }
}

struct RecordRow: View {
    let record: ScanRecord
    let thumbnailURL: URL
    let directory: CardDirectory

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailImage(url: thumbnailURL, maxPixelSize: 160)
                .frame(width: 44, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.topCandidate?.card.displayName ?? String(localized: "No match"))
                    .font(.body)
                Text("\(record.topCandidate?.card.code.canonical ?? "") \(record.capturedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VerdictBadge(verdict: record.verdict, directory: directory)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Loads a stored scan's images, then reuses the review screen to change its verdict.
struct StoredScanReview: View {
    let record: ScanRecord
    let model: BatchDetailModel
    let directory: CardDirectory

    @Environment(\.dismiss) private var dismiss
    @State private var photo: CGImage?
    @State private var rectified: CGImage?

    var body: some View {
        ScanReviewView(
            record: record,
            photo: photo,
            rectified: rectified,
            directory: directory,
            onVerdict: { verdict in
                Task {
                    await model.update(record, verdict: verdict)
                    dismiss()
                }
            },
            onRetake: nil
        )
        .task {
            photo = await PhotoDecoder.thumbnail(at: model.photoURL(for: record), maxPixelSize: 1024)
            if let url = model.rectifiedURL(for: record) {
                rectified = await PhotoDecoder.thumbnail(at: url, maxPixelSize: 1024)
            }
        }
    }
}
