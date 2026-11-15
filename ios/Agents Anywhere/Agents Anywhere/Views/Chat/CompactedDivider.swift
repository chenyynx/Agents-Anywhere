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
/// squiggle takes the rest.
struct CompactedDivider: View {
    let title: String
    /// The compaction failed: the official failure message in `danger00`.
    var failed = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 16) {
            CompactionSquiggle()
                .stroke(ink,
                        style: StrokeStyle(lineWidth: 1, lineCap: .butt,
                                           lineJoin: .miter, miterLimit: 10))
                .frame(height: 4)
                .frame(maxWidth: .infinity)
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
        }
        .padding(.vertical, 16)
        .accessibilityElement(children: .combine)
    }

    /// The blockquote ink at 15 % (`round31` §3.3) — the same dynamic colour
    /// the rendered quotes use.
    private var ink: Color { Color(uiColor: CodePageTheme.quoteBarUIColor) }
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
