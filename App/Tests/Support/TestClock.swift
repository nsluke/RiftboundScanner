import Foundation
import Synchronization

/// A clock tests move by hand. `now` starts at zero and only changes through
/// `advance(by:)`, which also wakes sleepers whose deadline has passed.
nonisolated final class TestClock: Clock, Sendable {
    typealias Duration = Swift.Duration

    nonisolated struct Instant: InstantProtocol, Sendable {
        typealias Duration = Swift.Duration

        var offset: Duration

        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [Sleeper] = []
    }

    private let state = Mutex<State>(State())

    init() {}

    var now: Instant { state.withLock { $0.now } }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let due = state.withLock { $0.now >= deadline }
        if due { return }
        try await withCheckedThrowingContinuation { continuation in
            state.withLock { $0.sleepers.append(Sleeper(deadline: deadline, continuation: continuation)) }
        }
    }

    func advance(by duration: Duration) {
        let woken: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let (due, waiting) = state.sleepers.reduce(into: ([Sleeper](), [Sleeper]())) { partial, sleeper in
                if sleeper.deadline <= state.now { partial.0.append(sleeper) } else { partial.1.append(sleeper) }
            }
            state.sleepers = waiting
            return due
        }
        for sleeper in woken {
            sleeper.continuation.resume()
        }
    }
}
