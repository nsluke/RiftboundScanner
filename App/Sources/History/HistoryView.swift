import SwiftUI

struct HistoryView: View {
    let model: HistoryModel
    let store: any ScanStoring
    let directory: CardDirectory
    let index: IndexSummary
    /// The installed confident tier, for the review queue pushed from here.
    let rule: @Sendable () -> ConfidenceRule

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
            BatchOverviewView(model: BatchDetailModel(batch: batch, store: store, directory: directory), directory: directory)
        }
        .reviewDestinations(store: store, directory: directory, rule: rule)
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
