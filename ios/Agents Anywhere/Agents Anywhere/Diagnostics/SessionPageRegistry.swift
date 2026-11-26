import Foundation

/// Tracks which tab pages currently mount a session.
///
/// Two live pages for one session share its composer draft and timeline model;
/// they fight over first responder and neither can type (device report
/// 2026-11-26). The tab shell parks the hidden duplicate, and this registry
/// makes any regression visible in the diagnostics log instead of waiting for
/// a verbal report.
@MainActor
enum SessionPageRegistry {
    private static var live: [V2SessionID: Set<ChatPaneRole>] = [:]

    /// Records an appearing page and returns the other panes already live for
    /// the same session.
    static func entered(_ sessionID: V2SessionID, pane: ChatPaneRole) -> [ChatPaneRole] {
        var panes = live[sessionID] ?? []
        panes.insert(pane)
        live[sessionID] = panes
        return panes.subtracting(Set([pane])).sorted { $0.rawValue < $1.rawValue }
    }

    static func left(_ sessionID: V2SessionID, pane: ChatPaneRole) {
        guard var panes = live[sessionID] else { return }
        panes.remove(pane)
        if panes.isEmpty {
            live.removeValue(forKey: sessionID)
        } else {
            live[sessionID] = panes
        }
    }

    /// Test hook; the app never resets the registry.
    static func reset() {
        live.removeAll()
    }
}
