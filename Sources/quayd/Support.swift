import Foundation

/// Thread-safe one-way stop flag toggled by signal handlers.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// Keep dispatch signal sources alive for the lifetime of the process.
nonisolated(unsafe) var signalSources: [DispatchSourceSignal] = []
