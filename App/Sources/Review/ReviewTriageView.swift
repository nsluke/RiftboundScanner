import RiftboundRecognizer
import SwiftUI

/// The Mac's "To review" in `BatchReviewView`: the uncertain
/// scans in a grid, each beside its match, with the focused pair large on the
/// right. Click a tile or press X to flag it wrong, ⌥F to mark it foil, then
/// ⌘↩ confirms the rest; the flagged ones and anything the grid leaves out
/// continue one at a time in `ReviewQueueView`.
struct ReviewTriageView: View {
    @State private var model: ReviewTriageModel
    /// Builds the queue that follows, given the flagged scans.
    let makeQueue: (Set<ScanRecord.ID>) -> ReviewQueueModel

    @Environment(\.dismiss) private var dismiss
    @State private var stage = Stage.grid
    @State private var columns = 4
    @FocusState private var isGridFocused: Bool

    /// Where the screen is: the grid, then the queue it hands over to.
    private enum Stage {
        case grid
        case queue(ReviewQueueModel)
        case finished(confirmed: Int)
    }

    init(model: @autoclosure @escaping () -> ReviewTriageModel, makeQueue: @escaping (Set<ScanRecord.ID>) -> ReviewQueueModel) {
        _model = State(wrappedValue: model())
        self.makeQueue = makeQueue
    }

    var body: some View {
        Group {
            switch stage {
            case .grid:
                gridStage
            case .queue(let queue):
                ReviewQueueView(model: queue)
            case .finished(let confirmed):
                finished(confirmed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .task { await model.load() }
        .onChange(of: model.phase) { _, phase in
            if case .confirmed(let count) = phase {
                handOver(confirmed: count)
            }
        }
    }

    @ViewBuilder
    private var gridStage: some View {
        switch model.tiles {
        case .idle, .loading:
            ProgressView().tint(Theme.text)
        case .failed(let problem):
            ContentUnavailableView {
                Label("Couldn't load the batch", systemImage: "exclamationmark.triangle")
            } description: {
                Text(problem.message)
            } actions: {
                Button("Try again") { Task { await model.load() } }
                    .prominentAction(Theme.amber)
            }
        case .loaded(let records):
            if records.isEmpty {
                // Nothing for a grid: whatever needs a look goes one at a time.
                Color.clear.onAppear { stage = .queue(makeQueue([])) }
            } else {
                triage(records)
            }
        }
    }

    private func triage(_ records: [ScanRecord]) -> some View {
        VStack(spacing: 0) {
            header(count: records.count)
            Divider().overlay(Theme.hairline)
            HStack(spacing: 0) {
                grid(records)
                Divider().overlay(Theme.hairline)
                preview
                    .frame(width: 360)
            }
            Divider().overlay(Theme.hairline)
            footer
        }
        .navigationTitle("Review")
        .alert("Couldn't save", isPresented: isShowingStorageProblem, presenting: model.storageProblem) { _ in
            Button("OK") { model.dismissStorageProblem() }
        } message: { problem in
            Text("\(problem.message) The cards confirmed so far are saved; the rest are still here.")
        }
        .overlay {
            if case .confirming(let done, let total) = model.phase {
                ProgressView("Confirming \(done) of \(total)…")
                    .padding(24)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    // MARK: - Header and footer

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(count) to check")
                    .font(.title3.weight(.semibold))
                Text(model.batch.label.isEmpty ? model.batch.startedAt.formatted(date: .abbreviated, time: .shortened) : model.batch.label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button("Review one at a time") { stage = .queue(makeQueue(model.flagged)) }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.blue)
            }
            Text("Every match is presumed right. Flag the wrong ones, then confirm the rest.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            CalibrationNotice(batch: model.batch)
        }
        .padding(16)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(footerCounts)
                .font(.subheadline.monospacedDigit())
            Text("Click or X flags · arrows move · ⌥F marks foil · ⌫ deletes · ⌘↩ confirms")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Spacer()
            Button(confirmTitle) {
                Task { await model.confirmUnflagged() }
            }
            .prominentAction(Theme.blue)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.phase != .triaging)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footerCounts: String {
        var parts = [String(localized: "\(model.unflaggedCount) look right"), String(localized: "\(model.flagged.count) flagged")]
        if model.deletedCount > 0 {
            parts.append(String(localized: "\(model.deletedCount) deleted"))
        }
        if model.leftForQueue > 0 {
            parts.append(String(localized: "\(model.leftForQueue) more after, one at a time"))
        }
        return parts.joined(separator: " · ")
    }

    private var confirmTitle: String {
        model.unflaggedCount > 0
            ? String(localized: "Confirm \(model.unflaggedCount)")
            : String(localized: "Fix the \(model.flagged.count) flagged")
    }

    // MARK: - Grid

    private static let tileWidth: CGFloat = 156
    private static let spacing: CGFloat = 12

    private func grid(_ records: [ScanRecord]) -> some View {
        GeometryReader { proxy in
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columns), spacing: Self.spacing) {
                        ForEach(records) { record in
                            tile(record)
                                .id(record.id)
                        }
                    }
                    .padding(16)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($isGridFocused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    let move: ReviewTriageModel.Move = switch press.key {
                    case .leftArrow: .left
                    case .rightArrow: .right
                    case .upArrow: .up
                    default: .down
                    }
                    model.moveFocus(move, columns: columns)
                    return .handled
                }
                .onChange(of: model.focusedID) { _, id in
                    if let id {
                        withAnimation(.snappy) { scroller.scrollTo(id) }
                    }
                }
            }
            .onAppear { columns = Self.columns(for: proxy.size.width) }
            .onChange(of: proxy.size.width) { _, width in columns = Self.columns(for: width) }
        }
        .onAppear { isGridFocused = true }
    }

    private static func columns(for width: CGFloat) -> Int {
        max(1, Int((width - 32 + spacing) / (tileWidth + spacing)))
    }

    private func tile(_ record: ScanRecord) -> some View {
        let isFlagged = model.isFlagged(record)
        let isFocused = model.focusedID == record.id
        let name = record.topCandidate?.card.displayName ?? String(localized: "No match")
        return Button {
            model.focusedID = record.id
            model.toggleFlag(record.id)
            isGridFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ThumbnailImage(url: model.photoURL(for: record), maxPixelSize: 360)
                        .aspectRatio(63 / 88, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    matchArt(record)
                }
                HStack(spacing: 4) {
                    Text(name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if marksFoil(record) {
                        Text("Foil")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.blue)
                    }
                    if isFlagged {
                        Text("Wrong")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.wrong)
                    }
                }
            }
            .padding(6)
            .background(isFlagged ? Theme.wrong.opacity(0.12) : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isFlagged ? Theme.wrong : Theme.hairline, lineWidth: isFlagged ? 2 : 1))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(isFocused ? Theme.amber : .clear, lineWidth: 2).padding(-3))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel(tileLabel(record, name: name, isFlagged: isFlagged))
        .accessibilityHint(isFlagged ? "Unflags this match" : "Flags this match as wrong")
        .accessibilityAddTraits(isFlagged ? [.isSelected] : [])
        .accessibilityActions {
            if model.asksForFinish(record) {
                Button(marksFoil(record) ? "Mark normal" : "Mark foil") { model.toggleFoil(record.id) }
            }
            Button("Delete scan") { Task { await model.delete(record.id) } }
        }
        .contextMenu {
            Button("Delete scan", systemImage: "trash", role: .destructive) {
                Task { await model.delete(record.id) }
            }
        }
    }

    /// Foil only where it is a choice: a foil-only printing (rares and up)
    /// is foil whatever the grid says, so labelling it is noise.
    private func marksFoil(_ record: ScanRecord) -> Bool {
        model.asksForFinish(record) && model.finish(of: record) == .foil
    }

    private func tileLabel(_ record: ScanRecord, name: String, isFlagged: Bool) -> String {
        var parts = [String(localized: "Matched as \(name)"), isFlagged ? String(localized: "flagged as wrong") : String(localized: "looks right")]
        if marksFoil(record) {
            parts.append(String(localized: "foil"))
        }
        return parts.joined(separator: ", ")
    }

    private func matchArt(_ record: ScanRecord) -> some View {
        GeometryReader { proxy in
            CardArtView(url: record.topCandidate?.card.imageURL, size: proxy.size, orientation: record.topCandidate?.card.orientation ?? .portrait)
        }
        .aspectRatio(63 / 88, contentMode: .fit)
    }

    // MARK: - Preview

    @ViewBuilder
    private var preview: some View {
        if let record = model.focused {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(spacing: 4) {
                            ThumbnailImage(url: model.photoURL(for: record), maxPixelSize: 900)
                                .aspectRatio(63 / 88, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.amber, lineWidth: 1.5))
                                .accessibilityLabel("The scanned card")
                            Text("Scanned").font(.caption).foregroundStyle(Theme.muted)
                        }
                        VStack(spacing: 4) {
                            matchArt(record)
                                .accessibilityLabel("The matched card")
                            Text("Matched").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    if let card = record.topCandidate?.card {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.displayName)
                                .font(.headline)
                            Text("\(card.code.canonical) · \(card.setName) · \(card.rarity.label)")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    if let doubt = model.doubt(about: record) {
                        Label(doubt, systemImage: "questionmark.circle")
                            .font(.caption)
                            .foregroundStyle(Theme.amber)
                    }
                    previewActions(record)
                }
                .padding(16)
            }
        } else {
            ContentUnavailableView("Pick a scan", systemImage: "square.grid.3x3", description: Text("Its photo and match show here, large."))
        }
    }

    private func previewActions(_ record: ScanRecord) -> some View {
        let isFlagged = model.isFlagged(record)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                model.toggleFlag(record.id)
            } label: {
                Label(isFlagged ? "Flagged as wrong" : "Wrong card", systemImage: isFlagged ? "xmark.circle.fill" : "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(isFlagged ? Theme.wrong : nil)
            .controlSize(.large)
            .keyboardShortcut("x", modifiers: [])
            .accessibilityHint(isFlagged ? "Unflags this match" : "Sends this scan to the fix panel after the rest are confirmed")
            Button(role: .destructive) {
                Task { await model.delete(record.id) }
            } label: {
                Label("Delete scan", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .keyboardShortcut(ReviewKey.delete)
            .accessibilityHint("Takes this scan out of the batch")
            if model.asksForFinish(record) {
                Picker("Finish", selection: Binding(
                    get: { model.finish(of: record) ?? .normal },
                    set: { if $0 != model.finish(of: record) { model.toggleFoil(record.id) } }
                )) {
                    ForEach(Finish.allCases, id: \.self) { finish in
                        Text(finish.label).tag(finish)
                    }
                }
                .pickerStyle(.segmented)
                Button("Toggle foil") { model.toggleFoil(record.id) }
                    .keyboardShortcut("f", modifiers: .option)
                    .hidden()
                    .frame(height: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - After the grid

    private func handOver(confirmed: Int) {
        if model.flagged.isEmpty && model.leftForQueue == 0 {
            stage = .finished(confirmed: confirmed)
        } else {
            stage = .queue(makeQueue(model.flagged))
        }
    }

    private func finished(_ confirmed: Int) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.blue)
                .accessibilityHidden(true)
            Text("Review complete")
                .font(.title2.weight(.semibold))
            Text("\(confirmed) confirmed. Nothing else in this batch needs a look.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Button("Back") { dismiss() }
                .prominentAction(Theme.amber)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding()
    }

    private var isShowingStorageProblem: Binding<Bool> {
        Binding(get: { model.storageProblem != nil }, set: { if !$0 { model.dismissStorageProblem() } })
    }
}

/// Says where the decisions go when they will not reach the collection: a
/// batch's purpose is fixed once it has a decision (ADR-002, decision 2), so
/// the fix is a new run, not a switch here.
struct CalibrationNotice: View {
    let batch: ScanBatch

    var body: some View {
        if batch.purpose == .calibration {
            Label("Calibration run: these decisions teach the recogniser but add nothing to your collection. For cards you want counted, use Start run… on the Scan tab before feeding.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.amber)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.amber.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}
