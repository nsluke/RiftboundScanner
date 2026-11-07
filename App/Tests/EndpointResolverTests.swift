import Foundation
import Testing
@testable import RiftboundScannerApp

@Suite("Endpoint resolver")
struct EndpointResolverTests {
    private let healthy = ProbeOutcome.healthy(HealthReport(status: "ok", userVersion: 5))
    private let manual = ServerEndpoint(url: URL(string: "http://192.168.1.155:8096")!, kind: .manual)

    private func makeResolver(
        probe: ScriptedProbe,
        paths: ScriptedPaths = ScriptedPaths(.wifi),
        clock: TestClock = TestClock()
    ) -> EndpointResolver<TestClock> {
        EndpointResolver(
            candidates: { [manual] in [.lan, .local, manual] },
            probe: probe,
            paths: paths,
            clock: clock,
            now: { Fixtures.epoch.addingTimeInterval(clock.now.offset.seconds) }
        )
    }

    @Test func aCellularOnlyPathIsNeverProbed() async {
        let probe = ScriptedProbe([.lan: healthy])
        let resolver = makeResolver(probe: probe, paths: ScriptedPaths(.cellularOnly))
        #expect(await resolver.resolve() == .unavailable(.cellularOnly))
        #expect(await probe.probed.isEmpty)
        #expect(await resolver.probeCount == 0)
    }

    @Test func noPathIsOffline() async {
        let probe = ScriptedProbe([.lan: healthy])
        let resolver = makeResolver(probe: probe, paths: ScriptedPaths(.offline))
        #expect(await resolver.resolve() == .unavailable(.noPath))
        #expect(await probe.probed.isEmpty)
    }

    @Test func aTunnelPathCountsAsHome() async {
        let probe = ScriptedProbe([.lan: healthy])
        let resolver = makeResolver(probe: probe, paths: ScriptedPaths(.tunnel))
        #expect(await resolver.resolve().endpoint == .lan)
    }

    @Test func picksLanWhenItIsHealthy() async {
        let probe = ScriptedProbe([.lan: healthy, .local: healthy, .manual: healthy])
        let resolver = makeResolver(probe: probe)
        let resolution = await resolver.resolve()
        #expect(resolution == .available(.lan, health: HealthReport(status: "ok", userVersion: 5)))
        #expect(await probe.probed == [.lan], "the first healthy candidate ends the cycle")
    }

    @Test func fallsBackToLocalThenManual() async {
        let probe = ScriptedProbe([.lan: .unhealthy("dns"), .local: healthy])
        let resolver = makeResolver(probe: probe)
        #expect(await resolver.resolve().endpoint == .local)
        #expect(await probe.probed == [.lan, .local])

        let manualOnly = ScriptedProbe([.manual: healthy])
        let second = makeResolver(probe: manualOnly)
        #expect(await second.resolve().endpoint == manual)
        #expect(await manualOnly.probed == [.lan, .local, .manual])
    }

    @Test func cachesForTenMinutes() async {
        let clock = TestClock()
        let probe = ScriptedProbe([.lan: healthy])
        let resolver = makeResolver(probe: probe, clock: clock)
        _ = await resolver.resolve()
        clock.advance(by: .seconds(9 * 60 + 59))
        _ = await resolver.resolve()
        #expect(await resolver.probeCount == 1, "a fresh cache answers without probing")
        #expect(await resolver.lastKnownEndpoint == .lan)

        clock.advance(by: .seconds(1))
        _ = await resolver.resolve()
        #expect(await resolver.probeCount == 2, "the cache expires after ten minutes")
    }

    @Test func backsOffFiveMinutesAfterAFailedCycle() async {
        let clock = TestClock()
        let probe = ScriptedProbe([:])
        let resolver = makeResolver(probe: probe, clock: clock)

        let first = await resolver.resolve()
        #expect(first == .unavailable(.backingOff(retryAt: Fixtures.epoch.addingTimeInterval(300))))
        #expect(await probe.probed == [.lan, .local, .manual])

        clock.advance(by: .seconds(4 * 60))
        await probe.set(.lan, healthy)
        #expect(await resolver.resolve() == first, "inside the backoff nothing is probed even though the server is back")
        #expect(await resolver.probeCount == 1)

        clock.advance(by: .seconds(60))
        #expect(await resolver.resolve().endpoint == .lan)
        #expect(await resolver.probeCount == 2)
    }

    @Test func invalidateClearsTheBackoffAndTheCache() async {
        let clock = TestClock()
        let probe = ScriptedProbe([:])
        let resolver = makeResolver(probe: probe, clock: clock)
        _ = await resolver.resolve()
        await probe.set(.lan, healthy)
        await resolver.invalidate()
        #expect(await resolver.resolve().endpoint == .lan)

        await probe.set(.lan, .unhealthy("down"))
        await probe.set(.manual, healthy)
        await resolver.invalidate()
        #expect(await resolver.resolve().endpoint == manual, "invalidate forgets the cached .lan hit")
    }

    @Test func pathChangesAreCheckedBeforeTheCache() async {
        let paths = ScriptedPaths(.wifi)
        let probe = ScriptedProbe([.lan: healthy])
        let resolver = makeResolver(probe: probe, paths: paths)
        _ = await resolver.resolve()
        await paths.set(.cellularOnly)
        #expect(await resolver.resolve() == .unavailable(.cellularOnly), "a cached endpoint is not used over cellular")
        await paths.set(.wifi)
        #expect(await resolver.resolve().endpoint == .lan)
        #expect(await resolver.probeCount == 1)
    }

    @Test func pathSummariesClassifyInterfaces() {
        #expect(NetworkPathSummary.wifi.reachesHomeNetwork)
        #expect(NetworkPathSummary.tunnel.reachesHomeNetwork)
        #expect(!NetworkPathSummary.cellularOnly.reachesHomeNetwork)
        #expect(!NetworkPathSummary.offline.reachesHomeNetwork)
        #expect(NetworkPathSummary(isSatisfied: true, interfaces: [.wired]).reachesHomeNetwork)
        #expect(NetworkPathSummary(isSatisfied: true, interfaces: [.other("awdl0")]).unavailability == .cellularOnly)
    }

    @Test func candidateOrderIsLanLocalManual() {
        let settings = ServerSettings(manualEndpoint: manual.url)
        #expect(settings.candidates == [.lan, .local, manual])
        #expect(ServerSettings(manualEndpoint: nil).candidates == [.lan, .local])
    }
}
