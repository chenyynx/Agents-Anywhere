import SwiftUI

/// A line-diff summary for a collapsed tool row.
///
/// The Code model layer does not carry a diff stat yet (`CodeToolSegments.swift`
/// models calls and segments, not their line counts), so W3 defines the shape
/// it consumes here. Both counts are line counts: zero means "no lines", never
/// a negative value.
nonisolated struct CodeDiffStat: Hashable, Sendable {
    let added: Int
    let removed: Int

    /// A badge exists only when there is something to count; an all-zero stat
    /// would draw an empty pill.
    fileprivate var hasCounts: Bool { added > 0 || removed > 0 }
}

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

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var fontSize = CodePageTheme.toolRowFontSize

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var lineHeight = CodePageTheme.toolRowLineHeight

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
                        .font(.system(size: fontSize, weight: CodePageTheme.toolRowFontWeight))
                        .foregroundStyle(.secondary)
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

                Image(systemName: "chevron.right")
                    .font(.system(size: fontSize, weight: CodePageTheme.toolRowFontWeight))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            // The official line box is 24 pt even though the 15 pt text is
            // shorter; `lineHeight` is the theme's scaled copy of that value.
            .frame(minHeight: lineHeight, alignment: .leading)
            .padding(CodePageTheme.toolRowButtonPadding)
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
        guard let target, !target.isEmpty else {
            return Text(verb)
                .font(.system(size: fontSize, weight: CodePageTheme.toolRowFontWeight))
                .foregroundStyle(.secondary)
        }
        let verbRun = Text(verb + " ")
            .font(.system(size: fontSize, weight: CodePageTheme.toolRowFontWeight))
            .foregroundStyle(.secondary)
        let targetRun = Text(target)
            .font(.system(size: fontSize,
                          weight: CodePageTheme.toolRowFontWeight,
                          design: .monospaced))
            .foregroundStyle(.primary)
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
    private var fontSize = CodePageTheme.diffIndicatorFontSize

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var horizontalPadding = CodePageTheme.diffIndicatorHorizontalPadding

    @ScaledMetric(relativeTo: CodePageTheme.toolRowTextStyle)
    private var verticalPadding = CodePageTheme.diffIndicatorVerticalPadding

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
        .font(.system(size: fontSize, weight: .regular))
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
            .padding(.vertical, verticalPadding)
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
