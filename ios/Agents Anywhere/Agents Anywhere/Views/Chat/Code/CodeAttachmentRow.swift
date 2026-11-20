import SwiftUI
import UIKit

// One user message's attachments, drawn outside the text bubble in official
// order (CLOSURE.md §4): the image grid first, then the file row. The file row
// itself draws failed uploads as `ArtifactPreviewCard`s before the successful
// file tiles, in one 8 pt stack (round25 `attachment-file-card.md` §0). The
// whole stack is trailing-aligned and shares the bubble's right edge; unlike
// the bubble it has no 36 pt opposite gutter, so it may extend 36 pt further
// left.
//
// Images and files in the same message share ONE grid instead of stacking: a
// screenshot + log pair reads as a single row of 140 pt squares, the image
// cropped into its slot (pp 2026-11-20).

/// The attachment blocks of one user row.
struct CodeAttachmentRow: View {
    let files: [ChatMessageAttachment]
    var state: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }
    /// The send-state indicator of a pure-attachment row. It sits in the
    /// stack's leading gutter, bottom-aligned with the cards — the row spans
    /// the page, so anchoring it to the row's leading edge put the spinner at
    /// the screen's far left while the card hugged the right (pp 2026-11-16).
    var leadingAccessory: AnyView? = nil

    var body: some View {
        let images = files.filter { $0.content.isImage }
        let documents = files.filter { !$0.content.isImage }
        let failedFiles = documents.filter { state($0.content) == .failed }
        let uploadedFiles = documents.filter { state($0.content) != .failed }
        let mixed = !images.isEmpty && !uploadedFiles.isEmpty

        HStack(alignment: .bottom, spacing: 8) {
            Spacer(minLength: 0)
            if let leadingAccessory { leadingAccessory }
            VStack(alignment: .trailing, spacing: CodePageTheme.blockGap) {
                if mixed {
                    CodeMixedAttachmentTiles(images: images,
                                             files: uploadedFiles.map(\.content),
                                             state: state,
                                             onAttachment: onAttachment,
                                             loadThumbnail: loadThumbnail)
                } else if !images.isEmpty {
                    CodeAttachmentTiles(files: images,
                                        state: state,
                                        onAttachment: onAttachment,
                                        loadThumbnail: loadThumbnail)
                }
                if !documents.isEmpty {
                    VStack(alignment: .trailing, spacing: CodePageTheme.blockGap) {
                        // Failed uploads first: `SendUserMessageAttachmentRow`'s
                        // `ForEach(uploadFailed)` precedes the successful tiles
                        // (CLOSURE.md §4 / round25 `attachment-file-card.md` §0).
                        ForEach(failedFiles) { file in
                            CodeArtifactPreviewCard(file: file.content, isFailed: true)
                        }
                        if !uploadedFiles.isEmpty && !mixed {
                            CodeFileTiles(files: uploadedFiles.map(\.content),
                                          state: state,
                                          onOpen: onAttachment)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// Images and files of one message in a single grid of 140 pt squares: the
/// image crops into its slot, the file draws its card, so a screenshot and a
/// log sit side by side instead of stacking (pp 2026-11-20). Pairs trail-align
/// like every other attachment grid; an odd last row gets the official
/// leading filler. Five or more keep the four-tile cap with `+N` on the
/// fourth, matching the image grid.
private struct CodeMixedAttachmentTiles: View {
    let images: [ChatMessageAttachment]
    let files: [V2AttachmentContent]
    var state: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }

    var body: some View {
        CodeAttachmentGrid(rows: Self.rows(count: images.count + files.count)) { placement in
            if placement.index < images.count {
                let file = images[placement.index]
                CodeAttachmentImageTile(
                    file: file,
                    placement: placement,
                    state: state(file.content),
                    onAttachment: onAttachment,
                    loadThumbnail: loadThumbnail)
            } else if placement.index - images.count < files.count {
                let file = files[placement.index - images.count]
                CodeFileTile(
                    file: file,
                    size: CodeAttachmentTileMetrics.square,
                    overflow: placement.overflow,
                    state: state(file),
                    onOpen: onAttachment)
            }
        }
    }

    private static func square(_ index: Int, overflow: Int? = nil) -> CodeAttachmentGridPlan.Placement {
        CodeAttachmentGridPlan.Placement(index: index, size: .square, overflow: overflow)
    }

    private static func rows(count: Int) -> [[CodeAttachmentGridPlan.Placement]] {
        if count > 4 {
            return [[square(0), square(1)], [square(2), square(3, overflow: count - 4)]]
        }
        var rows: [[CodeAttachmentGridPlan.Placement]] = []
        var index = 0
        while index < count {
            if index + 1 < count {
                rows.append([square(index), square(index + 1)])
                index += 2
            } else {
                rows.append([CodeAttachmentGridPlan.Placement(index: -1, size: .square, overflow: nil),
                             square(index)])
                index += 1
            }
        }
        return rows
    }
}
