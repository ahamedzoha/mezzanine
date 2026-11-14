import Foundation

/// Limits concurrent image downloads, serving the *newest* waiter first.
///
/// While the user scrolls, the newest requests are the cards on screen; the
/// older ones belong to cards already scrolled past (and usually cancelled).
/// A cancelled waiter leaves the queue at once instead of holding a place.
public actor PriorityGate {
    private let limit: Int
    private var running = 0
    private var nextID: UInt64 = 0
    private var waiting: [(id: UInt64, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) {
        self.limit = max(1, limit)
    }

    /// Waits for a slot. Throws `CancellationError` if the task is cancelled
    /// while waiting; the caller then must not call `release()`.
    public func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = nextID
        nextID += 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Runs on the actor before the first suspension, so the
                // waiter is queued before any cancellation hop can look for it.
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    public func release() {
        if let next = waiting.popLast() {
            next.continuation.resume()   // the slot passes straight on
        } else {
            running = max(0, running - 1)
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        // Not found means it was already granted a slot; the caller releases it.
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// For tests.
    public var snapshot: (running: Int, waiting: Int) { (running, waiting.count) }
}
