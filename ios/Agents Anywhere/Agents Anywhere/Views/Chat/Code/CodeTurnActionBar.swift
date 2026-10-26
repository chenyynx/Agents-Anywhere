import SwiftUI
import UIKit

/// The Code page's turn action bar: the official `SessionMessageActionBar`
/// row that follows a finished turn.
///
/// Official structure (`EVIDENCE/round18/user-row-and-action-bar.md` §3):
/// `IconButtonRow` with a 20 pt glyph slot, a 32 pt minimum tap width and
/// 12 pt spacing, no background/padding, one `session-message-action-bar`
/// accessibility element labelled “Message actions”. Only Copy carries the
/// `.selection` feedback.
///
/// The static Anthropicon declarations say `.large`, but the body overrides
/// every icon to **medium** at render time: five `movz w0,#1` +
/// `bl 0x100a29e2c` pairs inside `0x102b49dac` (copy/speak/thumbs/SendTo).
/// The same static-vs-runtime pattern appears on the code-card and thinking
/// row icons, so the artwork is 16×16 (copy) inside the 20 pt slot.
///
/// Scope for this batch (pp 2026-10-26): Copy is wired; the share button
/// (`SendToButton` in the official bar) is a **visual placeholder only**.
struct CodeTurnActionBar: View {
    let copyText: String

    /// The row's laid-out height: the 20 pt glyph slot. The tap targets are
    /// 32 pt wide (official `minimumTapWidth`) and do not add vertical space.
    static let rowHeight = CodeRowHeightPlan.actionBarHeight

    @State private var copied = false
    @State private var copyFeedback = 0
    @Environment(\.colorScheme) private var colorScheme

    private static let spacing: CGFloat = 12
    private static let glyphSlot: CGFloat = 20
    private static let minimumTapWidth: CGFloat = 32

    var body: some View {
        HStack(spacing: Self.spacing) {
            glyphButton(asset: copied ? "anthropicon.check" : "anthropicon.copy",
                        label: String(localized: "复制")) {
                UIPasteboard.general.string = copyText
                copied = true
                copyFeedback += 1
            }
            // Placeholder: the official bar's optional SendToButton is drawn,
            // but no transport exists in AA yet (pp 2026-10-26).
            glyphButton(asset: "anthropicon.share",
                        label: String(localized: "发送到")) {}
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("消息操作"))
        .accessibilityIdentifier("session-message-action-bar")
        .accessibilityAction(named: Text("复制")) {
            UIPasteboard.general.string = copyText
            copied = true
            copyFeedback += 1
        }
        .accessibilityAction(named: Text("发送到")) {}
        .sensoryFeedback(.selection, trigger: copyFeedback)
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            copied = false
        }
    }

    private func glyphButton(asset: String,
                             label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            AnthropiconView(name: asset, size: .medium)
                .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                    .resolved(for: colorScheme))
                .frame(width: Self.glyphSlot, height: Self.glyphSlot)
                .frame(width: Self.minimumTapWidth, height: Self.glyphSlot)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview("Turn action bar") {
    CodeTurnActionBar(copyText: "A finished reply.")
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}
