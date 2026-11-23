import BackgroundTasks
import Foundation

/// P0 probe for background keep-alive.
///
/// Registers an iOS 26 `BGContinuedProcessingTask` at launch and reports every
/// outcome to the diagnostics log (`keepalive.continued.*`): whether the
/// identifier from `BGTaskSchedulerPermittedIdentifiers` is present, whether
/// iOS accepts the registration, whether `submit` throws, and whether the
/// process keeps ticking while the app is behind. The product keep-alive
/// ladder (continued run → silent audio → coarse location) is built on this,
/// so the probe answers the only question code cannot: does iOS grant the task
/// to this signed build.
///
/// Diagnostics-only: nothing starts a task unless the Settings probe does. A
/// task that outlives the app is ended by iOS at process death; `end()` is the
/// explicit stop used by the probe row.
@MainActor
final class ContinuedRun {
    static let shared = ContinuedRun()

    /// The first permitted identifier ending in `.run.*`. The build expands
    /// `$(PRODUCT_BUNDLE_IDENTIFIER).run.*` to the signed bundle id, so this
    /// carries exactly what iOS compares against the running app.
    static var permittedIdentifier: String? {
        (Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String])?
            .first { $0.hasSuffix(".run.*") }
    }

    private var task: BGContinuedProcessingTask?
    private var identifier: String?
    private var ticker: Task<Void, Never>?
    private var registered = false
    private var attemptedRegistration = false
    private(set) var isRunning = false

    /// Called from `AgentsAnywhereApp.init`: BackgroundTasks takes a launch
    /// handler only before the app finishes launching.
    static func registerAtLaunch() {
        ClientDiagnosticsLog.shared.record(
            kind: "app.bundleId",
            detail: [
                "bundleId": Bundle.main.bundleIdentifier ?? "?",
                "permitted": permittedIdentifier ?? "none",
            ],
            dedupe: false)
        shared.register()
    }

    private func register() {
        guard !attemptedRegistration else { return }
        attemptedRegistration = true
        guard let wildcard = Self.permittedIdentifier else {
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.continued.register",
                detail: [
                    "ok": "false",
                    "reason": "no-permitted-identifier",
                    "bundleId": Bundle.main.bundleIdentifier ?? "?",
                ],
                dedupe: false)
            return
        }
        let ok = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: wildcard,
            using: .main
        ) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            MainActor.assumeIsolated { self?.started(continued) }
        }
        registered = ok
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.continued.register",
            detail: [
                "ok": ok ? "true" : "false",
                "identifier": wildcard,
                "bundleId": Bundle.main.bundleIdentifier ?? "?",
            ],
            dedupe: false)
    }

    /// Submits a continued-processing task. Must be called while the app is in
    /// front; the Settings probe calls it from the visible settings page.
    @discardableResult
    func begin(subtitle: String) -> Bool {
        guard !isRunning else { return true }
        register()
        guard registered, let wildcard = Self.permittedIdentifier else { return false }
        let id = String(wildcard.dropLast()) + UUID().uuidString.prefix(8).lowercased()
        let request = BGContinuedProcessingTaskRequest(
            identifier: id,
            title: "Agents Anywhere",
            subtitle: subtitle)
        request.strategy = .fail
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.continued.submit",
                detail: [
                    "ok": "false",
                    "identifier": id,
                    "error": error.localizedDescription,
                ],
                dedupe: false)
            return false
        }
        identifier = id
        isRunning = true
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.continued.submit",
            detail: ["ok": "true", "identifier": id],
            dedupe: false)
        return true
    }

    func end() {
        finish(success: true)
    }

    private func started(_ task: BGContinuedProcessingTask) {
        guard isRunning else {
            task.setTaskCompleted(success: true)
            return
        }
        self.task = task
        task.progress.totalUnitCount = 1_000
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.isRunning else { return }
                ClientDiagnosticsLog.shared.record(
                    kind: "keepalive.continued.expired",
                    detail: ["identifier": self.identifier ?? "?"],
                    dedupe: false)
                self.finish(success: false)
            }
        }
        let startedAt = Date()
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.continued.started",
            detail: [
                "identifier": identifier ?? "?",
                "bundleId": Bundle.main.bundleIdentifier ?? "?",
            ],
            dedupe: false)
        // iOS ends a task whose progress never moves. The tick doubles as the
        // probe's proof that the process kept running while backgrounded: a
        // `tick` line with a growing `elapsed` after the app went behind means
        // the task was actually granted.
        ticker = Task { @MainActor [weak self] in
            var tick = 0
            while !Task.isCancelled, let self, let task = self.task {
                tick += 1
                let progress = task.progress
                if progress.completedUnitCount < progress.totalUnitCount - 1 {
                    progress.completedUnitCount += 1
                }
                if tick % 6 == 0 {
                    ClientDiagnosticsLog.shared.record(
                        kind: "keepalive.continued.tick",
                        detail: [
                            "elapsed": String(Int(Date().timeIntervalSince(startedAt))),
                        ],
                        dedupe: false)
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func finish(success: Bool) {
        isRunning = false
        ticker?.cancel()
        ticker = nil
        if let task {
            task.progress.completedUnitCount = task.progress.totalUnitCount
            task.setTaskCompleted(success: success)
        }
        task = nil
        if let identifier {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
        identifier = nil
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.continued.end",
            detail: ["success": success ? "true" : "false"],
            dedupe: false)
    }
}
