import SwiftUI

extension View {
    /// Resolves `ReviewRoute` values pushed from the Scan tab or History.
    /// `rule` is the installed confident tier, read when a route is opened.
    func reviewDestinations(store: any ScanStoring, directory: CardDirectory, vault: CardVault, rule: @escaping @Sendable () -> ConfidenceRule) -> some View {
        navigationDestination(for: ReviewRoute.self) { route in
            switch route {
            case .queue(let batch):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule()))
            case .triage(let batch):
                let installed = rule()
                ReviewTriageView(
                    model: ReviewTriageModel(batch: batch, store: store, directory: directory, vault: vault, rule: installed),
                    makeQueue: { flagged in
                        ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: installed, flagged: flagged)
                    }
                )
            case .overview(let batch):
                BatchOverviewView(model: BatchDetailModel(batch: batch, store: store, directory: directory), directory: directory)
            case .spotCheck(let batch, let candidates, let limit):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule(), mode: .spotCheck(candidates: candidates, limit: limit)))
            }
        }
    }
}
