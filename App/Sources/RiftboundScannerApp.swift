import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct RiftboundScannerApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        #if os(macOS)
        // One window: the camera, the feeder link and the sync engine each
        // belong to a single scanner, so a second window would fight the first.
        Window("Riftbound Scanner", id: "scanner") {
            content
                .frame(minWidth: 980, minHeight: 640)
                // The review palette is a dark ground; the window chrome matches it.
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Show Scans in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.scans])
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }
        }
        #else
        WindowGroup {
            content
        }
        #endif
    }

    /// Unit tests run inside the app. They get an empty window instead of a
    /// camera, a feeder link and a sync engine reaching for the home server.
    @ViewBuilder
    private var content: some View {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            BootstrapView(bootstrap: bootstrap)
        } else {
            Color.clear
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
