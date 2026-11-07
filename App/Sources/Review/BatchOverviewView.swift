import SwiftUI

/// Every scan in a batch, grouped by what it still needs. The to-review scans
/// lead; the ones confirmed automatically sit folded away for spot-checks.
struct BatchOverviewView: View {
    enum Filter: Hashable, CaseIterable {
        case toReview, all, corrected, rejected

        func label(counts: Counts) -> String {
            switch self {
            case .toReview: String(localized: "To review · \(counts.toReview)")
            case .all: String(localized: "All · \(counts.all)")
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
                case .pending: break
                }
            }
        }
    }

    @State private var model: BatchDetailModel
    let directory: CardDirectory

    @State private var filter: Filter = .toReview
    @State private var isShowingConfident = false
    @State private var selectedRecord: ScanRecord?

    init(model: @autoclosure @escaping () -> BatchDetailModel, directory: CardDirectory) {
        _model = State(wrappedValue: model())
        self.directory = directory
    }

    private let reviewColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    private let confidentColumns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                exportButton
            }
        }
        .task { await model.load() }
        .sheet(item: $selectedRecord) { record in
            StoredScanReview(record: record, model: model, directory: directory)
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
                    case .toReview:
                        toReviewSection(records.filter(\.needsReview), counts: counts)
                        confirmedSection(records.filter { $0.isAutoConfirmable || $0.verdict == .correct }, counts: counts)
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
                summary
            }
            .padding()
            .padding(.bottom, counts.toReview > 0 ? 72 : 0)
        }
        .safeAreaInset(edge: .bottom) {
            if counts.toReview > 0 {
                NavigationLink(value: ReviewRoute.queue(model.batch)) {
                    Text("Review the \(counts.toReview)")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
                .foregroundStyle(Theme.ground)
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

    @ViewBuilder
    private func toReviewSection(_ records: [ScanRecord], counts: Counts) -> some View {
        if records.isEmpty {
            Label("Nothing left to review", systemImage: "checkmark.seal")
                .font(.subheadline)
                .foregroundStyle(Theme.blue)
        } else {
            grid(records, columns: reviewColumns, width: 96, showsReason: true, emptyText: "")
        }
    }

    @ViewBuilder
    private func confirmedSection(_ records: [ScanRecord], counts: Counts) -> some View {
        if !records.isEmpty {
            DisclosureGroup(isExpanded: $isShowingConfident) {
                VStack(alignment: .leading, spacing: 10) {
                    grid(records, columns: confidentColumns, width: 56, showsReason: false, emptyText: "")
                    if let sample = records.filter(\.isAutoConfirmable).randomElement() {
                        Button {
                            selectedRecord = sample
                        } label: {
                            Label("Spot-check one", systemImage: "eye")
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.blue)
                        .accessibilityHint("Opens one confident scan to check it")
                    }
                }
                .padding(.top, 8)
            } label: {
                Text("Confirmed automatically · \(records.count)")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.muted)
            }
            .tint(Theme.muted)
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
                    Button {
                        selectedRecord = record
                    } label: {
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

    private func exportSummary(_ export: CollectionExporter.Export) -> String {
        var parts = [String(localized: "\(export.totalCards) cards confirmed")]
        if export.pending > 0 { parts.append(String(localized: "\(export.pending) pending left out")) }
        if export.rejected > 0 { parts.append(String(localized: "\(export.rejected) rejected left out")) }
        return parts.joined(separator: " · ")
    }
}
