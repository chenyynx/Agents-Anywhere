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
/// pp 2026-11-24 replaced the in-house canvas mark with the official
/// ai-agents artwork pp sent (badge + two eyes + the second agent's arc on the
/// left). It ships as a template SVG asset, so the ink still follows
/// `text300` / failure red; the artwork is static and only the button's
/// entrance spring animates.
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

    /// The mark's badge keeps the 21.44 pt outer diameter the previous canvas
    /// mark used (the navigation ring beside it is 21.5 pt). The ai-agents
    /// artwork's viewBox is 14.3367 × 10.4267, so that height yields 29.5 pt
    /// of width for the second agent's arc on the left.
    private let markHeight: CGFloat = 21.44
    private var markWidth: CGFloat { markHeight * (14.3367 / 10.4267) }

    private var tint: Color {
        state.hasFailure
            ? CodePageTheme.failureGlyphFailedColor.resolved(for: colorScheme)
            : AppTheme.text300(colorScheme)
    }

    var body: some View {
        Button(action: onOpen) {
            Image("aa-SubAgentAgents")
                .resizable()
                .scaledToFit()
                .frame(width: markWidth, height: markHeight)
                .foregroundStyle(tint)
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

/// The running card's mark, read from the official running card's Lottie
/// (`grok-subagent-running.json`, 24-unit design space): an 18-unit badge ring
/// at 2 units stroke and two 2 × 5 eye bars, with both eyes driven by
/// `SubAgentMarkMotion` (saccade + blink). The toolbar entry no longer uses
/// this mark — it draws the ai-agents SVG asset above.
///
/// The outline never moves. Each eye glides with the saccade and closes
/// vertically around its own midpoint, so the blink collapses the bar toward a
/// short dash instead of shrinking it toward a corner.
struct SubAgentMark: View {
    /// The square the mark is drawn into, in points. 24 pt is the Lottie's own
    /// design space at 1:1, so the 18-unit ring plus its 2-unit stroke puts the
    /// badge's outer diameter at 20 pt.
    var size: CGFloat = 24
    /// The SVG's `currentColor`: one ink for the whole mark.
    var tint: Color = .primary

    /// The stroke in design units. The official running card's Lottie draws
    /// its badge ring at 2 units in this same 24-unit space, so the card mark
    /// matches that weight.
    private let strokeWidth: CGFloat = 2

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
                layer.fill(eye.path, with: .color(tint))
            }
        }
    }

    /// The badge ring: the Lottie's 18-unit ellipse (radius 9) around the
    /// 24-unit canvas centre.
    private static let outline: Path = {
        var p = Path()
        p.move(to: CGPoint(x: 12, y: 3))
        p.addCurve(to: CGPoint(x: 21, y: 12),
                   control1: CGPoint(x: 16.97056, y: 3),
                   control2: CGPoint(x: 21, y: 7.02944))
        p.addCurve(to: CGPoint(x: 12, y: 21),
                   control1: CGPoint(x: 21, y: 16.97056),
                   control2: CGPoint(x: 16.97056, y: 21))
        p.addCurve(to: CGPoint(x: 3, y: 12),
                   control1: CGPoint(x: 7.02944, y: 21),
                   control2: CGPoint(x: 3, y: 16.97056))
        p.addCurve(to: CGPoint(x: 12, y: 3),
                   control1: CGPoint(x: 3, y: 7.02944),
                   control2: CGPoint(x: 7.02944, y: 3))
        p.closeSubpath()
        return p
    }()

    /// The two eye bars from the Lottie's `Left Eye` / `Right Eye` layers: 2 × 5
    /// rects centred at (11, 10.5) and (16, 10.5), each with the midpoint the
    /// blink scales around.
    private static let eyes: [Eye] = {
        func bar(_ center: CGPoint) -> Eye {
            Eye(path: Path(CGRect(x: center.x - 1, y: center.y - 2.5,
                                  width: 2, height: 5)),
                center: center)
        }
        return [bar(CGPoint(x: 11, y: 10.5)), bar(CGPoint(x: 16, y: 10.5))]
    }()

    private struct Eye {
        var path: Path
        var center: CGPoint
    }
}
