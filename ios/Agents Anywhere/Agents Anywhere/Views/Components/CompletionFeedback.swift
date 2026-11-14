import SwiftUI

extension View {
    /// Shared finish cue for a reply and the New Session welcome presentation.
    func completionFeedback<Value: Equatable>(trigger: Value,
        sessionID: String? = nil,
        diagnostic: @escaping () -> [String: String] = { [:] },
        condition: @escaping (Value, Value) -> Bool = { _, _ in true }) -> some View {
        modifier(CompletionFeedback(trigger: trigger, sessionID: sessionID,
                                    diagnostic: diagnostic, condition: condition))
    }
}

private struct CompletionFeedback<Value: Equatable>: ViewModifier {
    let trigger: Value
    let sessionID: String?
    let diagnostic: () -> [String: String]
    let condition: (Value, Value) -> Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.sidebarDrawerIsTransitioning) private var drawerTransitioning
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
                      HapticGate.statusAllowed(),
                      condition(previous, current) else { return }
                playback = Task { @MainActor in
                    note(1)
                    pulse += 1
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard !Task.isCancelled, scenePhase == .active,
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
