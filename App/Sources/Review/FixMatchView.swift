import RiftboundRecognizer
import SwiftUI

/// The iPhone's fix sheet: the scan's thumbnail over `FixMatchPanel`. The Mac
/// shows the panel beside the full-size scan instead (`ReviewQueueView`).
struct FixMatchView: View {
    @State private var model: FixMatchModel
    let photoURL: URL
    let onChoose: (Card) -> Void
    let onReject: (RejectionReason) -> Void

    @Environment(\.dismiss) private var dismiss

    init(model: @autoclosure @escaping () -> FixMatchModel, photoURL: URL, onChoose: @escaping (Card) -> Void, onReject: @escaping (RejectionReason) -> Void) {
        _model = State(wrappedValue: model())
        self.photoURL = photoURL
        self.onChoose = onChoose
        self.onReject = onReject
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    FixMatchPanel(model: model, onChoose: onChoose, onReject: onReject)
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationTitle("Which card is it?")
            .inlineNavigationTitle()
            .darkNavigationBar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ThumbnailImage(url: photoURL, maxPixelSize: 300)
                .frame(width: 63, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("The scanned card")
            VStack(alignment: .leading, spacing: 4) {
                Text("Matched as")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Text(model.record.topCandidate?.card.displayName ?? String(localized: "No match"))
                    .font(.headline)
                if let code = model.record.codeReading {
                    Text("Code read: \(code.code.canonical)")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Names the right printing for a wrong match from one field: type part of
/// the name on the banner, or the code from the card in hand (`rad 40`, or
/// just `40`). Results resolve as you type; ↑ and ↓ move, Return uses the
/// highlighted one. The scan's other candidates and the two rejections sit
/// below.
struct FixMatchPanel: View {
    @Bindable var model: FixMatchModel
    let onChoose: (Card) -> Void
    let onReject: (RejectionReason) -> Void
    /// Shown where the panel replaces the verdict buttons (the Mac); the
    /// iPhone's sheet has its own Cancel.
    var onCancel: (() -> Void)?

    @FocusState private var isQueryFocused: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let explanation = model.explanation {
                Label(explanation, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.amber)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("Server: \(explanation)")
            }
            queryField
            results
            otherCandidates
            footer
        }
        .onAppear { isQueryFocused = true }
    }

    private var queryField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Which card is it?")
                .font(.subheadline.weight(.medium))
            TextField("Name or code, like kato or rad 40", text: $model.query)
                .textEntry(.verbatim)
                .textContentType(.none)
                .focused($isQueryFocused)
                .padding(.horizontal, 12)
                .frame(minHeight: 40)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(isQueryFocused ? Theme.amber : Theme.hairline))
                .onSubmit { useSelection() }
                .onKeyPress(.downArrow) {
                    model.moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    model.moveSelection(by: -1)
                    return .handled
                }
                #if os(macOS)
                .onExitCommand { onCancel?() }
                #endif
                .accessibilityLabel("Card name or code")
                .accessibilityHint("Results update as you type")
            if let hint {
                Text(hint)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// What the field understood, so a bare number's set order is no surprise.
    private var hint: String? {
        switch model.parsedQuery {
        case .empty:
            String(localized: "The name banner is readable in the photo; the code needs the card in hand.")
        case .number(let number):
            if let set = model.preferredSet {
                String(localized: "Number \(number.rawValue) in \(set.rawValue) first, then every other set.")
            } else {
                String(localized: "Number \(number.rawValue) in every set.")
            }
        case .code(let set, let number):
            String(localized: "\(set.rawValue) number \(number.rawValue).")
        case .name:
            nil
        }
    }

    @ViewBuilder
    private var results: some View {
        if model.results.isEmpty {
            if model.parsedQuery != .empty {
                Text("No card matches “\(model.query)”.")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        } else {
            VStack(spacing: 6) {
                ForEach(model.results) { card in
                    resultRow(card, isSelected: card.id == model.selection)
                }
            }
        }
    }

    private func resultRow(_ card: Card, isSelected: Bool) -> some View {
        Button {
            onChoose(card)
        } label: {
            HStack(spacing: 12) {
                CardArtView(url: card.imageURL, size: CGSize(width: 36, height: 50), orientation: card.orientation)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(card.code.canonical) · \(card.setName) · \(card.rarity.label)")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "return")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                        .accessibilityHidden(true)
                }
            }
            .padding(8)
            .background(isSelected ? Theme.amber.opacity(0.14) : Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isSelected ? Theme.amber : Theme.hairline, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.text)
        .accessibilityLabel("\(card.displayName), \(card.code.canonical), \(card.setName)")
        .accessibilityHint("Uses this card")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private var otherCandidates: some View {
        if !model.otherCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(otherCandidatesTitle)
                    .font(.subheadline.weight(.medium))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(Array(model.otherCandidates.prefix(4).enumerated()), id: \.element.card.id) { index, candidate in
                        Button {
                            onChoose(candidate.card)
                        } label: {
                            VStack(spacing: 4) {
                                GeometryReader { proxy in
                                    CardArtView(url: candidate.card.imageURL, size: proxy.size, orientation: candidate.card.orientation)
                                }
                                .aspectRatio(63 / 88, contentMode: .fit)
                                Text(candidate.card.displayName)
                                    .font(.caption2)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.center)
                                Text(candidate.card.code.canonical)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(Theme.muted)
                                    .lineLimit(1)
                            }
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.text)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                        .accessibilityLabel("\(candidate.card.displayName), \(candidate.card.code.canonical)")
                        .accessibilityHint("Uses this card")
                    }
                }
            }
        }
    }

    private var otherCandidatesTitle: String {
        #if os(macOS)
        String(localized: "Other candidates · ⌘1–⌘\(min(model.otherCandidates.count, 4))")
        #else
        String(localized: "Other candidates")
        #endif
    }

    private var footer: some View {
        HStack {
            Button("Not a card") { onReject(.notACard) }
            Button("Not in the catalog") { onReject(.cardNotInCatalog) }
            Spacer()
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.muted)
    }

    private func useSelection() {
        if let card = model.selectedCard {
            onChoose(card)
        }
    }
}
