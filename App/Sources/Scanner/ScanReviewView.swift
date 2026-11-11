import CoreGraphics
import RiftboundRecognizer
import SwiftUI

/// Shows what the recogniser saw in a photo just taken by hand and collects
/// the verdict, with Retake. A stored scan opens in the review queue's
/// one-at-a-time view instead (`ReviewRoute.scans`).
struct ScanReviewView: View {
    let record: ScanRecord
    let photo: CGImage?
    let rectified: CGImage?
    let directory: CardDirectory
    let onVerdict: (Verdict) -> Void
    let onRetake: () -> Void

    @State private var isPickingCard = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    images
                }
                if let top = record.topCandidate {
                    Section("Best match") {
                        CandidateRow(candidate: top, rank: 1)
                        readingRows
                    }
                } else {
                    Section {
                        ContentUnavailableView("No match", systemImage: "questionmark.square.dashed", description: Text("Nothing in the index resembled this photo."))
                        readingRows
                    }
                }
                if record.candidates.count > 1 {
                    Section("Other candidates") {
                        ForEach(Array(record.candidates.dropFirst().enumerated()), id: \.element.card.id) { offset, candidate in
                            Button {
                                onVerdict(.corrected(candidate.card.id))
                            } label: {
                                CandidateRow(candidate: candidate, rank: offset + 2)
                            }
                            .accessibilityHint("Marks this card as the right one")
                        }
                    }
                }
                Section {
                    if record.verdict != .pending {
                        LabeledContent("Current verdict") {
                            VerdictBadge(verdict: record.verdict, directory: directory)
                        }
                    }
                    verdictButtons
                }
            }
            .navigationTitle("Review scan")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Retake", action: onRetake)
                }
            }
            .sheet(isPresented: $isPickingCard) {
                CardPickerView(directory: directory, suggestions: record.candidates.map(\.card)) { card in
                    isPickingCard = false
                    onVerdict(card.id == record.topCandidate?.card.id ? .correct : .corrected(card.id))
                }
                .sheetSizing()
            }
        }
    }

    private var images: some View {
        HStack(spacing: 12) {
            capturedImage(photo, label: "Captured photo")
            capturedImage(rectified, label: "Card as the recogniser saw it")
        }
        .frame(maxWidth: .infinity)
        .frame(height: 180)
    }

    @ViewBuilder
    private func capturedImage(_ image: CGImage?, label: LocalizedStringKey) -> some View {
        if let image {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel(label)
        } else {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .overlay { ProgressView() }
                .accessibilityLabel(label)
        }
    }

    @ViewBuilder
    private var readingRows: some View {
        if let reading = record.codeReading {
            LabeledContent("Code read", value: "\(reading.code.canonical) (\(reading.confidence.formatted(.percent.precision(.fractionLength(0)))))")
        } else {
            LabeledContent("Code read", value: String(localized: "None"))
        }
        LabeledContent("Time", value: Measurement(value: record.processingSeconds, unit: UnitDuration.seconds).formatted(.measurement(width: .narrow, numberFormatStyle: .number.precision(.fractionLength(1)))))
    }

    private var verdictButtons: some View {
        VStack(spacing: 10) {
            Button {
                onVerdict(.correct)
            } label: {
                Label("Correct", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(record.topCandidate == nil)

            Button {
                isPickingCard = true
            } label: {
                Label("Pick the right card…", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            Menu {
                ForEach(RejectionReason.allCases, id: \.self) { reason in
                    Button(reason.label) { onVerdict(.rejected(reason)) }
                }
            } label: {
                Label("Reject…", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
}
