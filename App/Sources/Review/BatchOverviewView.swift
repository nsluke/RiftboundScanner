import SwiftUI

/// Every scan in a batch, grouped by what it still needs: the "All scans"
/// side of `BatchReviewView`. The to-review scans lead; the ones confirmed
/// automatically sit folded away for spot-checks. A scan opens in the same
/// one-at-a-time view the queue uses (`ReviewRoute.scans`).
struct BatchOverviewView: View {
    /// What needs a look is the other side of the batch's screen, so the
    /// filters here only slice what is already there.
    enum Filter: Hashable, CaseIterable {
        case all, confirmedAutomatically, corrected, rejected

        func label(counts: Counts) -> String {
            switch self {
            case .all: String(localized: "All · \(counts.all)")
            case .confirmedAutomatically: String(localized: "Confirmed automatically · \(counts.confirmedAutomatically)")
            case .corrected: String(localized: "Corrected · \(counts.corrected)")
            case .rejected: String(localized: "Rejected · \(counts.rejected)")
            }
        }
    }

    struct Counts: Hashable {
        var toReview = 0
        var all = 0
        var corrected = 0
        var rejected = 0
        var confirmedAutomatically = 0
        var confirmed = 0

        init(records: [ScanRecord]) {
            all = records.count
            for record in records {
                if record.needsReview { toReview += 1 }
                if record.isAutoConfirmable { confirmedAutomatically += 1 }
                switch record.verdict {
                case .correct: confirmed += 1
                case .corrected: corrected += 1
                case .rejected: rejected += 1
                case .pending, .voided: break
                }
            }
        }
    }

    @State private var model: BatchDetailModel
    let directory: CardDirectory
    /// Switches the batch's screen to what still needs a look.
    let onReview: () -> Void

    @Environment(SyncEngine.self) private var sync: SyncEngine?
    @Environment(\.dismiss) private var dismiss
    @State private var filter: Filter = .all
    @State private var isConfirmingVoid = false

    init(model: @autoclosure @escaping () -> BatchDetailModel, directory: CardDirectory, onReview: @escaping () -> Void) {
        _model = State(wrappedValue: model())
        self.directory = directory
        self.onReview = onReview
    }

    #if os(macOS)
    // A window is wide: as many thumbnails per row as fit, not the phone's three and five.
    private let reviewColumns = [GridItem(.adaptive(minimum: 112), spacing: 12)]
    private let confidentColumns = [GridItem(.adaptive(minimum: 64), spacing: 8)]
    #else
    private let reviewColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let confidentColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)
    #endif

    var body: some View {
        Group {
            switch model.records {
            case .idle, .loading:
                ProgressView().tint(Theme.text)
            case .failed(let problem):
                ContentUnavailableView {
                    Label("Couldn't load the batch", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(problem.message)
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
                }
            case .loaded(let records):
                content(records.sorted { $0.capturedAt < $1.capturedAt })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle(model.batch.displayName)
        .inlineNavigationTitle()
        .darkNavigationBar()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                exportButton
            }
            if sync != nil {
                ToolbarItem(placement: .secondaryAction) {
                    batchMenu
                }
            }
        }
        .task { await model.load() }
        .confirmationDialog("Void this batch?", isPresented: $isConfirmingVoid) {
            Button("Void \(model.batch.displayName)", role: .destructive) {
                Task {
                    await model.void()
                    dismiss()
                }
            }
        } message: {
            Text("Every card it added to the collection is taken back out. The batch disappears once the server has confirmed each undo.")
        }
    }

    // MARK: - Content

    private func content(_ records: [ScanRecord]) -> some View {
        let counts = Counts(records: records)
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                filterChips(counts: counts)
                if records.isEmpty {
                    ContentUnavailableView("No scans in this batch yet", systemImage: "tray")
                } else {
                    switch filter {
                    case .confirmedAutomatically:
                        confirmedAutomatically(records.filter(\.isAutoConfirmable))
                    case .all:
                        grid(records, columns: reviewColumns, width: 96, showsReason: true, emptyText: "")
                    case .corrected:
                        grid(records.filter { if case .corrected = $0.verdict { true } else { false } }, columns: reviewColumns, width: 96, showsReason: false, emptyText: String(localized: "Nothing has been corrected."))
                    case .rejected:
                        grid(records.filter { if case .rejected = $0.verdict { true } else { false } }, columns: reviewColumns, width: 96, showsReason: false, emptyText: String(localized: "Nothing has been rejected."))
                    }
                }
                if counts.toReview > 0 {
                    exportFootnote(counts.toReview)
                }
                if let sync, let syncSummary = sync.summary(for: model.batch.id) {
                    SyncSection(summary: syncSummary, status: sync.status, records: records, photoURL: model.photoURL(for:)) { attention in
                        ReviewRoute.scans(model.batch, ids: [attention.scanID], start: attention.scanID)
                    } retry: {
                        Task { await sync.retryNow() }
                    }
                }
                summary
            }
            .padding()
            .padding(.bottom, counts.toReview > 0 ? 72 : 0)
        }
        .safeAreaInset(edge: .bottom) {
            if counts.toReview > 0 {
                Button(action: onReview) {
                    Text("Review the \(counts.toReview)")
                        .frame(maxWidth: .infinity)
                }
                .prominentAction(Theme.amber)
                .controlSize(.large)
                .padding()
                .background(Theme.ground.opacity(0.95))
            }
        }
    }

    private func filterChips(counts: Counts) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Filter.allCases, id: \.self) { candidate in
                    Button {
                        filter = candidate
                    } label: {
                        Text(candidate.label(counts: counts))
                            .font(.footnote.weight(.medium))
                            .padding(.horizontal, 12)
                            .frame(minHeight: 32)
                            .background(filter == candidate ? Theme.amber : Theme.surface, in: Capsule())
                            .foregroundStyle(filter == candidate ? Theme.ground : Theme.text)
                    }
                    .accessibilityAddTraits(filter == candidate ? .isSelected : [])
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    /// The scans accepted without a look, and a way to re-check one of them.
    @ViewBuilder
    private func confirmedAutomatically(_ records: [ScanRecord]) -> some View {
        grid(records, columns: confidentColumns, width: 56, showsReason: false, emptyText: String(localized: "Nothing was confirmed automatically."))
        if let sample = records.randomElement() {
            NavigationLink(value: ReviewRoute.scans(model.batch, ids: [sample.id], start: sample.id)) {
                Label("Spot-check one", systemImage: "eye")
            }
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.blue)
            .accessibilityHint("Opens one confident scan to check it")
        }
    }

    @ViewBuilder
    private func grid(_ records: [ScanRecord], columns: [GridItem], width: CGFloat, showsReason: Bool, emptyText: String) -> some View {
        if records.isEmpty {
            Text(emptyText)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        } else {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(records) { record in
                    NavigationLink(value: ReviewRoute.scans(model.batch, ids: records.map(\.id), start: record.id)) {
                        VStack(spacing: 4) {
                            ScanThumbnail(record: record, url: model.photoURL(for: record), width: width, showsReason: showsReason)
                            if width >= 96 {
                                Text(record.topCandidate?.card.displayName ?? String(localized: "No match"))
                                    .font(.caption2)
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityHint("Opens this scan")
                }
            }
        }
    }

    private func exportFootnote(_ pending: Int) -> some View {
        Text("\(pending) scans still need a look. You can export now, but they will be missing from the card list and pending in the archive.")
            .font(.footnote)
            .foregroundStyle(Theme.muted)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let summary = model.summary {
                Text("Top-1 \(summary.topOneAccuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–") · Top-3 \(summary.topThreeAccuracy.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "–") on \(summary.judged) judged")
            }
            Text("\(model.batch.device.model), \(model.batch.device.systemVersion) · app \(model.batch.device.appVersion) · index of \(model.batch.index.entryCount)")
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var exportButton: some View {
        switch model.share {
        case .loaded(let file):
            ShareLink(item: file.url) {
                Label("Share \(file.kind.label)", systemImage: "square.and.arrow.up")
            }
            .accessibilityHint("Shares the prepared file")
        case .loading:
            ProgressView()
        case .idle, .failed:
            Menu {
                Section("Confirmed cards") {
                    ForEach(CollectionExporter.Format.allCases, id: \.self) { format in
                        Button {
                            Task { await model.prepareShare(.cards(format)) }
                        } label: {
                            Label(format.label, systemImage: format == .csv ? "tablecells" : "list.bullet")
                        }
                    }
                    .disabled(model.cardExport?.lines.isEmpty ?? true)
                }
                Section {
                    Button {
                        Task { await model.prepareShare(.archive) }
                    } label: {
                        Label("Full archive (zip)", systemImage: "archivebox")
                    }
                }
                if let export = model.cardExport {
                    Section {
                        Text(exportSummary(export))
                    }
                }
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
            }
        }
    }

    @ViewBuilder
    private var batchMenu: some View {
        let summary = sync?.summary(for: model.batch.id)
        Menu {
            if model.batch.purpose == .collection, summary?.isClosed != true {
                Button {
                    Task { await sync?.closeBatch(model.batch.id) }
                } label: {
                    Label("Close batch", systemImage: "lock")
                }
            }
            if model.batch.purpose == .collection, summary?.voiding == nil {
                Button(role: .destructive) {
                    isConfirmingVoid = true
                } label: {
                    Label("Void batch…", systemImage: "arrow.uturn.backward")
                }
            }
            Button {
                Task { await sync?.retryNow() }
            } label: {
                Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
            }
        } label: {
            Label("Batch", systemImage: "ellipsis.circle")
        }
    }

    private func exportSummary(_ export: CollectionExporter.Export) -> String {
        var parts = [String(localized: "\(export.totalCards) cards confirmed")]
        if export.pending > 0 { parts.append(String(localized: "\(export.pending) pending left out")) }
        if export.rejected > 0 { parts.append(String(localized: "\(export.rejected) rejected left out")) }
        return parts.joined(separator: " · ")
    }
}


/// The sync line for one batch: what the ledger holds, what is still owed,
/// and every terminal outcome that needs the user (ADR-002, principle 2).
struct SyncSection: View {
    let summary: BatchSyncSummary
    let status: SyncEngine.Status
    let records: [ScanRecord]
    let photoURL: (ScanRecord) -> URL
    /// Where a row that needs the user opens its scan.
    let route: (SyncAttention) -> ReviewRoute
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // One row while it fits; the button drops below the headline at
            // accessibility text sizes instead of leaving the screen. The
            // headline is one VoiceOver element and the button its own, so
            // "Retry now" stays activatable.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    headlineLabel
                    Spacer()
                    retryButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    headlineLabel
                    retryButton
                }
            }
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            ForEach(summary.attention) { attention in
                NavigationLink(value: route(attention)) {
                    HStack(alignment: .top, spacing: 10) {
                        if let record = records.first(where: { $0.id == attention.scanID }) {
                            ScanThumbnail(record: record, url: photoURL(record), width: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(records.first { $0.id == attention.scanID }?.topCandidate?.card.displayName ?? String(localized: "Scan"))
                                .font(.footnote.weight(.medium))
                            Text(attention.message)
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .accessibilityHint("Opens this scan")
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private var headlineLabel: some View {
        Label {
            Text(headline)
                .font(.subheadline.weight(.medium))
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var retryButton: some View {
        if showsRetry {
            Button("Retry now", action: retry)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.blue)
                .accessibilityHint("Looks for the server again and sends what is waiting")
        }
    }

    private var headline: String {
        switch summary.voiding {
        case .inProgress(let remaining): return String(localized: "Voiding · \(remaining) left to send")
        case .complete(let rejected): return String(localized: "Voided · \(rejected) undos refused")
        case nil: break
        }
        if !summary.isSettled {
            return String(localized: "\(summary.queuedItems) ledger items and \(summary.pendingUploads) uploads waiting")
        }
        if summary.appliedItems > 0 {
            return String(localized: "Synced · \(summary.appliedItems) in the ledger")
        }
        return summary.isClosed ? String(localized: "Closed · nothing to sync") : String(localized: "Nothing to sync")
    }

    private var detail: String? {
        var parts: [String] = []
        switch status {
        case .idle, .syncing: break
        case .offline, .waiting, .failed: parts.append(status.message)
        }
        if summary.failedUploads > 0 { parts.append(String(localized: "\(summary.failedUploads) uploads failed; retried next time.")) }
        if !summary.attention.isEmpty { parts.append(String(localized: "\(summary.attention.count) items need a look.")) }
        if case .complete(let rejected) = summary.voiding, rejected > 0 {
            parts.append(String(localized: "Resolve the refused undos on the web, then delete the batch."))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var showsRetry: Bool {
        switch status {
        case .offline, .waiting, .failed: true
        case .idle, .syncing: !summary.isSettled
        }
    }

    private var icon: String {
        if summary.voiding != nil { return "arrow.uturn.backward.circle" }
        if !summary.attention.isEmpty { return "exclamationmark.triangle" }
        if case .syncing = status { return "arrow.triangle.2.circlepath" }
        return summary.isSettled ? "checkmark.icloud" : "icloud.and.arrow.up"
    }

    private var tint: Color {
        if !summary.attention.isEmpty { return .red }
        if summary.voiding != nil || !summary.isSettled { return Theme.amber }
        return Theme.blue
    }
}
