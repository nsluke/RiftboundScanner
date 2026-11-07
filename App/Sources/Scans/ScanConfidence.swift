import RiftboundRecognizer

/// Whether a scan can be trusted without a human look. The bar for confident
/// is deliberately high: a code was read, it names the top candidate exactly,
/// and the fused score clears 1.0 (descriptor similarity of at least 0.5 on
/// top of the exact-code bonus).
nonisolated enum ScanConfidence: Hashable, Sendable {
    case confident
    case uncertain(UncertaintyReason)

    static let confidentScore = 1.0

    init(_ record: ScanRecord) {
        guard let top = record.topCandidate else {
            self = .uncertain(record.codeReading == nil ? .noCodeRead : .codeDisagrees)
            return
        }
        guard record.codeReading != nil else {
            self = .uncertain(.noCodeRead)
            return
        }
        switch top.codeAgreement {
        case .exact:
            self = top.score >= Self.confidentScore ? .confident : .uncertain(.weakArtMatch)
        case .variantDiffers:
            self = .uncertain(.variantOnly)
        case .numberDiffers, .setDiffers, .unrelated, nil:
            self = .uncertain(.codeDisagrees)
        }
    }

    var isConfident: Bool {
        if case .confident = self { return true }
        return false
    }

    var reason: UncertaintyReason? {
        if case .uncertain(let reason) = self { return reason }
        return nil
    }
}

nonisolated enum UncertaintyReason: Hashable, Sendable, CaseIterable {
    case noCodeRead
    case codeDisagrees
    case weakArtMatch
    case variantOnly

    /// A short label for badges and grids.
    var label: String {
        switch self {
        case .noCodeRead: String(localized: "No code read")
        case .codeDisagrees: String(localized: "Code disagrees")
        case .weakArtMatch: String(localized: "Weak art match")
        case .variantOnly: String(localized: "Variant unclear")
        }
    }

    /// One or two sentences for the review screen.
    func message(isArtWeak: Bool) -> String {
        switch self {
        case .noCodeRead:
            isArtWeak
                ? String(localized: "No code was read, and the art match is weak. Compare the two cards.")
                : String(localized: "No code was read, but the art matches well. Check the code in the corner.")
        case .codeDisagrees:
            String(localized: "The code that was read doesn't name this card. Check the code in the corner.")
        case .weakArtMatch:
            String(localized: "The code matches, but the art match is weak. Compare the two cards.")
        case .variantOnly:
            String(localized: "The code matches except for the variant. Check for a signature or alternate-art mark.")
        }
    }
}

extension ScanRecord {
    var confidence: ScanConfidence { ScanConfidence(self) }

    /// Still pending and not trusted on its own.
    var needsReview: Bool {
        verdict == .pending && !confidence.isConfident
    }

    /// Still pending but trusted; can be accepted without a look.
    var isAutoConfirmable: Bool {
        verdict == .pending && confidence.isConfident
    }

    /// The art match is weak even where a code exists; informs the reason text.
    var hasWeakArtMatch: Bool {
        (topCandidate?.descriptorScore ?? 0) < 0.5
    }
}
