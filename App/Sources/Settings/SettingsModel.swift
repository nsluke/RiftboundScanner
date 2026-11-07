import Foundation

/// The Settings screen's state: the editable server configuration and the
/// outcome of the last connection test.
@Observable
final class SettingsModel {
    /// A server that answered `/health`, supported or not.
    nonisolated struct Connection: Hashable, Sendable {
        let endpoint: ServerEndpoint
        let health: HealthReport

        var isSupported: Bool { health.isSupported }
    }

    nonisolated struct Storage: Hashable, Sendable {
        let syncBytes: Int
        let learningBytes: Int
        let catalogBytes: Int
    }

    private(set) var connection: Loadable<Connection, ServerError> = .idle
    /// The server's view of the confident tier: the Wilson bound and the
    /// audit counts (ADR-002, decision 9). Loaded with the screen; "offline"
    /// is a failure state with the server's reason, not a blank card.
    private(set) var learning: Loadable<LearningStats, ServerError> = .idle
    private(set) var storage: Storage?
    /// Whether the fields hold what is on disk; the view shows a placeholder until then.
    private(set) var isLoaded = false
    private(set) var saveProblem: String?

    var manualEndpointText = ""
    var token = ""

    let appVersion: String
    let index: IndexSummary

    private let settingsStore: any ServerSettingsStoring
    private let client: any CollectionServing
    private let endpoints: any EndpointResolving
    private let paths: AppPaths?
    private let confidenceRule: @Sendable () -> ConfidenceRule

    init(
        settingsStore: any ServerSettingsStoring,
        client: any CollectionServing,
        endpoints: any EndpointResolving,
        paths: AppPaths?,
        appVersion: String,
        index: IndexSummary,
        confidenceRule: @escaping @Sendable () -> ConfidenceRule = { .default }
    ) {
        self.settingsStore = settingsStore
        self.client = client
        self.endpoints = endpoints
        self.paths = paths
        self.appVersion = appVersion
        self.index = index
        self.confidenceRule = confidenceRule
    }

    /// The confident tier in force; the Learning card shows its audit rate.
    var rule: ConfidenceRule { confidenceRule() }

    /// The address as it would be saved, or `nil` when the text is not a URL.
    var parsedEndpoint: URL? { ServerSettings.parseEndpoint(manualEndpointText) }

    var endpointIsValid: Bool {
        manualEndpointText.trimmingCharacters(in: .whitespaces).isEmpty || parsedEndpoint != nil
    }

    func load() async {
        let settings = await settingsStore.load()
        manualEndpointText = settings.manualEndpoint?.absoluteString ?? ""
        token = settings.token ?? ""
        isLoaded = true
        refreshStorage()
        await refreshLearning()
    }

    /// Reads `/api/learning/stats`. A server without the route yet (`notFound`)
    /// or no reachable server leaves the card in its failed state with the reason.
    func refreshLearning() async {
        learning = .loading
        do {
            learning = .loaded(try await client.learningStats())
        } catch {
            learning = .failed(error)
        }
    }

    /// Writes the fields and forgets the resolved endpoint, since the
    /// candidate list may have changed.
    func save() async {
        saveProblem = nil
        let trimmed = manualEndpointText.trimmingCharacters(in: .whitespaces)
        let endpoint: URL?
        if trimmed.isEmpty {
            endpoint = nil
        } else if let parsed = parsedEndpoint {
            endpoint = parsed
            manualEndpointText = parsed.absoluteString
        } else {
            saveProblem = String(localized: "Enter a host or address such as 192.168.1.155:8096.")
            return
        }
        do {
            try await settingsStore.save(ServerSettings(manualEndpoint: endpoint, token: token.isEmpty ? nil : token))
            await endpoints.invalidate()
        } catch {
            saveProblem = String(localized: "The settings could not be saved. \(String(describing: error))")
        }
    }

    /// Probes afresh and reads `/health`. An outdated server is a
    /// *connection* with a warning, not a failure: its fields still show.
    func testConnection() async {
        connection = .loading
        await endpoints.invalidate()
        switch await endpoints.resolve() {
        case .unavailable(let reason):
            connection = .failed(.noEndpoint(reason))
        case .available(let endpoint, _):
            do {
                connection = .loaded(Connection(endpoint: endpoint, health: try await client.health()))
            } catch ServerError.serverOutdated(let report) {
                connection = .loaded(Connection(endpoint: endpoint, health: report))
            } catch {
                connection = .failed(error)
            }
        }
    }

    func refreshStorage() {
        guard let paths else { return }
        storage = Storage(syncBytes: paths.size(of: paths.sync), learningBytes: paths.size(of: paths.learning), catalogBytes: paths.size(of: paths.catalog))
    }
}
