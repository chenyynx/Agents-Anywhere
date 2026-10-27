import Foundation
import Testing
@testable import ClientCore

// The Code row's vertical arithmetic. Device probe 2026-10-23 measured a
// tool-only row at 52 pt while the old estimate reserved 54: the estimate used
// the unscaled 24 pt line box while `@ScaledMetric(relativeTo: .footnote)`
// scaled it to 22 pt at the device's text size. Every such row then shrank by
// 2 pt on first display, shifting everything below it while the reader
// scrolled. These tests pin the plan to the row view's real structure:
//
//   no block padding, block spacing 8, row spacing 10, margins 10,
//   collapsed tool row = line box + 2 x 6 pt button padding.
//
// The turn's working status is no longer part of a message row: it is its own
// transcript row (`CodeWorkingStatusRow`), so this plan has no status branch.

@Suite struct CodeRowHeightPlanTests {
    private let metrics = CodeRowHeightPlan.Metrics(
        blockSpacing: 8,
        rowSpacing: 10,
        toolLineHeight: 24,
        toolButtonPadding: 6,
        otherLineHeight: 24,
        rowMargins: 10)

    @Test func singleToolRowMatchesTheRenderedHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        // (24 + 12) button row + 10 margins; no block padding.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == 46)
    }

    @Test func scaledLineBoxIsTheOnlyDeviceDifference() {
        var scaled = metrics
        scaled.toolLineHeight = 22 // @ScaledMetric at the probe's text size
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: scaled) == 44)
    }

    @Test func parallelToolCallsPayOneButtonRowEach() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 3)])
        // One line box per segment, no per-block padding.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == CGFloat(3 * 36 + 10))
    }

    @Test func textBlocksMeasureTheirOwnHeight() {
        let row = CodeRowHeightPlan.Row(blocks: [
            .text(height: 100),
            .tools(segments: 1),
        ])
        // 100, 8 between blocks, 36, 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == 154)
    }

    @Test func multipleRenderedRowsAddRowSpacing() {
        let first = CodeRowHeightPlan.Row(blocks: [.text(height: 50)])
        let second = CodeRowHeightPlan.Row(blocks: [.text(height: 70)])
        // 50 + 10 + 70 + 10.
        #expect(CodeRowHeightPlan.height(rows: [first, second], metrics: metrics) == 140)
    }

    @Test func emptyRowsContributeNothing() {
        let empty = CodeRowHeightPlan.Row(blocks: [])
        #expect(CodeRowHeightPlan.height(rows: [empty], metrics: metrics) == 10)
    }

    @Test func actionBarAddsARowSpacingAndItsGlyphLine() {
        let row = CodeRowHeightPlan.Row(blocks: [.tools(segments: 1)])
        // 46 row + 10 row spacing + 20 glyph line.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics,
                                         hasActionBar: true) == 76)
    }

    @Test func actionBarRendersEvenWhenTheLastMessageHasNoBlocks() {
        let empty = CodeRowHeightPlan.Row(blocks: [])
        // No row spacing (nothing above), 20 glyph line + 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [empty], metrics: metrics,
                                         hasActionBar: true) == 30)
    }

    @Test func genericRowUsesTheUnscaledLineBox() {
        let row = CodeRowHeightPlan.Row(blocks: [.other])
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == CGFloat(24 + 10))
    }

    // MARK: - User attachments

    @Test func attachmentBlocksPayTheBlockSpacing() {
        let row = CodeRowHeightPlan.Row(blocks: [
            .text(height: 50),
            .attachments(height: 100),
        ])
        // 50, 8 between blocks, 100, 10 margins.
        #expect(CodeRowHeightPlan.height(rows: [row], metrics: metrics) == 168)
    }

    @Test func aSingleImageFitsTheLargeBoxAtItsClampedAspect() {
        // A 4:3 landscape fills the 200 pt box's width: 200 / (4/3) = 150.
        #expect(approximately(CodeAttachmentLayout.imageGridHeight(
            pixelSizes: [CGSize(width: 400, height: 300)]), 150))
        // A missing size reads as 4:3.
        #expect(approximately(CodeAttachmentLayout.imageGridHeight(pixelSizes: [nil]), 150))
        // A tall image clamps to 2/3 and fills the box's height.
        #expect(CodeAttachmentLayout.imageGridHeight(
            pixelSizes: [CGSize(width: 100, height: 300)]) == 200)
        // A wide image clamps to 3/2: 200 / 1.5.
        #expect(approximately(CodeAttachmentLayout.imageGridHeight(
            pixelSizes: [CGSize(width: 600, height: 200)]), 200 / 1.5))
    }

    @Test func twoImagesAreOneSquareRow() {
        #expect(CodeAttachmentLayout.imageGridHeight(pixelSizes: [nil, nil]) == 140)
    }

    @Test func threeAndMoreImagesAreTwoSquareRows() {
        // 3 → wide + 2 square; 4 → 2x2; 5+ → 2x2 with +N: all 140 + 8 + 140.
        #expect(CodeAttachmentLayout.imageGridHeight(pixelSizes: [nil, nil, nil]) == 288)
        #expect(CodeAttachmentLayout.imageGridHeight(
            pixelSizes: Array(repeating: nil, count: 4)) == 288)
        #expect(CodeAttachmentLayout.imageGridHeight(
            pixelSizes: Array(repeating: nil, count: 9)) == 288)
    }

    @Test func theFileGridUsesTheSameTileRule() {
        #expect(CodeAttachmentLayout.fileGridHeight(count: 0) == 0)
        // A single file has no pixel size: the unknown-pixel 4:3 rule puts
        // its large slot at 200x150.
        #expect(approximately(CodeAttachmentLayout.fileGridHeight(count: 1), 150))
        #expect(CodeAttachmentLayout.fileGridHeight(count: 2) == 140)
        #expect(CodeAttachmentLayout.fileGridHeight(count: 3) == 288)
        #expect(CodeAttachmentLayout.fileGridHeight(count: 5) == 288)
    }

    // `blockHeights` reads the shared `isImage` extension, which is
    // main-actor isolated under the package's default isolation.
    @Test @MainActor func imagesAndFilesAreSeparateGrids() throws {
        let image = try attachmentContent(["fileId": "i1", "mediaType": "image/png"])
        let secondImage = try attachmentContent(["fileId": "i2", "mediaType": "image/png"])
        let file = try attachmentContent(["fileId": "f1", "mediaType": "application/pdf"])

        // Two images and one file: one square row, then the 4:3 file slot.
        let mixedRow = CodeAttachmentLayout.blockHeights(files: [image, secondImage, file])
        #expect(mixedRow.count == 2)
        #expect(mixedRow[0] == 140)
        #expect(approximately(mixedRow[1], 150))
        // One image and two files: the image's own grid, then a square row.
        let mixed = CodeAttachmentLayout.blockHeights(files: [image, file, file])
        #expect(mixed.count == 2)
        #expect(approximately(mixed[0], 150))
        #expect(mixed[1] == 140)
    }

    @Test @MainActor func failedDocumentsUseTheCardHeightBeforeTheFileGrid() throws {
        let failed = try attachmentContent([
            "fileId": "f1", "mediaType": "application/pdf",
        ])
        let uploaded = try attachmentContent([
            "fileId": "f2", "mediaType": "application/pdf",
        ])
        let heights = CodeAttachmentLayout.blockHeights(
            files: [failed, uploaded],
            isFailed: { $0.fileId == "f1" })
        #expect(heights.count == 2)
        #expect(approximately(heights[0], 53.2))
        #expect(approximately(heights[1], 150))
    }

    @Test @MainActor func blockHeightsPreferTheProvidedPixelSize() throws {
        // The row view draws the locally decoded preview size when the store
        // has one; the measurer must take the same closure so the settled
        // height is not computed from stale server metadata.
        let image = try attachmentContent([
            "fileId": "i1", "mediaType": "image/png", "width": 400, "height": 300,
        ])
        let serverSized = CodeAttachmentLayout.blockHeights(files: [image])
        #expect(serverSized.count == 1)
        #expect(approximately(serverSized[0], 150))
        let previewSized = CodeAttachmentLayout.blockHeights(
            files: [image], pixelSize: { _ in CGSize(width: 300, height: 400) })
        #expect(previewSized.count == 1)
        #expect(approximately(previewSized[0], 200))
    }

    @Test func theFailedCardIsItsTextPlusPadding() {
        // 6 top + 8 bottom + (21 + 18.2) text. The leading box is
        // width-only, so 84 never enters the height.
        #expect(approximately(CodeAttachmentLayout.failedCardHeight(), 53.2))
    }

    private func approximately(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool {
        abs(lhs - rhs) < 0.001
    }

    private func attachmentContent(_ object: [String: Any]) throws -> V2AttachmentContent {
        V2AttachmentContent(rawContent: try decode(object))
    }
}
