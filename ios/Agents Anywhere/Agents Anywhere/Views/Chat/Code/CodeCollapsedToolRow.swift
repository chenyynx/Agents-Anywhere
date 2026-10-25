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
    /// The label plan's localized text plus the failure counts. One value
    /// keeps the verb/target runs and the per-phrase summary in sync.
    let label: CodeToolRowLabel
    /// An official Anthropicon asset name for the leading icon (see
    /// `AnthropiconAssets`). Defaults to none because a completed row in the
    /// official screenshot has no leading glyph; the caller passes one for
    /// the states that show it (running / background task,
    /// `04-tool-calls.md` §7.3).
    let icon: String?
    let action: () -> Void

    /// Both glyphs are the official Anthropicon artwork now (shipped from the
    /// app bundle, see `AnthropiconAssets`): the tool icon at the `.large`
    /// preset and the caret at `.medium`. The device-measured caret
    /// (7.7×14.3 pt) matches the medium 8×15 artwork extent, not the large
    /// 10×18 one, which is why the caret uses the smaller preset.

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var lineHeight = CodePageTheme.toolRowLineHeight

    @Environment(\.colorScheme) private var colorScheme
    /// The official `failureInWords` is the accessibility "differentiate
    /// without colour" value (`0x102ab2fb4`): when set, failures are written
    /// out and the label keeps its normal ink.
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    init(label: CodeToolRowLabel,
         icon: String? = nil,
         action: @escaping () -> Void) {
        self.label = label
        self.icon = icon
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center) {
                if let icon {
                    AnthropiconView(name: icon, size: .large)
                        .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                            .resolved(for: colorScheme))
                }

                labelText
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    // The official running row sweeps a shimmer across the
                    // label (`ShimmerView`, §4.1). Reuse the app's shared
                    // opacity sweep; it already honours Reduce Motion.
                    .modifier(StatusShimmer(active: label.isRunning))

                if let diff = label.diff, diff.hasCounts {
                    CodeDiffIndicator(stat: diff)
                }

                // Official `caretRight`, secondary, at the medium artwork
                // extent (8×15 pt); the device screenshots measure 7.7×14.3.
                AnthropiconView(name: "anthropicon.caretRight", size: .medium)
                    .foregroundStyle(CodePageTheme.toolRowSecondaryColor
                        .resolved(for: colorScheme))
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

    /// The single-target shape: two runs sharing one line, the secondary
    /// proportional verb then the primary monospaced target. Failure follows
    /// the official switch (`0x10289036c`): red verb unless colour must not
    /// carry meaning alone (`differentiateWithoutColor`), in which case the
    /// written `(N failed)` suffix is appended.
    private var labelText: Text {
        if !label.phrases.isEmpty { return phrasesText }
        let secondary = CodePageTheme.toolRowSecondaryColor.resolved(for: colorScheme)
        let failedColorOnly = label.failed > 0 && !differentiateWithoutColor
        let verbColor = failedColorOnly
            ? CodePageTheme.toolRowFailureColor.resolved(for: colorScheme)
            : secondary
        let targetColor = Color(uiColor: CodePageTheme.markdownTextUIColor)
        let suffix = singleTargetSuffix
        let sans = Font.custom(CodePageTheme.sansFontName,
                               size: CodePageTheme.toolRowFontSize,
                               relativeTo: CodePageTheme.toolRowTextStyle)
        guard let target = label.target, !target.isEmpty else {
            return Text(label.verb).font(sans).foregroundStyle(verbColor) + suffix
        }
        return Text(label.verb + " ")
            .font(sans)
            .foregroundStyle(verbColor)
            + Text(target)
            .font(.custom(CodePageTheme.monoFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowTextStyle))
            .foregroundStyle(targetColor)
            + suffix
    }

    private var singleTargetSuffix: Text {
        guard label.failed > 0, differentiateWithoutColor else { return Text("") }
        return Text(CodeToolLabels.failedSuffix(label.failed))
            .font(.custom(CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize,
                          relativeTo: CodePageTheme.toolRowTextStyle))
            .foregroundStyle(CodePageTheme.toolRowSecondaryColor.resolved(for: colorScheme))
    }

    /// The multi-target summary. Official rules (`0x10288ea34`): a partially
    /// failed category carries the written suffix; a category whose entries
    /// all failed is painted red unless colour is not a differentiator, in
    /// which case it carries the suffix instead.
    private var phrasesText: Text {
        let secondary = CodePageTheme.toolRowSecondaryColor.resolved(for: colorScheme)
        let failure = CodePageTheme.toolRowFailureColor.resolved(for: colorScheme)
        let sans = Font.custom(CodePageTheme.sansFontName,
                               size: CodePageTheme.toolRowFontSize,
                               relativeTo: CodePageTheme.toolRowTextStyle)
        var result = Text("")
        for (index, phrase) in label.phrases.enumerated() {
            if index > 0 {
                result = result
                    + Text(CodeToolLabels.phraseSeparator).font(sans)
                    .foregroundStyle(secondary)
            }
            let allFailed = phrase.total > 0 && phrase.failed == phrase.total
            let color = allFailed && !differentiateWithoutColor ? failure : secondary
            var text = phrase.text
            if phrase.failed > 0, !allFailed || differentiateWithoutColor {
                text += CodeToolLabels.failedSuffix(phrase.failed)
            }
            result = result + Text(text).font(sans).foregroundStyle(color)
        }
        return result
    }

    private var accessibilityText: String {
        if !label.phrases.isEmpty {
            return label.phrases.map { phrase in
                var text = phrase.text
                let allFailed = phrase.total > 0 && phrase.failed == phrase.total
                if phrase.failed > 0, !allFailed || differentiateWithoutColor {
                    text += CodeToolLabels.failedSuffix(phrase.failed)
                }
                return text
            }.joined(separator: CodeToolLabels.phraseSeparator)
        }
        var text = label.verb
        if let target = label.target, !target.isEmpty { text += " " + target }
        if label.failed > 0, differentiateWithoutColor {
            text += CodeToolLabels.failedSuffix(label.failed)
        }
        return text
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
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Read",
                                                 target: "Package.swift",
                                                 isRunning: false)) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — running") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Ran",
                                                 target: "npm test",
                                                 isRunning: true),
                         icon: "terminal") {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}

#Preview("Collapsed tool row — diff") {
    CodeCollapsedToolRow(label: CodeToolRowLabel(verb: "Edited",
                                                 target: "validate-email.ts",
                                                 diff: CodeDiffStat(added: 1, removed: 1),
                                                 isRunning: false)) {}
        .padding(.horizontal, CodePageTheme.rowMarginLeading)
}
