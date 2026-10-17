import Foundation
import Testing
@testable import ClientCore

/// The ratio helpers exist so a design constant in points survives Textual's
/// font-relative spacing. A silent change to the reference size would rescale
/// every spacing value at once, so the ratios are pinned here.
@Suite("Chat visual metrics")
struct ChatMetricsTests {
    @Test("the reference body size matches the measured text")
    func referenceBodySize() {
        #expect(ChatMetrics.referenceBodySize == 14)
        #expect(ChatMetrics.bodySize == 14)
    }

    @Test("body line spacing is the line box minus the font size")
    func bodyLineSpacing() {
        #expect(ChatMetrics.bodyLineSpacing == 22 - 14)
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
        #expect(ChatMetrics.blockCodeLineHeight > ChatMetrics.blockCodeSize)
        #expect(abs(ChatMetrics.blockCodeLineSpacingRatio - (14.33 - 12.3) / 14) < 0.0001)
    }

    @Test("the table cap leaves room for a padded cell")
    func tableCap() {
        #expect(ChatMetrics.tableContentWidthCap > ChatMetrics.tableCellPadHorizontal * 2)
    }
}
