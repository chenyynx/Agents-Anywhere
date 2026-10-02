import Foundation
import Network
import Observation

nonisolated struct V2NetworkStatus: Hashable, Sendable {
    enum Availability: Hashable, Sendable { case unknown, online, offline }
    var availability: Availability = .unknown
    var isExpensive = false
    var isConstrained = false
}

/// Path availability is a scheduling hint, not proof that this server is reachable.
@MainActor @Observable
final class V2ConnectivityMonitor {
    private(set) var status = V2NetworkStatus()
    @ObservationIgnored private var monitor: NWPathMonitor?
    @ObservationIgnored var onChange: ((V2NetworkStatus) -> Void)?

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        self.monitor = monitor
        monitor.pathUpdateHandler = { [weak self, weak monitor] path in
            let status = V2NetworkStatus(
                availability: path.status == .satisfied ? .online : .offline,
                isExpensive: path.isExpensive, isConstrained: path.isConstrained
            )
            Task { @MainActor [weak self, weak monitor] in
                guard let self, let monitor, self.monitor === monitor else { return }
                self.status = status
                self.onChange?(status)
            }
        }
        monitor.start(queue: DispatchQueue(label: "app.agentsanywhere.connectivity"))
    }

    func stop() { monitor?.cancel(); monitor = nil }

    /// Waits (bounded) for a usable path before a connection is opened.
    /// A path that is already reported offline returns false immediately.
    /// `.unknown` is only a missing hint, so when the window expires while the
    /// path still has not reported, the caller may try anyway: availability is
    /// a scheduling hint, never proof that the server is reachable.
    func waitUntilOnline(timeout: Duration = .seconds(2)) async -> Bool {
        if status.availability != .unknown { return status.availability == .online }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if Task.isCancelled { return false }
            do { try await Task.sleep(for: Self.readinessPollInterval) }
            catch { return false }
            switch status.availability {
            case .online: return true
            case .offline: return false
            case .unknown: continue
            }
        }
        return status.availability != .offline
    }

    private static let readinessPollInterval: Duration = .milliseconds(50)
}
