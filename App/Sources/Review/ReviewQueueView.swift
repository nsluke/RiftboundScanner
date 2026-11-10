import RiftboundRecognizer
import SwiftUI

/// One scan at a time: the crop beside the matched card, why it needs a look
/// (or that it is an audit or a spot-check), and one tap, swipe or key to
/// settle it: Return accepts, F fixes the match, → skips to the next scan and
/// ← goes back to the one before. The iPhone fixes a match in a sheet; the
/// Mac puts the fix panel in the side panel, beside the full-size scan, and
/// opens it at once for a scan the triage grid flagged.
struct ReviewQueueView: View {
    @State private var model: ReviewQueueModel
    @Environment(\.dismiss) private var dismiss
    /// For the fix sheet's explanation of what the server said about a scan.
    @Environment(SyncEngine.self) private var sync: SyncEngine?
    /// The fix in progress for the scan on screen, if any.
    @State private var fixing: FixMatchModel?
    @State private var dragOffset: CGFloat = 0

    init(model: @autoclosure @escaping () -> ReviewQueueModel) {
        _model = State(wrappedValue: model())
    }

    var body: some View {
        Group {
            switch model.queue {
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
            case .loaded:
                switch model.progress {
                case .reviewing(let position, let total):
                    if let record = model.current {
                        reviewing(record, position: position, total: total)
                    }
                case .done(let tally):
                    done(tally)
                case .nothingToReview:
                    ContentUnavailableView {
                        Label(model.mode.isSpotCheck ? "Nothing to spot-check" : "Nothing to review", systemImage: "checkmark.seal")
                    } description: {
                        Text(model.mode.isSpotCheck
                            ? "No accepted scans from this run are left to re-check."
                            : "Every scan in this batch has a verdict or was confident on its own.")
                    } actions: {
                        Button("Back to scanning") { dismiss() }
                            .prominentAction(Theme.amber)
                    }
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground.ignoresSafeArea())
        .foregroundStyle(Theme.text)
        .navigationTitle(model.mode.isSpotCheck ? "Spot-check" : "Review")
        .inlineNavigationTitle()
        .darkNavigationBar()
        .task { await model.load() }
        #if os(iOS)
        .sheet(item: $fixing) { fix in
            FixMatchView(
                model: fix,
                photoURL: model.photoURL(for: fix.record),
                onChoose: { card in use(card) },
                onReject: { reason in reject(reason) }
            )
        }
        #endif
        .onChange(of: model.current?.id, initial: true) { _, _ in
            fixing = model.currentIsFlagged ? makeFix() : nil
        }
        .alert("Couldn't save", isPresented: isShowingStorageProblem, presenting: model.storageProblem) { _ in
            Button("OK") { model.dismissStorageProblem() }
        } message: { problem in
            Text(problem.message)
        }
        .sensoryFeedback(.success, trigger: model.tally.decided)
    }

    // MARK: - Reviewing

    #if os(macOS)
    /// The Mac: the scan and its match as large as the window allows, and a
    /// side panel with the details and either the verdict buttons or the fix
    /// panel, so the photo stays in view while the right card is found.
    private func reviewing(_ record: ScanRecord, position: Int, total: Int) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: 12) {
                progressSegments(position: position, total: total)
                comparison(record)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(20)
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    CalibrationNotice(batch: model.batch)
                    if let kind = model.currentKind {
                        kindBadge(kind)
                    }
                    details(record)
                    if let fixing {
                        FixMatchPanel(
                            model: fixing,
                            onChoose: { card in use(card) },
                            onReject: { reason in reject(reason) },
                            onCancel: { self.fixing = nil }
                        )
                    } else {
                        decisionControls(record)
                        gestureHint
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(20)
            }
            .frame(width: 380)
        }
    }
    #else
    private func reviewing(_ record: ScanRecord, position: Int, total: Int) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                progressSegments(position: position, total: total)
                if let kind = model.currentKind {
                    kindBadge(kind)
                }
                comparison(record)
                    .offset(x: dragOffset)
                    .gesture(swipe)
                details(record)
                CalibrationNotice(batch: model.batch)
                decisionControls(record)
                gestureHint
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding()
        }
        .animation(.snappy, value: dragOffset)
    }
    #endif

    /// The duplicate comparison, printing chips, finish and verdict buttons.
    @ViewBuilder
    private func decisionControls(_ record: ScanRecord) -> some View {
        if let duplicate = model.duplicateOf, model.currentKind == .possibleDuplicate {
            duplicateRow(duplicate)
        }
        if let options = model.printingOptions, options.hasAlternatives, record.topCandidate != nil {
            PrintingPickerView(options: options, selection: $model.selectedPrinting)
        }
        if model.asksForFinish, record.topCandidate != nil {
            FinishToggle(selection: $model.selectedFinish, inherited: model.inheritedFinish)
        }
        if model.currentKind == .possibleDuplicate {
            duplicateButtons
        } else {
            verdictButtons
        }
    }

    private func makeFix() -> FixMatchModel? {
        guard let record = model.current else { return nil }
        return FixMatchModel(record: record, directory: model.directory, preferredSet: model.fixSet, serverStatus: serverStatus(for: record))
    }

    private func use(_ card: Card) {
        fixing = nil
        Task { await model.correct(to: card.id) }
    }

    private func reject(_ reason: RejectionReason) {
        fixing = nil
        Task { await model.reject(reason) }
    }

    /// The earlier scan this one seems to repeat, so the two can be compared.
    private func duplicateRow(_ duplicate: ScanRecord) -> some View {
        HStack(spacing: 12) {
            ThumbnailImage(url: model.photoURL(for: duplicate), maxPixelSize: 300)
                .frame(width: 44, height: 61)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Same card as the previous scan?")
                    .font(.subheadline.weight(.semibold))
                Text("Fed at \(duplicate.capturedAt.formatted(date: .omitted, time: .standard)) · \(duplicate.topCandidate?.card.displayName ?? String(localized: "no match"))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    /// Keep both (a second copy) or Drop (the feeder fed it twice).
    private var duplicateButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.keepBoth() }
                } label: {
                    Label("Keep both", systemImage: "plus.square.on.square")
                        .frame(maxWidth: .infinity)
                }
                .prominentAction(Theme.blue)
                .disabled(model.current?.topCandidate == nil)
                .keyboardShortcut(ReviewKey.accept)
                .accessibilityHint("Confirms this scan as a second copy of the card")

                Button {
                    Task { await model.drop() }
                } label: {
                    Label("Drop", systemImage: "trash")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
                .accessibilityHint("Rejects this scan as a duplicate capture; the earlier scan stands")
            }
            .controlSize(.large)

            HStack {
                Button("Wrong card") { fixing = makeFix() }
                    .keyboardShortcut(ReviewKey.fix)
                Spacer()
                previousButton
                Button("Skip for now") { model.skip() }
                    .keyboardShortcut(ReviewKey.next)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 4)
        }
    }

    /// What the server last said about this scan's ledger item, for the fix sheet.
    private func serverStatus(for record: ScanRecord) -> TerminalStatus? {
        guard let attention = sync?.summary(for: model.batch.id)?.attention.first(where: { $0.scanID == record.id }) else { return nil }
        if case .ledgerItem(let status, _) = attention.kind { return status }
        return nil
    }

    private func progressSegments(position: Int, total: Int) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index < position ? Theme.amber : Theme.hairline)
                        .frame(height: 4)
                }
            }
            Text("\(position) of \(total)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scan \(position) of \(total)")
    }

    private func comparison(_ record: ScanRecord) -> some View {
        HStack(spacing: 12) {
            VStack(spacing: 6) {
                ThumbnailImage(url: model.photoURL(for: record), maxPixelSize: 800)
                    .aspectRatio(63 / 88, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber, lineWidth: 2))
                    .accessibilityLabel("The scanned card")
                Text("Scanned")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            VStack(spacing: 6) {
                if let top = record.topCandidate {
                    GeometryReader { proxy in
                        CardArtView(url: top.card.imageURL, size: proxy.size, orientation: top.card.orientation)
                    }
                    .aspectRatio(63 / 88, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
                    .accessibilityLabel("The matched card, \(top.card.displayName)")
                } else {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Theme.surface)
                        .aspectRatio(63 / 88, contentMode: .fit)
                        .overlay { Text("No match").font(.footnote).foregroundStyle(Theme.muted) }
                }
                Text("Matched")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Audit and spot-check rows say so up front: the verdict they take is a
    /// different kind of label (ADR-002, decision 6), and the user should know
    /// the recogniser was sure.
    @ViewBuilder
    private func kindBadge(_ kind: ReviewKind) -> some View {
        switch kind {
        case .uncertain:
            EmptyView()
        case .audit:
            Label("Audit", systemImage: "checkmark.shield")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.blue.opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.blue)
                .accessibilityLabel("Audit: the recogniser was confident about this scan")
        case .spotCheck:
            Label("Spot-check", systemImage: "eye")
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.blue.opacity(0.18), in: Capsule())
                .foregroundStyle(Theme.blue)
                .accessibilityLabel("Spot-check of an accepted scan")
        case .pickPrinting:
            tierBadge(.pickPrinting, systemImage: "rectangle.on.rectangle", accessibility: "Pick printing: the card is known, the printing is not settled")
        case .possibleDuplicate:
            tierBadge(.possibleDuplicate, systemImage: "doc.on.doc", accessibility: "Possible duplicate: looks like the card fed just before it")
        case .unknown:
            tierBadge(.unknown, systemImage: "questionmark.square.dashed", accessibility: "Unknown: nothing in the index resembled this photo")
        }
    }

    private func tierBadge(_ tier: ScanTier, systemImage: String, accessibility: String) -> some View {
        Label(tier.label, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RunCompleteStrip.color(for: tier).opacity(0.18), in: Capsule())
            .foregroundStyle(RunCompleteStrip.color(for: tier))
            .accessibilityLabel(accessibility)
    }

    private func details(_ record: ScanRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.topCandidate?.card.displayName ?? String(localized: "No match in the index"))
                .font(.title3.weight(.semibold))
            if let card = record.topCandidate?.card {
                Text("\(card.code.canonical) · \(card.setName) · \(card.rarity.label)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            switch model.currentKind {
            case .uncertain(let reason):
                Label(reason.message(isArtWeak: record.hasWeakArtMatch), systemImage: "questionmark.circle")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            case .audit:
                Label("The code was read and the art matched; this scan was held back as a random check. Is it the right card?", systemImage: "checkmark.shield")
                    .font(.footnote)
                    .foregroundStyle(Theme.blue)
            case .spotCheck:
                Label("Accepted without a look on \(record.verdictAt?.formatted(date: .omitted, time: .shortened) ?? "this run"). Is it the right card?", systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(Theme.blue)
            case .pickPrinting:
                Label(record.confidence(under: model.rule).reason == .variantOnly
                      ? "The code matches except for the variant. Pick the printing in the corner."
                      : "This art comes in printings the recogniser cannot tell apart. Pick the one in your hand.", systemImage: "rectangle.on.rectangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            case .possibleDuplicate:
                Label("This photo looks like the card fed just before it. Keep both if it is a second copy; drop it if the feeder fed the same card twice.", systemImage: "doc.on.doc")
                    .font(.footnote)
                    .foregroundStyle(RunCompleteStrip.color(for: .possibleDuplicate))
            case .unknown:
                Label("Nothing in the index resembled this photo. Name the card, or reject it.", systemImage: "questionmark.square.dashed")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
            case nil:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var verdictButtons: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task { await model.confirm() }
                } label: {
                    Label("It's right", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .prominentAction(Theme.blue)
                .disabled(model.current?.topCandidate == nil)
                .keyboardShortcut(ReviewKey.accept)

                Button {
                    fixing = makeFix()
                } label: {
                    Label("Wrong card", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
                .keyboardShortcut(ReviewKey.fix)
            }
            .controlSize(.large)

            HStack {
                Button("Not a card") { Task { await model.reject(.notACard) } }
                Spacer()
                previousButton
                Button("Skip for now") { model.skip() }
                    .keyboardShortcut(ReviewKey.next)
            }
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 4)
        }
    }

    /// Back to the scan before; a new verdict there supersedes the old one.
    @ViewBuilder
    private var previousButton: some View {
        if model.canGoBack {
            Button("Previous") { model.goBack() }
                .keyboardShortcut(ReviewKey.previous)
                .accessibilityHint("Goes back to the scan before so you can decide it again")
        }
    }

    /// How to settle the scan without the buttons: swipes on the iPhone, keys on the Mac.
    private var gestureHint: Text {
        let isDuplicate = model.currentKind == .possibleDuplicate
        #if os(macOS)
        return Text(isDuplicate ? "Return keeps both · F fixes the match · → skips · ← goes back" : "Return confirms · F fixes the match · → skips · ← goes back")
        #else
        return Text(isDuplicate ? "Swipe right to keep both, left to fix." : "Swipe right to confirm, left to fix.")
        #endif
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 24)
            .onChanged { value in
                dragOffset = value.translation.width / 3
            }
            .onEnded { value in
                dragOffset = 0
                if value.translation.width > 80 {
                    if model.current?.topCandidate != nil {
                        Task { await model.confirm() }  // keep both, for a duplicate
                    }
                } else if value.translation.width < -80 {
                    fixing = makeFix()
                }
            }
    }

    // MARK: - Done

    private func done(_ tally: ReviewQueueModel.Tally) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.blue)
            Text(model.mode.isSpotCheck ? "Spot-check complete" : "Review complete")
                .font(.title2.weight(.semibold))
            VStack(spacing: 4) {
                Text("\(tally.confirmed) confirmed · \(tally.corrected) corrected · \(tally.rejected) rejected")
                if tally.skipped > 0 {
                    Text(model.mode.isSpotCheck ? "\(tally.skipped) skipped, left as accepted" : "\(tally.skipped) skipped, still pending")
                        .foregroundStyle(Theme.amber)
                }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .accessibilityElement(children: .combine)
            if model.canGoBack {
                Button("Go back to the last scan") { model.goBack() }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.blue)
                    .keyboardShortcut(ReviewKey.previous)
            }
            Button("Back to scanning") { dismiss() }
                .prominentAction(Theme.amber)
                .controlSize(.large)
                .keyboardShortcut(ReviewKey.accept)
        }
        .padding()
    }

    private var isShowingStorageProblem: Binding<Bool> {
        Binding(get: { model.storageProblem != nil }, set: { if !$0 { model.dismissStorageProblem() } })
    }
}

/// The review queue's keys. They sit on the buttons rather than in a menu
/// because they only mean something while a scan is on screen, and a button's
/// key goes quiet while the fix sheet (and its search field) has the focus.
enum ReviewKey {
    /// Return: it's right, or keep both for a possible duplicate.
    static let accept = KeyboardShortcut(.return, modifiers: [])
    /// F: the match is wrong; opens the fix sheet.
    static let fix = KeyboardShortcut("f", modifiers: [])
    /// →: on to the next scan, leaving this one pending.
    static let next = KeyboardShortcut(.rightArrow, modifiers: [])
    /// ←: back to the scan before, to decide it again.
    static let previous = KeyboardShortcut(.leftArrow, modifiers: [])
}
