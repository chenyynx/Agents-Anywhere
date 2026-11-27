import SwiftUI

extension View {
    /// Shared finish cue for a reply and the New Session welcome presentation.
    func completionFeedback<Value: Equatable>(trigger: Value,
        sessionID: String? = nil,
        revealPending: @escaping @MainActor () -> Bool = { false },
        diagnostic: @escaping () -> [String: String] = { [:] },
        condition: @escaping (Value, Value) -> Bool = { _, _ in true }) -> some View {
        modifier(CompletionFeedback(trigger: trigger, sessionID: sessionID,
                                    revealPending: revealPending,
                                    diagnostic: diagnostic, condition: condition))
    }
}

private struct CompletionFeedback<Value: Equatable>: ViewModifier {
    let trigger: Value
    let sessionID: String?
    /// True while the page is still replaying streamed text; the cue waits.
    let revealPending: @MainActor () -> Bool
    let diagnostic: () -> [String: String]
    let condition: (Value, Value) -> Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarDrawerIsTransitioning) private var drawerTransitioning
    /// A completion belongs to the page the reader is looking at. A hidden
    /// tab page keeps its view mounted and still sees the turn end; without
    /// this gate it would buzz from off screen (pp 2026-11-27).
    @Environment(\.shellTabVisible) private var shellTabVisible
    @Environment(\.shellTabTransitioning) private var shellTabTransitioning
    @State private var pulse = 0
    @State private var playback: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(.impact(flexibility: .rigid, intensity: 0.65), trigger: pulse)
            .onChange(of: trigger) { previous, current in
                playback?.cancel()
                // A completion is a passive status cue: when the user just
                // moved the drawer, its own haptic owns the engine and this
                // one stays silent instead of colliding with it.
                guard scenePhase == .active, !drawerTransitioning,
                      shellTabVisible, !shellTabTransitioning,
                      HapticGate.statusAllowed(),
                      condition(previous, current) else { return }
                playback = Task { @MainActor in
                    // A tab-return reveal still draining: let the text catch
                    // up before the cue (b1731: pump backlog 297, completion
                    // pulses 1.2 s later). A long replay is capped at 3 s so
                    // the cue is never lost entirely.
                    var waited = 0
                    while revealPending(), waited < 30 {
                        if Task.isCancelled { return }
                        try? await Task.sleep(for: .milliseconds(100))
                        guard !Task.isCancelled, scenePhase == .active,
                              shellTabVisible, !shellTabTransitioning,
                              HapticGate.statusAllowed() else { return }
                        waited += 1
                    }
                    note(1)
                    pulse += 1
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard !Task.isCancelled, scenePhase == .active,
                          shellTabVisible, !shellTabTransitioning,
                          HapticGate.statusAllowed() else { return }
                    note(2)
                    pulse += 1
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { playback?.cancel() }
            }
            .onDisappear { playback?.cancel() }
    }

    private func note(_ pulse: Int) {
        guard let sessionID else { return }
        var detail = diagnostic()
        detail["source"] = "completion"
        detail["pulse"] = String(pulse)
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.haptic", sessionID: sessionID, detail: detail, dedupe: false)
    }
}
