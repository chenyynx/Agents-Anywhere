import Observation
import SwiftUI

/// The Code page's return-to-bottom control, following the official
/// `ClaudeCoreUI.ScrollDownIndicator`:
///
/// - content circle `iconSize + 2 × 12` (16 pt base, `.footnote` scaling) =
///   40×40 pt at the default type size (`FUN_100c2e718` / `FUN_100c2ee0c`);
/// - icon `anthropicon.arrowDown`, `.large` (14×15 pt artwork; the static
///   Anthropicon at `FUN_100a2eab8`);
/// - iOS 26 glass circle (`Glass.regular.interactive().tint(nil)`), minimum
///   tap target 44 pt (`FUN_100c2e15c`);
/// - show/hide `easeInOut(0.2)`, skipped under Reduce Motion (part-u §5.1);
/// - accessibility label key `scroll_down` ("向下滚动", `FUN_100dc6d50`).
///
/// The host-side predicate lives in the controller (`canScrollDown`); the
/// component only consumes the boolean, exactly like the official `hidden`.
@MainActor
@Observable
final class CodeScrollDownIndicatorState {
    var isVisible: Bool

    init(isVisible: Bool = false) {
        self.isVisible = isVisible
    }
}

struct CodeScrollDownIndicator: View {
    let state: CodeScrollDownIndicatorState
    let onTap: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .footnote) private var iconSize: CGFloat = 16

    /// Official `ScrollDownIndicator` padding token
    /// (`DAT_1042cba20 = 12.0`, read by `FUN_100c2ee0c`).
    private let padding: CGFloat = 12

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if state.isVisible {
                button.transition(.opacity)
            }
        }
        // The official presence animation is `Animation.easeInOut(duration:
        // 0.2)`; Reduce Motion skips it (part-u §5.1).
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: state.isVisible)
    }

    private var button: some View {
        Button(action: onTap) {
            AnthropiconView(name: "anthropicon.arrowDown", size: .large)
                .foregroundStyle(.primary)
                .frame(width: iconSize + padding * 2, height: iconSize + padding * 2)
                .glassEffect(.regular.interactive(), in: Circle())
                // Official hit target is a separate 44 pt minimum; it must not
                // grow the visible 40 pt circle.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("向下滚动"))
        .accessibilityIdentifier("code.timeline.scrollDown")
    }
}
