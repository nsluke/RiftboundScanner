import RiftboundRecognizer
import SwiftUI

/// One scan at a time: the crop beside the matched card, why it needs a look
/// (or that it is an audit or a spot-check), and one tap (or swipe) to settle it.
struct ReviewQueueView: View {
    @State private var model: ReviewQueueModel
    @Environment(\.dismiss) private var dismiss
    @State private var isFixing = false
    @State private var dragOffset: CGFloat = 0
    @State private var decidedCount = 0

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
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.amber)
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
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.amber)
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
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task { await model.load() }
        .sheet(isPresented: $isFixing) {
            if let record = model.current {
                FixMatchView(
                    model: FixMatchModel(record: record, directory: model.directory, preferredSet: model.dominantSet),
                    photoURL: model.photoURL(for: record),
                    onChoose: { card in
                        isFixing = false
                        Task { await model.correct(to: card.id) }
                    },
                    onReject: { reason in
                        isFixing = false
                        Task { await model.reject(reason) }
                    }
                )
            }
        }
        .alert("Couldn't save", isPresented: isShowingStorageProblem, presenting: model.storageProblem) { _ in
            Button("OK") { model.dismissStorageProblem() }
        } message: { problem in
            Text(problem.message)
        }
        .sensoryFeedback(.success, trigger: model.tally.decided)
    }

    // MARK: - Reviewing

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
                verdictButtons
                Text("Swipe right to confirm, left to fix.")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .padding()
        }
        .animation(.snappy, value: dragOffset)
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
                        CardArtView(url: top.card.imageURL, size: proxy.size)
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
        }
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
                .buttonStyle(.borderedProminent)
                .tint(Theme.blue)
                .foregroundStyle(Theme.ground)
                .disabled(model.current?.topCandidate == nil)

                Button {
                    isFixing = true
                } label: {
                    Label("Wrong card", systemImage: "pencil")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(Theme.amber)
            }
            .controlSize(.large)

            HStack {
                Button("Not a card") { Task { await model.reject(.notACard) } }
                Spacer()
                Button("Skip for now") { model.skip() }
            }
            .font(.subheadline)
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 4)
        }
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
                        Task { await model.confirm() }
                    }
                } else if value.translation.width < -80 {
                    isFixing = true
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
            Button("Back to scanning") { dismiss() }
                .buttonStyle(.borderedProminent)
                .tint(Theme.amber)
                .foregroundStyle(Theme.ground)
                .controlSize(.large)
        }
        .padding()
    }

    private var isShowingStorageProblem: Binding<Bool> {
        Binding(get: { model.storageProblem != nil }, set: { if !$0 { model.dismissStorageProblem() } })
    }
}
