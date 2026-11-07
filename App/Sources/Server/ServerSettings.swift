import Foundation
import Security

/// What the user can configure about the server: the fallback address when
/// neither name resolves, and the optional write token.
nonisolated struct ServerSettings: Hashable, Sendable {
    var manualEndpoint: URL?
    var token: String?

    init(manualEndpoint: URL? = ServerEndpoint.defaultManualURL, token: String? = nil) {
        self.manualEndpoint = manualEndpoint
        self.token = token
    }

    /// The probe order with this configuration's manual address last.
    var candidates: [ServerEndpoint] { ServerEndpoint.candidates(manual: manualEndpoint) }

    /// Parses what the user typed: a bare host gets `http://`, and nothing
    /// but http(s) with a host is accepted.
    static func parseEndpoint(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty else {
            return nil
        }
        return components.url
    }
}

/// Where the settings live. Endpoint in defaults, token in the Keychain.
nonisolated protocol ServerSettingsStoring: Sendable {
    func load() async -> ServerSettings
    func save(_ settings: ServerSettings) async throws
}

/// A single secret under a key; the live one is the Keychain.
nonisolated protocol SecretStoring: Sendable {
    func read(_ key: String) async throws -> String?
    /// `nil` deletes.
    func write(_ value: String?, for key: String) async throws
}

actor DefaultsServerSettingsStore: ServerSettingsStoring {
    static let endpointKey = "server.manualEndpoint"
    static let tokenKey = "server.token"

    private let defaults: UserDefaults
    private let secrets: any SecretStoring

    /// `UserDefaults` is thread-safe but not `Sendable`; the instance is
    /// handed over and owned by this actor from then on.
    init(defaults: sending UserDefaults, secrets: any SecretStoring) {
        self.defaults = defaults
        self.secrets = secrets
    }

    func load() async -> ServerSettings {
        let endpoint: URL?
        if let text = defaults.string(forKey: Self.endpointKey) {
            endpoint = text.isEmpty ? nil : URL(string: text)
        } else {
            endpoint = ServerEndpoint.defaultManualURL
        }
        let token = (try? await secrets.read(Self.tokenKey)).flatMap { $0 }
        return ServerSettings(manualEndpoint: endpoint, token: token?.isEmpty == false ? token : nil)
    }

    func save(_ settings: ServerSettings) async throws {
        defaults.set(settings.manualEndpoint?.absoluteString ?? "", forKey: Self.endpointKey)
        try await secrets.write(settings.token?.isEmpty == false ? settings.token : nil, for: Self.tokenKey)
    }
}

nonisolated enum KeychainError: Error, Hashable {
    case status(OSStatus)
}

/// Generic passwords in this app's Keychain, available after first unlock so
/// a background-resumed sync can read the token.
nonisolated struct KeychainSecretStore: SecretStoring {
    let service: String

    init(service: String = "com.nsluke.RiftboundScanner") {
        self.service = service
    }

    private func query(_ key: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: key]
    }

    func read(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func write(_ value: String?, for key: String) throws {
        let deleteStatus = SecItemDelete(query(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError.status(deleteStatus) }
        guard let value else { return }
        var attributes = query(key)
        attributes[kSecValueData] = Data(value.utf8)
        attributes[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }
}
