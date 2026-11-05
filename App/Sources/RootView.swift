import SwiftUI

struct RootView: View {
    let dependencies: AppDependencies
    @State private var scanner: ScannerModel
    @State private var history: HistoryModel

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _scanner = State(wrappedValue: ScannerModel(
            camera: dependencies.camera,
            feeder: dependencies.makeFeeder(),
            identifier: dependencies.identifier,
            store: dependencies.store,
            makeBatch: dependencies.makeBatch,
            now: dependencies.now,
            makeID: dependencies.makeID
        ))
        _history = State(wrappedValue: HistoryModel(store: dependencies.store))
    }

    var body: some View {
        TabView {
            Tab("Scan", systemImage: "camera.viewfinder") {
                ScannerView(model: scanner, session: dependencies.camera.session, directory: dependencies.directory)
            }
            Tab("History", systemImage: "list.bullet.rectangle") {
                NavigationStack {
                    HistoryView(model: history, store: dependencies.store, directory: dependencies.directory, index: dependencies.index, now: dependencies.now)
                }
            }
        }
    }
}
