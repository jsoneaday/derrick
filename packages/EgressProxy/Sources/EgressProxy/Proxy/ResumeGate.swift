import Foundation
import Structure

/// Ensures a continuation is resumed at most once across concurrent NW callbacks.
final class ResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resumeOnce(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        body()
    }
}
