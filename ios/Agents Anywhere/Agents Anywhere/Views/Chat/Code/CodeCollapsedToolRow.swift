import SwiftUI
import UIKit

/// The Code page's collapsed tool row: one line, never an in-place expansion.
///
/// Official structure (`CANONICAL/04-tool-calls.md` §4.1, §6.2): the
/// `CollapsedRowButton` is an optional leading icon, a label, an optional
/// `DiffIndicator` (+N / −N, corner radius 4.5), a running shimmer and a
/// trailing caret, all inside 6 pt padding. The official label mixes two runs:
/// the verb ("Edited") is proportional and secondary, its target
/// ("validate-email.ts") is monospaced and primary — the 2026-10-22 screenshot
/// shows both at the same 15 pt size. A tap routes to the full-screen detail
/// and never expands the row (§4.2), so this view only calls `action`;
/// navigation belongs to the caller.
///
/// Every visual constant comes from `CodePageTheme`; this file adds none.
struct CodeCollapsedToolRow: View {
    let verb: String
    let target: String?
    /// An SF Symbol name for the leading icon. Defaults to none because a
    /// completed row in the official screenshot has no leading glyph; the
    /// caller passes one for the states that show it (running / background
    /// task, `04-tool-calls.md` §7.3).
    let icon: String?
    let diff: CodeDiffStat?
    let isRunning: Bool
    let action: () -> Void

    /// [E] R19 `tool-row-status.md:79-80` — the collapsed row's icon is an
    /// Anthropicon at `.large`: a 24 pt slot whose glyph does not scale with
    /// Dynamic Type.
    ///
    /// The artwork inside that slot is smaller than the slot. At `.large`,
    /// `DATA/anthropicon-map.tsv` records the drawn extents per icon (prompt
    /// 20×15, eye 20×15, search 20×20, file 15×20 …), i.e. at most 20 pt.
    /// SF Symbols fill their layout box: the `terminal` stand-in at the slot's
    /// 24 pt draws 27.6×21.8 pt (measured on the device screenshot), so 17 pt
    /// puts it at 19.6×15.4 - the official prompt mark. The label's line box
    /// still provides the official 24 pt row height.
    private let glyphSize: CGFloat = 17

    /// [E] The caret is `caretRight` at `.large` as well; its artwork is
    /// 10×18 pt (`DATA/anthropicon-map.tsv`, the largest rendition). An SF
    /// chevron at the 24 pt slot draws 11.3×20.3 pt (measured on the device
    /// screenshot), i.e. ~13% over the official mark, so the stand-in is drawn
    /// at 21 pt (~9.9×17.8 pt).
    private let caretSize: CGFloat = 21

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var lineHeight = CodePageTheme.toolRowLineHeight

    @Environment(\.colorScheme) private var colorScheme

    init(verb: String,
         target: String? = nil,
         icon: String? = nil,
         diff: CodeDiffStat? = nil,
         isRunning: Bool,
         action: @escaping () -> Void) {
        self.verb = verb
        self.target = target
        self.icon = icon
        self.diff = diff
        self.isRunning = isRunning
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: glyphSize, weight: CodePageTheme.toolRowFontWeight))
                        .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                            .resolved(for: colorScheme))
                        .accessibilityHidden(true)
                }

                labelText
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    // The official running row sweeps a shimmer across the
                    // label (`ShimmerView`, §4.1). Reuse the app's shared
                    // opacity sweep; it already honours Reduce Motion.
                    .modifier(StatusShimmer(active: isRunning))

                if let diff, diff.hasCounts {
                    CodeDiffIndicator(stat: diff)
                }

                // [E] The official caret is the `caretRight` Anthropicon at
                // `.large` = 24 pt, secondary. The Anthropicon assets are not
                // extracted yet (06-visuals-assets §4: pixel export blocked),
                // so the SF chevron is a placeholder with the same 24 pt box.
                Image(systemName: "chevron.right")
                    .font(.system(size: caretSize, weight: CodePageTheme.toolRowFontWeight))
                    .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                        .resolved(for: colorScheme))
                    .accessibilityHidden(true)
            }
            // The official line box is 24 pt even though the 15 pt text is
            // shorter; `lineHeight` is the theme's scaled copy of that value.
            // [E] `CollapsedRowButton`: `minHeight: 24`, `.padding(.vertical, 6)`,
            // no horizontal padding (R19 tool-row-status.md).
            .frame(minHeight: lineHeight, alignment: .leading)
            .padding(.vertical, CodePageTheme.toolRowButtonPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(diffAccessibilityValue)
    }

    /// Two runs sharing one line: the secondary proportional verb, then the
    /// primary monospaced target. Concatenating `Text` keeps truncation and
    /// line-limit behaviour on the whole label.
    private var labelText: Text {
        let verbColor = CodePageTheme.toolRowSecondaryColor.resolved(for: colorScheme)
        let targetColor = Color(uiColor: CodePageTheme.markdownTextUIColor)
        guard let target, !target.isEmpty else {
            return Text(verb)
                .font(.custom(CodePageTheme.sansFontName,
                              size: CodePageTheme.toolRowFontSize,
                              relativeTo: CodePageTheme.toolRowTextStyle))
                .foregroundStyle(verbColor)
        }
        let verbRun = Text(verb + " ")
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowTextStyle))
            .foregroundStyle(verbColor)
        let targetRun = Text(target)
            .font(.custom(CodePageTheme.monoFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowTextStyle))
            .foregroundStyle(targetColor)
        return verbRun + targetRun
    }

    private var accessibilityText: String {
        guard let target, !target.isEmpty else { return verb }
        return verb + " " + target
    }

    /// "+1 −1" in symbols rather than words, so it needs no localisation.
    private var diffAccessibilityValue: String {
        guard let diff else { return "" }
        var parts: [String] = []
        if diff.added > 0 { parts.append("+\(diff.added)") }
        if diff.removed > 0 { parts.append("−\(diff.removed)") }
        return parts.joined(separator: " ")
    }
}

/// The official `DiffIndicator`: `+N` and `−N` share one 4.5 pt rounded pill,
/// each half carrying its own fill and ink (`04-tool-calls.md` §4.1/§6.2).
private struct CodeDiffIndicator: View {
    let stat: CodeDiffStat

    @Environment(\.colorScheme) private var colorScheme

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var horizontalPadding = CodePageTheme.diffIndicatorHorizontalPadding

    /// [E] Each half is 18 pt tall and the glyph is 11 pt / 550 / 16
    /// (R19 tool-row-status.md).
    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var halfHeight = CodePageTheme.diffIndicatorHeight

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var fontSize = CodePageTheme.diffIndicatorFontSize

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var cornerRadius = CodePageTheme.diffIndicatorCornerRadius

    var body: some View {
        HStack(spacing: 0) {
            if stat.added > 0 {
                half(text: "+\(stat.added)",
                     fill: CodePageTheme.diffIndicatorAddFill,
                     ink: CodePageTheme.diffIndicatorAddText)
            }
            if stat.removed > 0 {
                half(text: "−\(stat.removed)",
                     fill: CodePageTheme.diffIndicatorRemoveFill,
                     ink: CodePageTheme.diffIndicatorRemoveText)
            }
        }
        // [E] 11 pt / weight 550. The variable face needs a CT variation
        // weight, so the font is built once from the scaled size.
        .font(Font(MarkdownFontFactory.font(
            name: CodePageTheme.monoFontName,
            size: fontSize,
            weight: CodePageTheme.diffIndicatorFontWeight)))
        .lineLimit(1)
        .fixedSize()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }

    private func half(text: String,
                      fill: CodePageTheme.SchemeColor,
                      ink: CodePageTheme.SchemeColor) -> some View {
        Text(text)
            .monospacedDigit()
            .foregroundStyle(ink.resolved(for: colorScheme))
            .padding(.horizontal, horizontalPadding)
            .frame(height: halfHeight)
            .background(fill.resolved(for: colorScheme))
    }
}

#Preview("Collapsed tool row — settled") {
    CodeCollapsedToolRow(verb: "Read",
                         target: "Package.swift",
                         isRunning: false) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — running") {
    CodeCollapsedToolRow(verb: "Ran",
                         target: "npm test",
                         icon: "terminal",
                         isRunning: true) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — diff") {
    CodeCollapsedToolRow(verb: "Edited",
                         target: "validate-email.ts",
                         diff: CodeDiffStat(added: 1, removed: 1),
                         isRunning: false) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}
