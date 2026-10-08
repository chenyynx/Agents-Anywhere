import Foundation

/// What one live frame means for the orb's receive pulse (§6.3).
struct OrbPulseDecision: Equatable {
    /// nil = this frame triggers nothing.
    let pulse: OrbPulse?
    /// The throttle anchor the caller writes back — unchanged unless a small
    /// stream pulse was actually emitted.
    let streamPulseAt: Date?
}

/// The receive pulse's pure decision: qualification, insert vs supersede
/// update, and the stream throttle (§6.3). It runs only on the live socket
/// path — replay, snapshot, paging and cache restores never reach it.
enum OrbPulsePolicy {
    /// At most one small stream pulse per this window.
    static let streamThrottle: TimeInterval = 0.25

    static func decide(item: V2TimelineItem, wasInserted: Bool,
                       now: Date, lastStreamPulseAt: Date?) -> OrbPulseDecision {
        // Only the assistant's own message rows qualify — a user echo, tool,
        // reasoning or system row must not ring the orb.
        guard item.type == .message, item.role == .assistant else {
            return OrbPulseDecision(pulse: nil, streamPulseAt: lastStreamPulseAt)
        }
        // A newly inserted row is a real arrival: a full pulse that does not
        // spend the stream throttle.
        if wasInserted {
            return OrbPulseDecision(pulse: OrbPulse(strength: 1.0), streamPulseAt: lastStreamPulseAt)
        }
        // A supersede update only pulses while the row is still streaming.
        guard item.status == .pending || item.status == .running else {
            return OrbPulseDecision(pulse: nil, streamPulseAt: lastStreamPulseAt)
        }
        if let last = lastStreamPulseAt, now.timeIntervalSince(last) < streamThrottle {
            return OrbPulseDecision(pulse: nil, streamPulseAt: lastStreamPulseAt)
        }
        return OrbPulseDecision(pulse: OrbPulse(strength: 0.3), streamPulseAt: now)
    }
}
