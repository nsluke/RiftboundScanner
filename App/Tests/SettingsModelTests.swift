import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Settings model")
struct SettingsModelTests {
    private let index = IndexSummary(builtAt: Fixtures.epoch, entryCount: 2, formatVersion: 1)

    private func makeModel(
        store: InMemoryServerSettingsStore = InMemoryServerSettingsStore(),
        client: StubCollectionClient = StubCollectionClient(),
        endpoints: FixedEndpoints = FixedEndpoints(.available(.lan, health: HealthReport(userVersion: 5)))
    ) -> SettingsModel {
        SettingsModel(settingsStore: store, client: client, endpoints: endpoints, paths: nil, appVersion: "0.2.0", index: index)
    }

    @Test func loadFillsTheFieldsFromTheStore() async {
        let store = InMemoryServerSettingsStore(ServerSettings(manualEndpoint: URL(string: "http://10.0.0.5:8096"), token: "t0k"))
        let model = makeModel(store: store)
        #expect(!model.isLoaded)
        await model.load()
        #expect(model.isLoaded)
        #expect(model.manualEndpointText == "http://10.0.0.5:8096")
        #expect(model.token == "t0k")
    }

    @Test func testConnectionShowsTheHealthFields() async {
        let model = makeModel()
        await model.testConnection()
        guard case .loaded(let connection) = model.connection else {
            Issue.record("expected a connection, got \(model.connection)")
            return
        }
        #expect(connection.endpoint == .lan)
        #expect(connection.isSupported)
        #expect(connection.health.cards == 1822)
        #expect(connection.health.catalogVersion == "cat-1")
    }

    @Test func anOutdatedServerIsAConnectionThatNeedsUpdating() async {
        let outdated = HealthReport(status: "ok", version: "0.1.0", cards: 1822, userVersion: 1)
        let client = StubCollectionClient()
        await client.update { $0.health = .failure(.serverOutdated(outdated)) }
        let model = makeModel(client: client)
        await model.testConnection()
        guard case .loaded(let connection) = model.connection else {
            Issue.record("expected a connection, got \(model.connection)")
            return
        }
        #expect(!connection.isSupported)
        #expect(connection.health == outdated)
        #expect(ServerError.serverOutdated(outdated).message.contains("Server needs updating"))
    }

    @Test func noEndpointIsAFailureWithAReason() async {
        let endpoints = FixedEndpoints(.unavailable(.cellularOnly))
        let model = makeModel(endpoints: endpoints)
        await model.testConnection()
        guard case .failed(let error) = model.connection else {
            Issue.record("expected a failure, got \(model.connection)")
            return
        }
        #expect(error == .noEndpoint(.cellularOnly))
        #expect(await endpoints.invalidations == 1, "Test connection probes afresh")
    }

    @Test func aFailingHealthIsAFailure() async {
        let client = StubCollectionClient()
        await client.update { $0.health = .failure(.timedOut) }
        let model = makeModel(client: client)
        await model.testConnection()
        guard case .failed(let error) = model.connection else {
            Issue.record("expected a failure, got \(model.connection)")
            return
        }
        #expect(error == .timedOut)
    }

    @Test func saveParsesTheAddressPersistsAndInvalidatesDiscovery() async {
        let store = InMemoryServerSettingsStore()
        let endpoints = FixedEndpoints(.available(.lan, health: HealthReport()))
        let model = makeModel(store: store, endpoints: endpoints)
        await model.load()
        model.manualEndpointText = " 192.168.1.155:8096/ "
        model.token = "abc"
        #expect(model.endpointIsValid)
        await model.save()
        #expect(model.saveProblem == nil)
        #expect(model.manualEndpointText == "http://192.168.1.155:8096")
        #expect(await store.settings == ServerSettings(manualEndpoint: URL(string: "http://192.168.1.155:8096"), token: "abc"))
        #expect(await endpoints.invalidations == 1)

        model.manualEndpointText = ""
        model.token = ""
        await model.save()
        #expect(await store.settings == ServerSettings(manualEndpoint: nil, token: nil))
    }

    @Test func anUnparseableAddressIsRefused() async {
        let store = InMemoryServerSettingsStore()
        let model = makeModel(store: store)
        await model.load()
        model.manualEndpointText = "ftp://nope"
        #expect(!model.endpointIsValid)
        await model.save()
        #expect(model.saveProblem != nil)
        #expect(await store.saveCount == 0)
    }

    @Test func endpointParsingAcceptsHostsAndRejectsJunk() {
        #expect(ServerSettings.parseEndpoint("riftbound.lan") == URL(string: "http://riftbound.lan"))
        #expect(ServerSettings.parseEndpoint("http://192.168.1.155:8096/") == URL(string: "http://192.168.1.155:8096"))
        #expect(ServerSettings.parseEndpoint("https://pi.example") == URL(string: "https://pi.example"))
        #expect(ServerSettings.parseEndpoint("") == nil)
        #expect(ServerSettings.parseEndpoint("ftp://x") == nil)
        #expect(ServerSettings.parseEndpoint("http://") == nil)
    }
}

@Suite("Server settings store")
struct ServerSettingsStoreTests {
    @Test func roundTripsThroughDefaultsAndTheSecretStore() async throws {
        let suite = "ServerSettingsStoreTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let secrets = InMemorySecretStore()
        // UserDefaults is not Sendable: the store gets its own instance and the
        // assertions below open the same suite again.
        let store = DefaultsServerSettingsStore(defaults: UserDefaults(suiteName: suite)!, secrets: secrets)

        #expect(await store.load() == ServerSettings(manualEndpoint: ServerEndpoint.defaultManualURL, token: nil), "a fresh install falls back to the Pi's LAN address")

        try await store.save(ServerSettings(manualEndpoint: URL(string: "http://10.0.0.9:8096"), token: "tok"))
        #expect(await store.load() == ServerSettings(manualEndpoint: URL(string: "http://10.0.0.9:8096"), token: "tok"))
        #expect(await secrets.values[DefaultsServerSettingsStore.tokenKey] == "tok")
        #expect(UserDefaults(suiteName: suite)?.string(forKey: DefaultsServerSettingsStore.endpointKey) == "http://10.0.0.9:8096")

        try await store.save(ServerSettings(manualEndpoint: nil, token: nil))
        #expect(await store.load() == ServerSettings(manualEndpoint: nil, token: nil), "an emptied address stays empty rather than reverting to the default")
        #expect(await secrets.values[DefaultsServerSettingsStore.tokenKey] == nil)
    }

    @Test func keychainStoreWritesReadsAndDeletes() async throws {
        let keychain = KeychainSecretStore(service: "com.nsluke.RiftboundScanner.tests")
        let key = "token-\(UUID().uuidString)"
        #expect(try await keychain.read(key) == nil)
        try await keychain.write("first", for: key)
        #expect(try await keychain.read(key) == "first")
        try await keychain.write("second", for: key)
        #expect(try await keychain.read(key) == "second")
        try await keychain.write(nil, for: key)
        #expect(try await keychain.read(key) == nil)
    }
}
