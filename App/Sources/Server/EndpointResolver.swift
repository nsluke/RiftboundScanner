import Foundation
import Network

/// Where the server might be. `.lan` is the UniFi name that also works over
/// the VPN, `.local` is mDNS at home, `.manual` is the address in Settings.
nonisolated struct ServerEndpoint: Hashable, Sendable, Identifiable {
    nonisolated enum Kind: String, Hashable, Sendable, Codable {
        case lan
        case local
        case manual
    }

    let url: URL
    let kind: Kind

    var id: String { url.absoluteString }

    static let lan = ServerEndpoint(url: URL(string: "http://riftbound.lan")!, kind: .lan)
    static let local = ServerEndpoint(url: URL(string: "http://riftbound.local")!, kind: .local)
    static let defaultManualURL = URL(string: "http://192.168.1.155:8096")!

    /// The probe order: `.lan`, `.local`, then the manual address.
    static func candidates(manual: URL?) -> [ServerEndpoint] {
        var list = [lan, local]
        if let manual {
            list.append(ServerEndpoint(url: manual, kind: .manual))
        }
        return list
    }
}

/// The resolved server, or why there is none.
nonisolated enum EndpointResolution: Hashable, Sendable {
    case available(ServerEndpoint, health: HealthReport)
    case unavailable(EndpointUnavailability)

    var endpoint: ServerEndpoint? {
        if case .available(let endpoint, _) = self { return endpoint }
        return nil
    }
}

/// What the sync layer needs from discovery.
nonisolated protocol EndpointResolving: Sendable {
    /// The cached endpoint when fresh, otherwise a probe cycle.
    func resolve() async -> EndpointResolution
    /// Forgets the cached endpoint and any backoff, so the next `resolve()` probes.
    func invalidate() async
}

// MARK: - Network path

/// The one fact discovery needs about the network: is there a path the
/// server could be on? Wi-Fi, wired and tunnel (utun, the VPN) qualify;
/// cellular alone never does.
nonisolated struct NetworkPathSummary: Hashable, Sendable {
    nonisolated enum Interface: Hashable, Sendable {
        case wifi
        case wired
        case tunnel
        case cellular
        case other(String)
    }

    let isSatisfied: Bool
    let interfaces: Set<Interface>

    init(isSatisfied: Bool, interfaces: Set<Interface>) {
        self.isSatisfied = isSatisfied
        self.interfaces = interfaces
    }

    static let offline = NetworkPathSummary(isSatisfied: false, interfaces: [])
    static let wifi = NetworkPathSummary(isSatisfied: true, interfaces: [.wifi])
    static let cellularOnly = NetworkPathSummary(isSatisfied: true, interfaces: [.cellular])
    static let tunnel = NetworkPathSummary(isSatisfied: true, interfaces: [.tunnel, .cellular])

    /// Whether the server should be probed over this path.
    var reachesHomeNetwork: Bool {
        isSatisfied && !interfaces.isDisjoint(with: [.wifi, .wired, .tunnel])
    }

    var unavailability: EndpointUnavailability? {
        if !isSatisfied { return .noPath }
        if !reachesHomeNetwork { return .cellularOnly }
        return nil
    }

    init(_ path: NWPath) {
        isSatisfied = path.status == .satisfied
        interfaces = Set(path.availableInterfaces.map { interface in
            switch interface.type {
            case .wifi: .wifi
            case .wiredEthernet: .wired
            case .cellular: .cellular
            case .loopback: .other(interface.name)
            case .other: interface.name.hasPrefix("utun") || interface.name.hasPrefix("ipsec") || interface.name.hasPrefix("ppp") ? .tunnel : .other(interface.name)
            @unknown default: .other(interface.name)
            }
        })
    }
}

nonisolated protocol NetworkPathObserving: Sendable {
    func currentPath() async -> NetworkPathSummary
}

/// Reads the live path from `NWPathMonitor`.
actor LiveNetworkPathSource: NetworkPathObserving {
    private let monitor: NWPathMonitor

    init() {
        monitor = NWPathMonitor()
        monitor.start(queue: DispatchQueue(label: "com.nsluke.RiftboundScanner.path"))
    }

    func currentPath() -> NetworkPathSummary {
        NetworkPathSummary(monitor.currentPath)
    }
}

// MARK: - Probing

nonisolated enum ProbeOutcome: Hashable, Sendable {
    case healthy(HealthReport)
    case unhealthy(String)
}

/// Asks one candidate for `/health` within a short timeout.
nonisolated protocol EndpointProbing: Sendable {
    func probe(_ endpoint: ServerEndpoint, timeout: Duration) async -> ProbeOutcome
}

/// The live probe: a cache-free `URLSession` GET of `/health`. A server
/// answering with an outdated schema is still *found*; Settings explains it.
nonisolated struct URLSessionEndpointProbe: EndpointProbing {
    private let session: URLSession

    init(session: URLSession = HTTPCollectionClient.makeSession()) {
        self.session = session
    }

    func probe(_ endpoint: ServerEndpoint, timeout: Duration) async -> ProbeOutcome {
        var request = URLRequest(url: endpoint.url.appending(path: "health"))
        request.timeoutInterval = timeout.seconds
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .unhealthy("not HTTP") }
            guard (200..<300).contains(http.statusCode) else { return .unhealthy("status \(http.statusCode)") }
            return .healthy(try JSONDecoder.server.decode(HealthReport.self, from: data))
        } catch {
            return .unhealthy(String(describing: error))
        }
    }
}

// MARK: - Resolver

/// Finds the server: `/health` on `.lan`, then `.local`, then the manual
/// address, 3 s per probe, only over Wi-Fi, wired or tunnel paths. A hit is
/// cached for 10 minutes; a cycle where nothing answers backs off 5 minutes.
/// Time comes from the injected clock, so tests move it instantly.
actor EndpointResolver<C: Clock>: EndpointResolving where C.Duration == Duration {
    nonisolated struct Policy: Hashable, Sendable {
        var probeTimeout: Duration = .seconds(3)
        var cacheLifetime: Duration = .seconds(600)
        var backoff: Duration = .seconds(300)

        init(probeTimeout: Duration = .seconds(3), cacheLifetime: Duration = .seconds(600), backoff: Duration = .seconds(300)) {
            self.probeTimeout = probeTimeout
            self.cacheLifetime = cacheLifetime
            self.backoff = backoff
        }
    }

    private let candidates: @Sendable () async -> [ServerEndpoint]
    private let probe: any EndpointProbing
    private let paths: any NetworkPathObserving
    private let clock: C
    private let now: @Sendable () -> Date
    private let policy: Policy

    private var cached: (resolution: EndpointResolution, expiresAt: C.Instant)?
    private var backoffUntil: (instant: C.Instant, date: Date)?
    private var inFlight: Task<EndpointResolution, Never>?
    /// Every probe cycle so far, for diagnostics and tests.
    private(set) var probeCount = 0

    init(
        candidates: @escaping @Sendable () async -> [ServerEndpoint],
        probe: any EndpointProbing,
        paths: any NetworkPathObserving,
        clock: C,
        now: @escaping @Sendable () -> Date,
        policy: Policy = Policy()
    ) {
        self.candidates = candidates
        self.probe = probe
        self.paths = paths
        self.clock = clock
        self.now = now
        self.policy = policy
    }

    func resolve() async -> EndpointResolution {
        let path = await paths.currentPath()
        if let unavailability = path.unavailability {
            return .unavailable(unavailability)
        }
        if let cached, cached.expiresAt > clock.now {
            return cached.resolution
        }
        cached = nil
        if let backoffUntil {
            if backoffUntil.instant > clock.now {
                return .unavailable(.backingOff(retryAt: backoffUntil.date))
            }
            self.backoffUntil = nil
        }
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await self.probeCycle() }
        inFlight = task
        let resolution = await task.value
        inFlight = nil
        return resolution
    }

    func invalidate() {
        cached = nil
        backoffUntil = nil
    }

    /// The cached endpoint without probing, for callers that only want to
    /// know whether discovery has succeeded recently.
    var lastKnownEndpoint: ServerEndpoint? {
        cached?.resolution.endpoint
    }

    private func probeCycle() async -> EndpointResolution {
        probeCount += 1
        for endpoint in await candidates() {
            if case .healthy(let report) = await probe.probe(endpoint, timeout: policy.probeTimeout) {
                let resolution = EndpointResolution.available(endpoint, health: report)
                cached = (resolution, clock.now.advanced(by: policy.cacheLifetime))
                return resolution
            }
        }
        let retryAt = now().addingTimeInterval(policy.backoff.seconds)
        backoffUntil = (clock.now.advanced(by: policy.backoff), retryAt)
        return .unavailable(.backingOff(retryAt: retryAt))
    }
}
