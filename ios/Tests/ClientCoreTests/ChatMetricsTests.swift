import Foundation
import Testing
@testable import ClientCore

/// The ratio helpers exist so a design constant in points survives Textual's
/// font-relative spacing. A silent change to the reference size would rescale
/// every spacing value at once, so the ratios are pinned here.
@Suite("Chat visual metrics")
struct ChatMetricsTests {
    @Test("the reference body size matches the measured text")
    func referenceBodySizeMatchesMeasurement() {
        #expect(abs(ChatMetrics.referenceBodySize - 14) < 0.0001)
        #expect(abs(ChatMetrics.bodySize - 13) < 0.0001)
    }

    @Test("body line spacing is the line box minus the font size")
    func bodyLineSpacing() {
        #expect(abs(ChatMetrics.bodyLineSpacing - 8) < 0.0001)
        #expect(abs(ChatMetrics.bodyLineSpacingRatio - 8.0 / 14.0) < 0.0001)
    }

    @Test("a scaled constant resolves back to itself at the reference size")
    func scalingRoundTrip() {
        for points in [CGFloat(6), 15.5, 20, 24.4] {
            #expect(abs(ChatMetrics.scaled(points) * ChatMetrics.referenceBodySize - points) < 0.0001)
        }
    }

    @Test("code block leading stays positive")
    func codeBlockLeading() {
        // AA pins fenced code at its measured size, so the leading is the
        // measured pitch minus that size — not a value that moves with the
        // body size setting.
        #expect(abs(ChatMetrics.blockCodeSize - 12.3) < 0.0001)
        #expect(ChatMetrics.blockCodeLineHeight > ChatMetrics.blockCodeSize)
        #expect(abs(ChatMetrics.codeBlockLineSpacingRatio - (14.33 - 12.3) / 14) < 0.0001)
    }

    @Test("code block leading grows with a pinned code size")
    func codeBlockLeadingScales() {
        // 2pt of leading under 17pt glyphs would crowd the lines; the leading
        // is a share of the code size so the ratio is what stays fixed.
        #expect(abs(ChatMetrics.blockCodeLineSpacing / ChatMetrics.blockCodeSize - 2.03 / 12.3) < 0.0001)
    }
    @Test("list items sit wider than the lines inside them")
    func listItemSpacingExceedsLeading() {
        // A wrapped continuation line only reads as part of its own item while
        // the next item sits wider than the line's own leading. Left at
        // Textual's 0.25em default the items came out 2.3x tighter than the
        // leading, so a wrap looked like a new item.
        #expect(ChatMetrics.listItemSpacing > ChatMetrics.bodyLineSpacing)
        #expect(abs(ChatMetrics.listItemSpacing - ChatMetrics.bodyLineSpacing
                    - ChatMetrics.listItemExtraSpacing) < 0.0001)
        #expect(ChatMetrics.listItemSpacingRatio > ChatMetrics.bodyLineSpacingRatio)
    }

    @Test("the table cap leaves room for a padded cell")
    func tableCap() {
        #expect(ChatMetrics.tableContentWidthCap > ChatMetrics.tableCellPadHorizontal * 2)
    }
}
