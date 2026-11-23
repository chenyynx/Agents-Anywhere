import Foundation
import Observation

/// The background keep-alive ladder (Poki's `BackgroundKeeper`, adapted).
///
/// iOS offers no single API that keeps an app running forever, so the ladder
/// degrades along the paths that do work:
///
///   1. `BGContinuedProcessingTask` (iOS 26): the system shows its own
///      progress UI, keeps the process alive, and may end it at any time.
///   2. Silent audio: no expiry, but another app's audio can interrupt it.
///   3. Coarse location: the last resort when audio cannot play; it never
///      reads or sends a coordinate, only holds the background execution.
///
/// The ladder is explicit state, not implicit retries: every level change is
/// written to the diagnostics log with its reason, and the Settings probe
/// shows the current level. The product starts it on every background entry
/// and stops it on foreground (P3 常驻); the probe can drive it separately.
@MainActor @Observable
final class KeepAliveCoordinator {
    enum Level: String {
        case off, continued, audio, location
    }

    static let shared = KeepAliveCoordinator()

    private(set) var level: Level = .off
    private(set) var detail = ""
    /// Mirrors `CoarseLocationKeeper.authorization` in observable storage so
    /// the Settings probe refreshes when the permission dialog returns.
    private(set) var locationAuthorization = "notDetermined"

    @ObservationIgnored private let audio = SilentAudioKeeper()
    @ObservationIgnored private let location = CoarseLocationKeeper()
    @ObservationIgnored private var audioLost = false

    var isOn: Bool { level != .off }
    var locationAuthorizationLabel: String { locationAuthorization }

    func start() {
        guard level == .off else { return }
        audioLost = false
        locationAuthorization = location.authorizationLabel
        setLevel(.off, reason: "starting")
        if startContinued() {
            setLevel(.continued, reason: "started")
            return
        }
        startAudioOrBelow(reason: "continued-refused")
    }

    func stop() {
        guard level != .off else { return }
        ContinuedRun.shared.onExpired = nil
        ContinuedRun.shared.end()
        audio.stop()
        location.stop()
        setLevel(.off, reason: "stopped")
    }

    // MARK: - Level 1: continued processing

    private func startContinued() -> Bool {
        let run = ContinuedRun.shared
        run.onExpired = { [weak self] in
            self?.continuedExpired()
        }
        return run.begin(subtitle: String(localized: "Keeping the connection alive"))
    }

    private func continuedExpired() {
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.level",
            detail: ["level": level.rawValue, "reason": "continued-expired"],
            dedupe: false)
        startAudioOrBelow(reason: "continued-expired")
    }

    // MARK: - Level 2: silent audio

    private func startAudioOrBelow(reason: String) {
        audio.onInterrupted = { [weak self] in
            guard let self else { return }
            self.audioLost = true
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.level",
                detail: ["level": self.level.rawValue, "reason": "audio-interrupted"],
                dedupe: false)
            self.startLocationIfPossible(reason: "audio-interrupted")
        }
        audio.onRestored = { [weak self] in
            guard let self else { return }
            self.audioLost = false
            self.location.stop()
            self.setLevel(.audio, reason: "audio-restored")
        }
        do {
            try audio.start()
            setLevel(.audio, reason: reason)
        } catch {
            ClientDiagnosticsLog.shared.record(
                kind: "keepalive.audio.start",
                detail: ["ok": "false", "error": error.localizedDescription],
                dedupe: false)
            startLocationIfPossible(reason: "audio-failed")
        }
    }

    // MARK: - Level 3: coarse location

    private func startLocationIfPossible(reason: String) {
        location.onChange = { [weak self] in
            guard let self else { return }
            self.locationAuthorizationChanged()
        }
        guard location.allowed else {
            // The user has not granted location; ask while the app is in
            // front. Nothing else can hold the process if audio is gone.
            location.requestPermission()
            setLevel(.audio, reason: "\(reason)-location-permission-needed")
            return
        }
        location.start()
        if location.isOn {
            setLevel(.location, reason: reason)
        } else {
            setLevel(.audio, reason: "\(reason)-location-start-failed")
        }
    }

    private func locationAuthorizationChanged() {
        locationAuthorization = location.authorizationLabel
        if location.allowed, level == .audio, audioLost || !audio.isOn {
            startLocationIfPossible(reason: "authorization-granted")
        } else if !location.allowed, level == .location {
            // Permission was revoked under a live fallback; the ladder has no
            // further level below location.
            location.stop()
            setLevel(.audio, reason: "location-not-authorized")
        }
    }

    // MARK: - State

    private func setLevel(_ next: Level, reason: String) {
        level = next
        detail = reason
        ClientDiagnosticsLog.shared.record(
            kind: "keepalive.level",
            detail: ["level": next.rawValue, "reason": reason],
            dedupe: false)
    }
}
