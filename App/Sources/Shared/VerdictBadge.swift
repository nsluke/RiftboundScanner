import SwiftUI

struct VerdictBadge: View {
    let verdict: Verdict
    let directory: CardDirectory

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch verdict {
        case .pending: String(localized: "Pending")
        case .correct: String(localized: "Correct")
        case .corrected(let id): String(localized: "Corrected: \(directory[id]?.code.canonical ?? id.rawValue)")
        case .rejected(let reason): reason.label
        }
    }

    private var color: Color {
        switch verdict {
        case .pending: .secondary
        case .correct: .green
        case .corrected: .orange
        case .rejected: .red
        }
    }
}
