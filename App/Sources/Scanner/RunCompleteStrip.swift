import SwiftUI

/// What a finished feed-and-scan run leaves on the Scan tab: this run's scans
/// at a glance in five tiers (Confident / Needs a look / Pick printing /
/// Possible duplicate / Unknown), how many confident ones the policy holds
/// for audit, and the next step for each (ADR-002 §6).
struct RunCompleteStrip: View {
    let model: ScannerModel
    let progress: ScannerModel.AutoScanProgress
    let reason: ScannerModel.AutoScanEnd

    private var rule: ConfidenceRule { model.rule }
    private var records: [ScanRecord] { model.runRecords }
    private var counts: TierCounts { model.runTierCounts }
    private var spotCheckCandidates: [ScanRecord.ID] { model.spotCheckCandidates }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if records.isEmpty {
                Text(reason.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            } else {
                thumbnails
                legend
                actions
            }
        }
        .padding(12)
        .background(Theme.surface.opacity(0.92), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .foregroundStyle(Theme.text)
    }

    private var header: some View {
        HStack {
            Text(reason == .hopperEmpty ? "Run complete" : "Run ended")
                .font(.headline)
            if reason != .hopperEmpty {
                Text(reason.message)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
            Spacer()
            if let batch = model.batch {
                NavigationLink("See all", value: ReviewRoute.overview(batch))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.blue)
            }
            Button {
                model.dismissAutoScanResult()
            } label: {
                Image(systemName: "xmark")
                    .font(.footnote.weight(.semibold))
                    .frame(minWidth: 32, minHeight: 32)
            }
            .foregroundStyle(Theme.muted)
            .accessibilityLabel("Dismiss run summary")
        }
    }

    private var thumbnails: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(records) { record in
                    ScanThumbnail(record: record, url: model.photoURL(for: record), width: 44, rule: rule, tier: model.tier(of: record))
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("\(records.count) scans from this run")
    }

    /// One dot per tier that has scans, in tier order, plus the audit hold.
    private var legend: some View {
        let counts = counts
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { legendItems(counts) }
            VStack(alignment: .leading, spacing: 4) { legendItems(counts) }
        }
        .font(.footnote)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(legendAccessibilityText(counts))
    }

    @ViewBuilder
    private func legendItems(_ counts: TierCounts) -> some View {
        let shown = ScanTier.allCases.filter { counts[$0] > 0 || $0 == .confident }
        ForEach(Array(shown.enumerated()), id: \.element) { offset, tier in
            if offset > 0 {
                Text("·").foregroundStyle(Theme.muted)
            }
            HStack(spacing: 4) {
                Circle().fill(Self.color(for: tier)).frame(width: 8, height: 8)
                Text("\(tier == .confident ? counts[.confident] + counts.decided : counts[tier]) \(tier.label.lowercased())")
            }
        }
        if counts.heldForAudit > 0 {
            Text("·").foregroundStyle(Theme.muted)
            HStack(spacing: 4) {
                Image(systemName: "checkmark.shield").font(.caption2).foregroundStyle(Theme.blue)
                Text("\(counts.heldForAudit) held for audit")
            }
        }
    }

    private func legendAccessibilityText(_ counts: TierCounts) -> String {
        var parts = ScanTier.allCases.filter { counts[$0] > 0 || $0 == .confident }.map { tier in
            "\(tier == .confident ? counts[.confident] + counts.decided : counts[tier]) \(tier.label.lowercased())"
        }
        if counts.heldForAudit > 0 { parts.append(String(localized: "\(counts.heldForAudit) held for audit")) }
        return parts.joined(separator: ", ")
    }

    static func color(for tier: ScanTier) -> Color {
        switch tier {
        case .confident: Theme.blue
        case .needsALook, .pickPrinting, .unknown: Theme.amber
        case .possibleDuplicate: Color(red: 0xE0 / 255, green: 0x8A / 255, blue: 0x5C / 255)
        }
    }

    private var reviewLabel: String {
        let counts = counts
        var parts: [String] = []
        let needLook = counts[.needsALook] + counts[.unknown]
        if needLook > 0 { parts.append(String(localized: "\(needLook) uncertain")) }
        if counts[.pickPrinting] > 0 { parts.append(String(localized: "\(counts[.pickPrinting]) printings")) }
        if counts[.possibleDuplicate] > 0 { parts.append(String(localized: "\(counts[.possibleDuplicate]) duplicates")) }
        if counts.heldForAudit > 0 { parts.append(String(localized: "\(counts.heldForAudit) for audit")) }
        return String(localized: "Review \(parts.joined(separator: " · "))")
    }

    private var acceptLabel: String {
        let counts = counts
        switch (counts.heldForAudit, counts.toReview) {
        case (0, 0): return String(localized: "Accept the \(counts.acceptable) confident")
        case (0, _): return String(localized: "Accept the \(counts.acceptable) confident, finish later")
        case (let audits, _): return String(localized: "Accept \(counts.acceptable) confident · \(audits) held for audit")
        }
    }

    @ViewBuilder
    private var actions: some View {
        if let batch = model.batch {
            let counts = counts
            VStack(spacing: 8) {
                if counts.toReview > 0 {
                    NavigationLink(value: ReviewRoute.review(batch)) {
                        Text(reviewLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .prominentAction(Theme.amber)
                    .accessibilityHint("Opens the review queue for this batch")
                }
                if counts.acceptable > 0 {
                    Button {
                        Task { await model.acceptConfidentScans() }
                    } label: {
                        Text(acceptLabel)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                    .accessibilityHint(counts.heldForAudit == 0
                        ? "Marks the confident scans correct without reviewing them"
                        : "Marks the confident scans correct without reviewing them; the ones held for audit stay in the review queue")
                }
                if counts.acceptable == 0, !spotCheckCandidates.isEmpty {
                    NavigationLink(value: ReviewRoute.spotCheck(batch, candidates: spotCheckCandidates, limit: ScannerModel.spotCheckLimit)) {
                        Label("Spot-check \(min(spotCheckCandidates.count, ScannerModel.spotCheckLimit))", systemImage: "eye")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                    .accessibilityHint("Re-checks a sample of the scans that were accepted without a look")
                }
                if counts.toReview == 0, counts.acceptable == 0, spotCheckCandidates.isEmpty {
                    Text("Everything in this run has a verdict.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            }
            .controlSize(.regular)
        }
    }
}

/// A scan's saved crop with its confidence drawn on: blue edge when the
/// recogniser is sure, amber mark when it is not, and a check once decided.
struct ScanThumbnail: View {
    let record: ScanRecord
    let url: URL
    var width: CGFloat = 44
    var showsReason = false
    /// The confident tier to draw under; History draws under the defaults.
    var rule: ConfidenceRule = .default
    /// The five-tier reading when the caller knows the batch; without it the
    /// thumbnail falls back to confidence alone.
    var tier: ScanTier? = nil

    private var height: CGFloat { width * 88 / 63 }
    private var confidence: ScanConfidence { record.confidence(under: rule) }
    private var isHeldForAudit: Bool { record.isHeldForAudit(under: rule) }

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailImage(url: url, maxPixelSize: Int(width * 3))
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(edgeColor, lineWidth: 2))
                .overlay(alignment: .topTrailing) { badge }
            if showsReason, let reason = confidence.reason {
                Text(reason.label)
                    .font(.caption2)
                    .foregroundStyle(Theme.amber)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var edgeColor: Color {
        switch record.verdict {
        case .pending:
            if let tier { return RunCompleteStrip.color(for: tier) }
            return confidence.isConfident ? Theme.blue : Theme.amber
        case .correct, .corrected: return Theme.blue
        case .rejected, .voided: return Theme.muted
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch record.verdict {
        case .pending where isHeldForAudit:
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 16, height: 16)
                .background(Theme.blue, in: Circle())
                .offset(x: 4, y: -4)
        case .pending where tier == .possibleDuplicate:
            Image(systemName: "doc.on.doc")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 16, height: 16)
                .background(RunCompleteStrip.color(for: .possibleDuplicate), in: Circle())
                .offset(x: 4, y: -4)
        case .pending where !confidence.isConfident || tier?.needsAPerson == true:
            Text("?")
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 16, height: 16)
                .background(Theme.amber, in: Circle())
                .offset(x: 4, y: -4)
        case .correct, .corrected:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 16, height: 16)
                .background(Theme.blue, in: Circle())
                .offset(x: 4, y: -4)
        case .rejected:
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Theme.ground)
                .frame(width: 16, height: 16)
                .background(Theme.muted, in: Circle())
                .offset(x: 4, y: -4)
        case .pending, .voided:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        let name = record.topCandidate?.card.displayName ?? String(localized: "No match")
        switch record.verdict {
        case .pending:
            if let tier, tier != .confident, tier != .needsALook {
                return "\(name), \(tier.label.lowercased())"
            }
            if let reason = confidence.reason {
                return String(localized: "\(name), needs a look: \(reason.label)")
            }
            return isHeldForAudit ? String(localized: "\(name), confident, held for audit") : String(localized: "\(name), confident")
        case .correct: return String(localized: "\(name), confirmed")
        case .corrected: return String(localized: "\(name), corrected")
        case .rejected(let reason): return String(localized: "\(name), rejected: \(reason.label)")
        case .voided: return String(localized: "\(name), voided")
        }
    }
}
