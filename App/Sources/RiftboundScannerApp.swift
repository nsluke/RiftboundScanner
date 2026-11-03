import SwiftUI

@main
struct RiftboundScannerApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            BootstrapView(bootstrap: bootstrap)
        }
    }
}

/// Loads the card index and wires the dependency graph once, off the main actor,
/// so launch shows a loading state instead of a hang.
@Observable
final class AppBootstrap {
    private(set) var state: Loadable<AppDependencies, BootstrapError> = .idle

    func load() async {
        state = .loading
        do {
            state = .loaded(try await AppDependencies.live())
        } catch {
            state = .failed(error)
        }
    }
}

struct BootstrapView: View {
    let bootstrap: AppBootstrap

    var body: some View {
        Group {
            switch bootstrap.state {
            case .idle, .loading:
                ProgressView("Loading card index…")
            case .loaded(let dependencies):
                RootView(dependencies: dependencies)
            case .failed(let error):
                ContentUnavailableView {
                    Label("Card index unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error.message)
                } actions: {
                    Button("Try again") { Task { await bootstrap.load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .task { await bootstrap.load() }
    }
}
