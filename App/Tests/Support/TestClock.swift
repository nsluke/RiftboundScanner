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
        let id: UUID
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
    /// How many sleeps are waiting for `advance(by:)`: lets a test wait until a
    /// task has reached its sleep before moving time, so the deadline it
    /// registers is the one the test expects.
    var sleeperCount: Int { state.withLock { $0.sleepers.count } }
    var minimumResolution: Duration { .zero }

    /// Cancelling the sleeping task removes its sleeper and throws
    /// `CancellationError`, as the system clocks do, so a cancelled flush
    /// never lingers in `sleeperCount`.
    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        try Task.checkCancellation()
        let due = state.withLock { $0.now >= deadline }
        if due { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let cancelled = state.withLock { state -> Bool in
                    guard !Task.isCancelled else { return true }
                    state.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper = state.withLock { state -> Sleeper? in
                guard let position = state.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return state.sleepers.remove(at: position)
            }
            sleeper?.continuation.resume(throwing: CancellationError())
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
