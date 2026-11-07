import SwiftUI

/// What a finished feed-and-scan run leaves on the Scan tab: this run's scans
/// at a glance, split into the ones the recogniser is sure of and the ones
/// that need a look, with the next step for each.
struct RunCompleteStrip: View {
    let model: ScannerModel
    let progress: ScannerModel.AutoScanProgress
    let reason: ScannerModel.AutoScanEnd

    private var records: [ScanRecord] { model.runRecords }
    private var uncertain: [ScanRecord] { records.filter(\.needsReview) }
    private var confident: [ScanRecord] { records.filter(\.isAutoConfirmable) }
    private var accepted: Int { records.filter { $0.verdict != .pending }.count }

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
                    ScanThumbnail(record: record, url: model.photoURL(for: record), width: 44)
                }
            }
        }
        .scrollIndicators(.hidden)
        .accessibilityLabel("\(records.count) scans from this run")
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Circle().fill(Theme.blue).frame(width: 8, height: 8)
            Text("\(confident.count + accepted) confident, code read")
            Text("·").foregroundStyle(Theme.muted)
            Circle().fill(Theme.amber).frame(width: 8, height: 8)
            Text("\(uncertain.count) need a look")
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var actions: some View {
        if let batch = model.batch {
            VStack(spacing: 8) {
                if !uncertain.isEmpty {
                    NavigationLink(value: ReviewRoute.queue(batch)) {
                        Text("Review \(uncertain.count) uncertain")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.amber)
                    .foregroundStyle(Theme.ground)
                }
                if !confident.isEmpty {
                    Button {
                        Task { await model.acceptConfidentScans() }
                    } label: {
                        Text(uncertain.isEmpty ? "Accept the \(confident.count) confident" : "Accept the \(confident.count) confident, finish later")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Theme.blue)
                    .accessibilityHint("Marks the confident scans correct without reviewing them")
                }
                if uncertain.isEmpty, confident.isEmpty {
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

    private var height: CGFloat { width * 88 / 63 }

    var body: some View {
        VStack(spacing: 4) {
            ThumbnailImage(url: url, maxPixelSize: Int(width * 3))
                .frame(width: width, height: height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(edgeColor, lineWidth: 2))
                .overlay(alignment: .topTrailing) { badge }
            if showsReason, let reason = record.confidence.reason {
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
        case .pending: record.confidence.isConfident ? Theme.blue : Theme.amber
        case .correct, .corrected: Theme.blue
        case .rejected: Theme.muted
        }
    }

    @ViewBuilder
    private var badge: some View {
        switch record.verdict {
        case .pending where !record.confidence.isConfident:
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
        case .pending:
            EmptyView()
        }
    }

    private var accessibilityText: String {
        let name = record.topCandidate?.card.displayName ?? String(localized: "No match")
        switch record.verdict {
        case .pending:
            if let reason = record.confidence.reason {
                return String(localized: "\(name), needs a look: \(reason.label)")
            }
            return String(localized: "\(name), confident")
        case .correct: return String(localized: "\(name), confirmed")
        case .corrected: return String(localized: "\(name), corrected")
        case .rejected(let reason): return String(localized: "\(name), rejected: \(reason.label)")
        }
    }
}
