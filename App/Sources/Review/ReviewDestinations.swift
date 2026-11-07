import SwiftUI

extension View {
    /// Resolves `ReviewRoute` values pushed from the Scan tab or History.
    /// `rule` is the installed confident tier, read when a route is opened.
    func reviewDestinations(store: any ScanStoring, directory: CardDirectory, rule: @escaping @Sendable () -> ConfidenceRule) -> some View {
        navigationDestination(for: ReviewRoute.self) { route in
            switch route {
            case .queue(let batch):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, rule: rule()))
            case .overview(let batch):
                BatchOverviewView(model: BatchDetailModel(batch: batch, store: store, directory: directory), directory: directory)
            case .spotCheck(let batch, let candidates, let limit):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory, rule: rule(), mode: .spotCheck(candidates: candidates, limit: limit)))
            }
        }
    }
}
