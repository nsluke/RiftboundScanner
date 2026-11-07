import SwiftUI

struct HistoryView: View {
    let model: HistoryModel
    let store: any ScanStoring
    let directory: CardDirectory
    let index: IndexSummary
    /// The installed confident tier, for the review queue pushed from here.
    let rule: @Sendable () -> ConfidenceRule

    @Environment(SyncEngine.self) private var sync: SyncEngine?
    @State private var batchToDelete: ScanBatch?
    @State private var batchToVoid: ScanBatch?

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
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(batch.displayName)
                                        .font(.headline)
                                    Text("\(batch.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(batch.device.model)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    BatchBadges(batch: batch, summary: sync?.summary(for: batch.id))
                                }
                                .accessibilityElement(children: .combine)
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    batchToDelete = batch
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                if batch.purpose == .collection, sync?.summary(for: batch.id)?.voiding == nil {
                                    Button {
                                        batchToVoid = batch
                                    } label: {
                                        Label("Void", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.orange)
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
        .confirmationDialog("Void this batch?", isPresented: isConfirmingVoid, presenting: batchToVoid) { batch in
            Button("Void \(batch.displayName)", role: .destructive) {
                Task { await model.void(batch) }
            }
        } message: { _ in
            Text("Every card it added to the collection is taken back out. The batch disappears once the server has confirmed each undo.")
        }
    }

    private var isConfirmingDelete: Binding<Bool> {
        Binding(get: { batchToDelete != nil }, set: { if !$0 { batchToDelete = nil } })
    }

    private var isConfirmingVoid: Binding<Bool> {
        Binding(get: { batchToVoid != nil }, set: { if !$0 { batchToVoid = nil } })
    }
}

/// The purpose and sync state of a batch, as small capsules.
struct BatchBadges: View {
    let batch: ScanBatch
    let summary: BatchSyncSummary?

    var body: some View {
        // Side by side while they fit; stacked at accessibility text sizes.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { badges }
            VStack(alignment: .leading, spacing: 4) { badges }
        }
        .accessibilityLabel(accessibilityText)
    }

    @ViewBuilder
    private var badges: some View {
        badge(purposeLabel, color: batch.purpose == .collection ? .blue : .secondary)
        if let summary {
            badge(syncLabel(summary), color: syncColor(summary))
        }
    }

    private var purposeLabel: String {
        switch batch.purpose {
        case .collection: String(localized: "Collection")
        case .calibration: String(localized: "Calibration")
        }
    }

    private func syncLabel(_ summary: BatchSyncSummary) -> String {
        switch summary.voiding {
        case .inProgress(let remaining): return String(localized: "Voiding · \(remaining) left")
        case .complete(let rejected): return String(localized: "Voided · \(rejected) undos refused")
        case nil: break
        }
        if !summary.attention.isEmpty { return String(localized: "Needs attention · \(summary.attention.count)") }
        if !summary.isSettled { return String(localized: "\(summary.queuedItems + summary.pendingUploads) to sync") }
        if summary.isClosed { return String(localized: "Closed · synced") }
        return String(localized: "Synced")
    }

    private func syncColor(_ summary: BatchSyncSummary) -> Color {
        if summary.voiding != nil { return .orange }
        if !summary.attention.isEmpty { return .red }
        if !summary.isSettled { return .orange }
        return .green
    }

    private var accessibilityText: String {
        [purposeLabel, summary.map(syncLabel)].compactMap { $0 }.joined(separator: ", ")
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
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
