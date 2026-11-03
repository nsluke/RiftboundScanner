/// A counting semaphore for async code: at most `limit` callers run `operation` at once.
///
/// Vision's text recogniser has crashed in this process (`EXC_BAD_ACCESS` inside
/// TextRecognition) when many `RecognizeTextRequest`s ran concurrently, so OCR is
/// funnelled through one of these. Waiters are resumed in arrival order.
public actor AsyncLimiter {
    private let limit: Int
    private var inUse = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    public func run<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async {
        if inUse < limit {
            inUse += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            inUse -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
