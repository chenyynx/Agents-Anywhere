import Foundation

/// The collection engine's shared scroll vocabulary: the phase the native
/// scroll callbacks report (`TimelinePhaseMapping`) and the mode the follow
/// gates judge.
///
/// The state machine that used to live here — and the `TimelineTailVisibility`
/// probes it owned — was retired on 2026-11-16. The SwiftUI container it
/// served had already been deleted, and nothing in the app constructed it any
/// more; only the two enums below stayed in use.
nonisolated enum TimelineScrollState {
    enum Phase { case idle, tracking, interacting, decelerating, animating }
    enum Mode { case reading, following, returning }
}
