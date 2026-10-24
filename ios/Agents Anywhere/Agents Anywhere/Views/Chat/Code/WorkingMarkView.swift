import SwiftUI
import UIKit

/// The Code page's running mark: the official three-dot flipbook, redrawn
/// with Core Graphics because the official sprite sheets cannot be
/// redistributed (`docs/perf-6b-c5-code-profile-task.md` §6).
///
/// The view owns no frame math; it only drives `WorkingMarkRenderer`:
///
/// - `isRunning` plays opening (16 frames, 0.53 s) then loops (110 frames,
///   3.67 s) at the official 30 fps.
/// - `reduceMotion` (or the accessibility Reduce Motion value) freezes on the
///   single rest frame, mirroring the official `isStill` path.
/// - Turning `isRunning` off plays the official 0.4 s exit group:
///   `transform.scale -> 0.01` with opacity -> 0
///   (`CANONICAL/20-working-mark.md:53`). [I] The exit animates the frame that
///   is on screen rather than a flipbook that keeps stepping; the parent must
///   keep the view mounted for those 0.4 s because a child cannot remove
///   itself.
/// - Under Reduce Motion the official still path plays one frame and builds
///   no runs (`CANONICAL/20-working-mark.md:24`); AA therefore removes the
///   mark at once instead of scaling/fading it ([I]: the exit group is not
///   part of the still path).
///
/// The official mark is a fixed 20 x 20 pt decorative element, so the view is
/// `accessibilityHidden(true)`.
struct WorkingMarkView: View {

    /// Only `.think` is drawn today; every other pose falls back to it.
    ///
    /// The label is `body:` to mirror the official type. The value is stored
    /// as `markBody` because `body` is already SwiftUI's view requirement.
    private let markBody: WorkingMarkBody

    /// While true the flipbook runs; false starts the 0.4 s exit.
    private let isRunning: Bool

    /// Forces the still frame in addition to the accessibility environment.
    private let reduceMotion: Bool

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    /// Anchors the flipbook so the first rendered frame is opening frame 0.
    /// Only a restart resets it: the exit must keep the same anchor, or the
    /// flipbook would jump back to its opening frame while the exit group
    /// plays.
    @State private var start = Date()

    /// The flipbook time captured when `isRunning` turned false. The official
    /// exit is one 0.4 s group on `transform.scale`/`opacity`
    /// (`CANONICAL/20-working-mark.md:53`); [I] it holds the frame that is on
    /// screen instead of stepping the flipbook on, so the mark keeps this
    /// frame for the whole exit. `nil` while running.
    @State private var frozenElapsed: TimeInterval?

    init(body: WorkingMarkBody = .think,
         isRunning: Bool = true,
         reduceMotion: Bool = false) {
        self.markBody = body
        self.isRunning = isRunning
        self.reduceMotion = reduceMotion
    }

    private var isStill: Bool {
        reduceMotion || accessibilityReduceMotion
    }

    var body: some View {
        markContent
            .frame(width: CodePageTheme.workingMarkSize,
                   height: CodePageTheme.workingMarkSize)
            .modifier(WorkingMarkExitModifier(progress: isRunning ? 0 : 1))
            .animation(exitAnimation, value: isRunning)
            .onAppear {
                start = Date()
                // A view mounted already stopped is invisible (progress 1);
                // the frame it holds does not matter, but keep the state
                // deterministic instead of reading the clock in `body`.
                frozenElapsed = isRunning ? nil : 0
            }
            .onChange(of: isRunning) { _, running in
                if running {
                    // Restart: a new opening must begin at frame 0. The exit
                    // animation is nil in this state, so progress snaps back.
                    start = Date()
                    frozenElapsed = nil
                } else {
                    // Freeze the flipbook where it stands before the exit
                    // group takes over.
                    frozenElapsed = max(0, Date().timeIntervalSince(start))
                }
            }
            .accessibilityHidden(true)
    }

    /// Reduce Motion draws the single rest frame directly instead of through
    /// the timeline: a periodic schedule can be a tick late, and the still
    /// pose must apply the moment the environment value changes.
    ///
    /// The running timeline is removed at `isRunning == false`, so the 30 fps
    /// flipbook cannot keep stepping behind the 0.4 s exit group; the exit
    /// draws the frame captured at the stop instead.
    @ViewBuilder
    private var markContent: some View {
        let tint = UIColor(CodePageTheme.workingMarkTint.resolved(for: scheme))
        if isStill {
            // Official `isStill` plays one sprite frame and builds no runs
            // (`CANONICAL/20-working-mark.md:24`); [I] the still path has no
            // exit group, so the mark is gone the moment the turn stops.
            if isRunning {
                Image(uiImage: WorkingMarkRenderer.image(
                    for: WorkingMarkRenderer.frame(body: markBody,
                                                   phase: .looping,
                                                   index: 0),
                    tint: tint,
                    scale: displayScale))
            }
        } else if isRunning {
            TimelineView(.periodic(from: start,
                                   by: 1.0 / CodePageTheme.workingMarkFrameRate)) { timeline in
                let elapsed = timeline.date.timeIntervalSince(start)
                let frame = WorkingMarkRenderer.frame(body: markBody,
                                                      elapsed: elapsed,
                                                      isStill: false)
                Image(uiImage: WorkingMarkRenderer.image(for: frame,
                                                          tint: tint,
                                                          scale: displayScale))
            }
        } else {
            Image(uiImage: WorkingMarkRenderer.image(
                body: markBody,
                elapsed: frozenElapsed ?? max(0, Date().timeIntervalSince(start)),
                isStill: false,
                tint: tint,
                scale: displayScale))
        }
    }

    /// Drives `WorkingMarkExitModifier.progress` linearly over the official
    /// 0.4 s; the modifier turns that one progress value into the official
    /// scale and opacity keyframes. Nil while running, so a restart snaps the
    /// mark back before the opening flipbook takes over. Nil under Reduce
    /// Motion too: the still path builds no runs
    /// (`CANONICAL/20-working-mark.md:24`), [I] no exit group.
    private var exitAnimation: Animation? {
        guard !isRunning, !isStill else { return nil }
        return .linear(duration: CodePageTheme.workingMarkExitDuration)
    }
}

/// The official exit group (`CANONICAL/20-working-mark.md` §6) expressed as
/// one animatable progress value.
///
/// The view drives `progress` from 0 to 1 with a linear 0.4 s animation; this
/// modifier maps a single progress to the two official sub-animations:
///
/// - `transform.scale`: captured value -> 0.01 across the whole 0.4 s.
/// - `opacity`: a `CAKeyframe` on keyTimes `[0, 0.6, 1]` — hold for the first
///   60 %, then fall to 0 over the last 40 %.
private struct WorkingMarkExitModifier: ViewModifier, Animatable {
    /// 0 = fully present, 1 = fully exited.
    var progress: Double

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let clamped = min(max(progress, 0), 1)
        // This view's captured scale is 1 (it carries no glide transform of
        // its own), so the official "from captured value" starts here.
        content
            .scaleEffect(1 + (CodePageTheme.workingMarkExitScale - 1) * CGFloat(clamped))
            .opacity(opacity(at: clamped))
    }

    /// [E]/[I] `CANONICAL/20-working-mark.md` §6 — keyTimes `[0, 0.6, 1]` are
    /// [E]; the decoded values `[s8, s8, 0]` are marked inference and read as
    /// "hold at the captured opacity, then fall to 0".
    private func opacity(at progress: Double) -> Double {
        guard progress > 0.6 else { return 1 }
        let fade = (progress - 0.6) / 0.4
        return 1 + (CodePageTheme.workingMarkExitOpacity - 1) * fade
    }
}

// MARK: - Previews

#Preview("Working mark — running") {
    WorkingMarkPreviewStage {
        WorkingMarkView(body: .think, isRunning: true)
    }
}

#Preview("Working mark — stop (0.4 s exit)") {
    WorkingMarkStopPreview()
}

#Preview("Working mark — Reduce Motion") {
    WorkingMarkPreviewStage {
        WorkingMarkView(body: .think, isRunning: true, reduceMotion: true)
    }
}

/// The mark beside the status text it belongs to (screenshot 2026-10-22).
private struct WorkingMarkPreviewStage<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            content
            Text("Computing...")
                .font(.system(size: CodePageTheme.runningStatusFontSize))
                .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: .light))
        }
        .padding(24)
        .background(Color(.systemBackground))
    }
}

/// Toggling the button exercises the real exit path; a static
/// `isRunning: false` preview would only show the invisible end state.
private struct WorkingMarkStopPreview: View {
    @State private var isRunning = true

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                WorkingMarkView(body: .think, isRunning: isRunning)
                Text(isRunning ? "Computing..." : "Stopped")
                    .font(.system(size: CodePageTheme.runningStatusFontSize))
                    .foregroundStyle(CodePageTheme.runningStatusColor.resolved(for: .light))
            }
            Button(isRunning ? "Stop" : "Run again") {
                isRunning.toggle()
            }
        }
        .padding(24)
        .background(Color(.systemBackground))
    }
}
