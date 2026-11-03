import RiftboundRecognizer
import SwiftUI

/// Searchable list of every printing, for correcting a scan.
struct CardPickerView: View {
    let directory: CardDirectory
    let suggestions: [Card]
    let onPick: (Card) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List {
                if query.isEmpty, !suggestions.isEmpty {
                    Section("Suggestions") {
                        ForEach(suggestions) { card in
                            row(card)
                        }
                    }
                }
                Section(query.isEmpty ? "All cards" : "Results") {
                    ForEach(directory.matching(query)) { card in
                        row(card)
                    }
                }
            }
            .searchable(text: $query, prompt: "Name or code, e.g. OGN-001")
            .navigationTitle("Which card is it?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func row(_ card: Card) -> some View {
        Button {
            onPick(card)
        } label: {
            HStack(spacing: 12) {
                CardArtView(url: card.imageURL)
                VStack(alignment: .leading) {
                    Text(card.displayName)
                        .font(.body)
                    Text("\(card.code.canonical) · \(card.setName) · \(card.rarity.label)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .tint(.primary)
        .accessibilityElement(children: .combine)
    }
}
