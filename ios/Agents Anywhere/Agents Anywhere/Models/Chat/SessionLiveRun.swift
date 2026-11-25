import Foundation

/// Owns the chat page's long-lived timeline observer.
///
/// The repository shares one socket across observers and closes it when the
/// last observer leaves (`V2SessionRepository.observe`). SwiftUI cancels the
/// view's `.task` whenever the tab is hidden, so the run must live with the
/// page model instead: switching tabs keeps the socket connected, and leaving
/// the chat (the model is released) cancels it.
final class SessionLiveRun: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return task != nil
    }

    func start(_ operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }
        task = Task { [weak self] in
            await operation()
            self?.finish()
        }
    }

    private func finish() {
        lock.lock()
        task = nil
        lock.unlock()
    }

    deinit {
        lock.lock()
        let task = task
        lock.unlock()
        task?.cancel()
    }
}
