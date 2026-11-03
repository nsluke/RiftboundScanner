import RiftboundRecognizer
import SwiftUI

struct CandidateRow: View {
    let candidate: Candidate
    let rank: Int

    var body: some View {
        HStack(spacing: 12) {
            CardArtView(url: candidate.card.imageURL)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.card.displayName)
                    .font(.headline)
                Text("\(candidate.card.code.canonical) · \(candidate.card.setName)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("Score \(candidate.score.formatted(.number.precision(.fractionLength(2))))")
                    if let agreement = candidate.codeAgreement {
                        Text(agreement.label)
                    }
                    if candidate.orientation == .upsideDown {
                        Text("Upside down")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Text("#\(rank)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

extension CodeAgreement {
    var label: String {
        switch self {
        case .exact: String(localized: "Code matches")
        case .variantDiffers: String(localized: "Variant differs")
        case .numberDiffers: String(localized: "Number differs")
        case .setDiffers: String(localized: "Set differs")
        case .unrelated: String(localized: "Code disagrees")
        }
    }
}
