import Foundation

/// A feeder with no hardware behind it, for previews and tests. Each feed takes
/// the next scripted outcome; once the script runs out it behaves like an empty
/// hopper and times out.
@Observable
final class StubFeeder: FeederControlling {
    enum FeedOutcome: Sendable {
        case fed
        case failed(FeederError)
        /// Never completes on its own, so a test can cancel it; stands in for a
        /// feed the user interrupts.
        case hangs
    }

    private(set) var state: FeederState
    private(set) var feedCount = 0
    private(set) var connectCount = 0
    private(set) var stopCount = 0
    private(set) var disconnectCount = 0
    private var script: [FeedOutcome]
    private let firmwareVersion: String

    init(state: FeederState = .idle, script: [FeedOutcome] = [], firmwareVersion: String = "0.1.5") {
        self.state = state
        self.script = script
        self.firmwareVersion = firmwareVersion
    }

    func connect() {
        connectCount += 1
        state = .ready(firmwareVersion: firmwareVersion)
    }

    func feedOneCard(timeout: Duration) async throws {
        guard case .ready = state else { throw FeederError.notReady(state) }
        feedCount += 1
        state = .feeding
        defer { state = .ready(firmwareVersion: firmwareVersion) }
        guard !script.isEmpty else { throw FeederError.timedOut }
        switch script.removeFirst() {
        case .fed:
            await Task.yield()
        case .failed(let error):
            throw error
        case .hangs:
            try await Task.sleep(for: .seconds(60))
        }
    }

    func stop() {
        stopCount += 1
    }

    func disconnect() {
        disconnectCount += 1
        state = .idle
    }
}
