import SwiftUI

/// The SubAgent entry, docked in the session page's navigation bar as its own
/// circular toolbar item (pp 2026-11-18, from the official app's top-bar
/// reference). iOS 26 gives every trailing item one shared glass background,
/// so the host hides that background for this item
/// (`.sharedBackgroundVisibility(.hidden)`) and the button draws its own
/// system-glass circle — the same material the sidebar button gets on the
/// leading side, at the bar's own 44 pt content height. The old composer-dock
/// capsule (`SubAgentCapsule`, removed the same day) carried a label; a
/// circle carries only the mark, so the count and phase stay in the
/// accessibility value instead of the visible chrome.
///
/// The ink is the navigation bar's own `text300`, the same ink as the sidebar
/// mark beside it (pp 2026-11-18: 子代理图标颜色也换成这颜色), and turns the
/// tool-row failure red (`CodePageTheme.failureGlyphFailedColor`, pp's
/// explicit choice) while the newest batch carries a failure, exactly like the
/// capsule's repaint rule.
struct SubAgentToolbarButton: View {
    let state: SubAgentCapsuleState
    let onOpen: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The whole circle — glass included, since this button owns it — springs
    /// in on the item's first appearance. The item's removal is the bar's,
    /// so the exit still follows the system.
    @State private var hasEntered = false

    /// The bar's standard content height; the leading button's own glass
    /// circle is the same size.
    private let diameter: CGFloat = 44

    private var tint: Color {
        state.hasFailure
            ? CodePageTheme.failureGlyphFailedColor.resolved(for: colorScheme)
            : AppTheme.text300(colorScheme)
    }

    var body: some View {
        Button(action: onOpen) {
            SubAgentMark(size: 24, tint: tint)
                .frame(width: diameter, height: diameter)
                .glassEffect(.regular.interactive(), in: Circle())
                .opacity(hasEntered ? 1 : 0)
                .scaleEffect(hasEntered ? 1 : 0.72)
        }
        .buttonStyle(.plain)
        .onAppear {
            guard !hasEntered else { return }
            guard !reduceMotion else { hasEntered = true; return }
            withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
                hasEntered = true
            }
        }
        .accessibilityIdentifier("chat.subagent.toolbar")
        .accessibilityLabel(String(localized: "子代理运行中"))
        .accessibilityValue(state.accessibilityText)
        .accessibilityHint(String(localized: "查看详情"))
    }
}

/// The toolbar's own leaf: only this view reads the presented rows, so a
/// streamed token re-evaluates one bar button instead of the page (the same
/// reason the old dock capsule was a leaf). The toolbar item itself is gated
/// on the projection's active-card sidecar, which changes only when a card is
/// dispatched or settles; the full state here still needs the window, because
/// a failed card leaves the sidecar as soon as it reaches a terminal phase.
struct SubAgentToolbarSlot: View {
    let model: SessionChatModel
    let onOpen: (String) -> Void

    var body: some View {
        let state = SubAgentProgress.capsuleState(inWindow: model.timeline.rows.map(\.value),
                                                  activeCards: model.session.activeAgentCards)
        if state.isVisible {
            SubAgentToolbarButton(state: state) {
                if let id = state.latestRunningID { onOpen(id) }
            }
        }
    }
}

/// The mark: the badge circle and two eye strokes, traced 1:1 from the SVG pp
/// sent (24-unit design space, round caps/joins), with the eyes driven by
/// `SubAgentMarkMotion`.
///
/// The outline never moves. Each eye glides with the saccade and closes
/// vertically around its own midpoint (the same centre-scaling blobatar's
/// idle used), so the blink collapses the stroke toward a short dash instead
/// of shrinking it toward a corner.
struct SubAgentMark: View {
    /// The square the mark is drawn into, in points. 24 pt is the SVG's own
    /// design space at 1:1, which puts the badge's outer diameter at 21.44 pt
    /// — the context ring's own 21.5 pt (pp 2026-11-18: 子代理图标大小跟圆环
    /// 保持一致).
    var size: CGFloat = 24
    /// The SVG's `currentColor`: one ink for the whole mark.
    var tint: Color = .primary

    /// The stroke in design units. The source SVG draws at 2, but the toolbar
    /// renders at the weight of the official navigation mark beside it (pp
    /// 2026-11-18: 比这图标粗): `anthropicon.menu`'s bars are 0.9 units on an
    /// 18×15 artwork → 1.44 pt. Shape stays the SVG's.
    private let strokeWidth: CGFloat = 1.44

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let motion = SubAgentMarkMotion()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: reduceMotion)) { timeline in
            Canvas { context, canvasSize in
                draw(context: &context,
                     size: canvasSize,
                     time: reduceMotion ? nil : timeline.date.timeIntervalSinceReferenceDate * 1_000)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func draw(context: inout GraphicsContext, size: CGSize, time: Double?) {
        let scale = min(size.width, size.height) / 24
        context.scaleBy(x: scale, y: scale)
        let style = StrokeStyle(lineWidth: strokeWidth, lineCap: .round, lineJoin: .round)
        context.stroke(Self.outline, with: .color(tint), style: style)

        let frame = time.map { motion.frame(at: $0) } ?? .still
        for eye in Self.eyes {
            context.drawLayer { layer in
                layer.translateBy(x: frame.eyeOffset.x, y: frame.eyeOffset.y)
                layer.translateBy(x: eye.center.x, y: eye.center.y)
                layer.scaleBy(x: 1, y: frame.blink)
                layer.translateBy(x: -eye.center.x, y: -eye.center.y)
                layer.stroke(eye.path, with: .color(tint), style: style)
            }
        }
    }

    /// The badge outline, transcribed verbatim from the SVG's `M`/`C`
    /// commands so the silhouette stays identical to the design source.
    private static let outline: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 2))
        p.addCurve(to: CGPoint(x: 22, y: 12),
                   control1: CGPoint(x: 17.5228, y: 2),
                   control2: CGPoint(x: 22, y: 6.47715))
        p.addCurve(to: CGPoint(x: 12, y: 22),
                   control1: CGPoint(x: 22, y: 17.5228),
                   control2: CGPoint(x: 17.5228, y: 22))
        p.addCurve(to: CGPoint(x: 2, y: 12),
                   control1: CGPoint(x: 6.47715, y: 22),
                   control2: CGPoint(x: 2, y: 17.5228))
        p.addCurve(to: CGPoint(x: 12, y: 2),
                   control1: CGPoint(x: 2, y: 6.47715),
                   control2: CGPoint(x: 6.47715, y: 2))
        p.closeSubpath()
        return p
    }()

    /// The two eye strokes, transcribed verbatim from the SVG's second path
    /// (split at its `M`), each with the midpoint the blink scales around.
    private static let eyes: [Eye] = {
        func eye(_ start: CGPoint, _ end: CGPoint) -> Eye {
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            return Eye(path: path,
                       center: CGPoint(x: (start.x + end.x) / 2,
                                       y: (start.y + end.y) / 2))
        }
        return [eye(CGPoint(x: 12, y: 7.60279), CGPoint(x: 12.4521, y: 10.5685)),
                eye(CGPoint(x: 15.9543, y: 7), CGPoint(x: 16.4064, y: 9.96574))]
    }()

    private struct Eye {
        var path: Path
        var center: CGPoint
    }
}
