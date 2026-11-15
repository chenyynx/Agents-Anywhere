import SwiftUI
import UIKit

/// The official compaction divider (`ClaudeCoreUI.SquiggleDivider`,
/// `EVIDENCE/round31-compaction-ui.md` §1–§3): a squiggly line and a
/// secondary label 16 pt apart, with 16 pt of vertical padding. It replaces
/// the straight hairline + caption row the timeline used to draw.
///
/// Every value below is decoded from the official binary: 1 pt stroke with
/// butt caps and mitre joins, a 4 pt line box, 8 pt segments on a 16 pt
/// period, 15 pt / 400 label in the `text400` secondary grey, and the
/// blockquote ink at 15 % for the line. The label is a single line
/// (`.fixedSize()` + `.layoutPriority(1)`), so it keeps its width and the
/// squiggles take the rest.
///
/// The official divider draws the line only on the leading side; pp
/// 2026-11-15 asked for a line on both sides (`〰️ 已压缩对话 〰️`), so the
/// text sits centred between two squiggles.
struct CompactedDivider: View {
    let title: String
    /// The compaction failed: the official failure message in `danger00`.
    var failed = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            squiggle
            Text(title)
                // [E] 15 / 400; the official Typography preset scales relative
                // to the surrounding text style (round31 §3.1).
                .font(.custom(CodePageTheme.sansFontName,
                              size: CodePageTheme.toolRowFontSize,
                              relativeTo: .footnote))
                .foregroundStyle(failed
                    ? CodePageTheme.danger00Color.resolved(for: colorScheme)
                    : CodePageTheme.text400Color.resolved(for: colorScheme))
                .multilineTextAlignment(.leading)
                .fixedSize()
                .layoutPriority(1)
            squiggle
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    private var squiggle: some View {
        CompactionSquiggle()
            .stroke(ink,
                    style: StrokeStyle(lineWidth: 1, lineCap: .butt,
                                       lineJoin: .miter, miterLimit: 10))
            .frame(height: 4)
            .frame(maxWidth: .infinity)
    }

    /// The blockquote ink at 15 % (`round31` §3.3) — the same dynamic colour
    /// the rendered quotes use.
    private var ink: Color { Color(uiColor: CodePageTheme.quoteBarUIColor) }

    /// The row's height before it is measured: the label's scaled line box
    /// plus the 16 pt padding on each side.
    ///
    /// The collection estimates a self-sizing row with a generic text floor
    /// (44 pt) and then corrects to the real height. The 10 pt correction
    /// moved the divider on every refresh while the anchor followed (pp
    /// 2026-11-15: 「压缩分割线会抖」— `timeline.mover start delta 10.0` on
    /// every open). Declaring the exact height removes the correction; the
    /// 0.5 pt tolerance in `applyPreferredHeight` absorbs any rounding left
    /// between SwiftUI's custom-font metrics and `UIFontMetrics`.
    static func estimatedHeight(traits: UITraitCollection?) -> CGFloat {
        let base = UIFont(name: CodePageTheme.sansFontName,
                          size: CodePageTheme.toolRowFontSize)
            ?? UIFont.systemFont(ofSize: CodePageTheme.toolRowFontSize)
        let font = UIFontMetrics(forTextStyle: .footnote)
            .scaledFont(for: base, compatibleWith: traits)
        return ceil(font.lineHeight) + 32
    }
}

/// The official `Squiggle` shape (`round31` §2.2): 8 pt segments on a 16 pt
/// period, each a quadratic curve whose control point sits
/// `±height × 0.5 × seg × 0.125` off the midline — at the 4 pt line box that
/// is ±2 pt of control and ±1 pt of peak.
private struct CompactionSquiggle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        var x = rect.minX
        while x < rect.maxX {
            let nextX = min(x + 8, rect.maxX)
            let segment = nextX - x
            let phase = x - (x / 16).rounded(.towardZero) * 16
            let sign: CGFloat = phase < 8 ? 1 : -1
            let control = CGPoint(
                x: x + segment * 0.5,
                y: rect.midY + sign * (rect.height * 0.5) * (segment * 0.125))
            path.addQuadCurve(to: CGPoint(x: nextX, y: rect.midY), control: control)
            x = nextX
        }
        return path
    }
}
