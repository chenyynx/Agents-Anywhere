import Foundation
import os

/// Signposts for the session open / restore / merge / presentation hot paths.
///
/// Off unless `AA_PERF_SIGNPOST=1`, so a release build pays one boolean read
/// per call. Names are static strings so Instruments groups the intervals
/// without a runtime string table.
nonisolated enum PerfSignpost {
    static let enabled = ProcessInfo.processInfo.environment["AA_PERF_SIGNPOST"] == "1"

    private static let signposter = OSSignposter(
        subsystem: "com.agentsanywhere.perf",
        category: .pointsOfInterest
    )

    static func begin(_ name: StaticString) -> OSSignpostIntervalState? {
        guard enabled else { return nil }
        return signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(name, state)
    }

    static func event(_ name: StaticString) {
        guard enabled else { return }
        signposter.emitEvent(name)
    }
}
