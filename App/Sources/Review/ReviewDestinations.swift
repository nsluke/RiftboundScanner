import SwiftUI

extension View {
    /// Resolves `ReviewRoute` values pushed from the Scan tab or History.
    /// `rule` is the installed confident tier, read when a route is opened.
    func reviewDestinations(store: any ScanStoring, directory: CardDirectory, vault: CardVault, rule: @escaping @Sendable () -> ConfidenceRule) -> some View {
        navigationDestination(for: ReviewRoute.self) { route in
            switch route {
            case .batch(let batch):
                BatchReviewView(batch: batch, store: store, directory: directory, vault: vault, rule: rule())
            case .scans(let batch, let ids, let start):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule(), mode: .browse(ids: ids, start: start)))
            case .spotCheck(let batch, let candidates, let limit):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, vault: vault, rule: rule(), mode: .spotCheck(candidates: candidates, limit: limit)))
            }
        }
    }
}
