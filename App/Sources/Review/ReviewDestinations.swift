import SwiftUI

extension View {
    /// Resolves `ReviewRoute` values pushed from the Scan tab or History.
    func reviewDestinations(store: any ScanStoring, directory: CardDirectory) -> some View {
        navigationDestination(for: ReviewRoute.self) { route in
            switch route {
            case .queue(let batch):
                ReviewQueueView(model: ReviewQueueModel(batch: batch, store: store, directory: directory))
            case .overview(let batch):
                BatchOverviewView(model: BatchDetailModel(batch: batch, store: store, directory: directory), directory: directory)
            }
        }
    }
}
