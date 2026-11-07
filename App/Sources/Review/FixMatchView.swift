import RiftboundRecognizer
import SwiftUI

/// Names the right printing for a wrong match. Code first, then the scan's
/// other candidates, then a full search.
struct FixMatchView: View {
    @State private var model: FixMatchModel
    let photoURL: URL
    let onChoose: (Card) -> Void
    let onReject: (RejectionReason) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSearching = false
    @FocusState private var isNumberFocused: Bool

    init(model: @autoclosure @escaping () -> FixMatchModel, photoURL: URL, onChoose: @escaping (Card) -> Void, onReject: @escaping (RejectionReason) -> Void) {
        _model = State(wrappedValue: model())
        self.photoURL = photoURL
        self.onChoose = onChoose
        self.onReject = onReject
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let explanation = model.explanation {
                        Label(explanation, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.amber)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("Server: \(explanation)")
                    }
                    codeEntry
                    resolved
                    otherCandidates
                    Button {
                        isSearching = true
                    } label: {
                        Label("Search all \(model.directory.cards.count) cards by name", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                    .controlSize(.large)
                    rejections
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground.ignoresSafeArea())
            .foregroundStyle(Theme.text)
            .navigationTitle("Which card is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $isSearching) {
                CardPickerView(directory: model.directory, suggestions: model.record.candidates.map(\.card)) { card in
                    isSearching = false
                    onChoose(card)
                }
            }
            .onAppear { isNumberFocused = true }
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

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Type the code in the corner")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.sets, id: \.self) { set in
                        Button(set.rawValue) { model.set = set }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(model.set.rawValue)
                            .font(.body.monospaced().weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                }
                .foregroundStyle(Theme.text)
                .accessibilityLabel("Set \(model.set.rawValue)")
                .accessibilityHint("Changes the set")

                TextField("001", text: $model.numberText)
                    .font(.body.monospaced())
                    .keyboardType(.numberPad)
                    .textContentType(.none)
                    .focused($isNumberFocused)
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityLabel("Collector number")
            }
        }
    }

    @ViewBuilder
    private var resolved: some View {
        if model.matches.isEmpty {
            if !model.numberText.isEmpty {
                Text("No \(model.set.rawValue) card has number \(model.numberText).")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        } else {
            VStack(spacing: 8) {
                ForEach(model.matches) { card in
                    HStack(spacing: 12) {
                        CardArtView(url: card.imageURL)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.displayName).font(.headline)
                            Text("\(card.code.canonical) · \(card.setName) · \(card.rarity.label)")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Button("Use") { onChoose(card) }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.amber)
                            .foregroundStyle(Theme.ground)
                    }
                    .padding(10)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber, lineWidth: 1.5))
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Use") { onChoose(card) }
                }
            }
        }
    }

    @ViewBuilder
    private var otherCandidates: some View {
        if !model.otherCandidates.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Other candidates")
                    .font(.subheadline.weight(.medium))
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(model.otherCandidates, id: \.card.id) { candidate in
                        Button {
                            onChoose(candidate.card)
                        } label: {
                            VStack(spacing: 4) {
                                GeometryReader { proxy in
                                    CardArtView(url: candidate.card.imageURL, size: proxy.size)
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
                        .foregroundStyle(Theme.text)
                        .accessibilityLabel("\(candidate.card.displayName), \(candidate.card.code.canonical)")
                        .accessibilityHint("Uses this card")
                    }
                }
            }
        }
    }

    private var rejections: some View {
        HStack {
            Button("Not a card") { onReject(.notACard) }
            Spacer()
            Button("Not in the catalog") { onReject(.cardNotInCatalog) }
        }
        .font(.subheadline)
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, 4)
    }
}
