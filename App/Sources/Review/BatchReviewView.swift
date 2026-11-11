import SwiftUI

/// The one screen for a batch, however it was opened: the run strip, History
/// or an imported server batch. It opens on what still needs a look, as a
/// grid on the Mac and one at a time on the iPhone, and switches to every
/// scan in the batch grouped by what it needs. Any scan opened from either
/// goes to the same one-at-a-time view and fix panel.
struct BatchReviewView: View {
    enum Section: Hashable {
        case toReview
        case all
    }

    /// How "To review" settles the uncertain scans. A Mac window fits a run's
    /// scans side by side, so it triages them in a grid first; the iPhone
    /// walks them one at a time.
    enum ReviewStyle: Hashable {
        case grid
        case oneAtATime

        static var platform: ReviewStyle {
            #if os(macOS)
            .grid
            #else
            .oneAtATime
            #endif
        }
    }

    let batch: ScanBatch
    let store: any ScanStoring
    let directory: CardDirectory
    let vault: CardVault
    /// The confident tier the screen was opened under, fixed for its lifetime.
    let rule: ConfidenceRule

    /// `nil` until the batch has been read, so the screen opens on the right section.
    @State private var section: Section?

    var body: some View {
        Group {
            switch section {
            case nil:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .toReview:
                toReview
            case .all:
                BatchOverviewView(
                    model: BatchDetailModel(batch: batch, store: store, directory: directory),
                    directory: directory,
                    onReview: { section = .toReview }
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $section) {
                    Text("To review").tag(Section?.some(.toReview))
                    Text("All scans").tag(Section?.some(.all))
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .disabled(section == nil)
            }
        }
        .task {
            guard section == nil else { return }
            let records = (try? await store.records(in: batch.id)) ?? []
            section = records.contains(where: \.needsReview) ? .toReview : .all
        }
    }

    @ViewBuilder
    private var toReview: some View {
        switch ReviewStyle.platform {
        case .grid:
            ReviewTriageView(
                model: ReviewTriageModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule),
                makeQueue: { [batch, store, directory, vault, rule] flagged in
                    ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule, flagged: flagged)
                }
            )
        case .oneAtATime:
            ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule))
        }
    }
}
