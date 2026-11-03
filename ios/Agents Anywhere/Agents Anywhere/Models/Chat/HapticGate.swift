import Foundation

/// Serializes haptics that would otherwise collide on the Taptic Engine.
///
/// iOS plays one feedback at a time; two `.sensoryFeedback` modifiers firing
/// in the same moment swallow one of them. Direct manipulation (the drawer's
/// open/close cue) is the user's own action and owns the engine for a short
/// window; passive status cues (a turn phase change, a turn completion) stay
/// silent during it instead of fighting for the slot.
@MainActor
enum HapticGate {
    /// How long a user-action haptic keeps passive cues out. iOS merges
    /// impacts fired within roughly 0.1 s; 0.15 s leaves the drawer's 0.2 s
    /// spring one clear slot.
    static let userActionWindow: TimeInterval = 0.15

    private static var lastUserActionAt: TimeInterval?

    /// Call when a haptic tied to the user's own gesture is about to play.
    static func noteUserAction(now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastUserActionAt = now
    }

    /// Whether a passive status cue may play now.
    static func statusAllowed(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard let lastUserActionAt else { return true }
        return now - lastUserActionAt >= userActionWindow
    }

    /// Test hook: clears the window so suites do not leak into each other.
    static func reset() {
        lastUserActionAt = nil
    }
}
