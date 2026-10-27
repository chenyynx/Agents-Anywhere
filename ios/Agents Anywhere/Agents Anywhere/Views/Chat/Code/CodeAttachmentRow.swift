import SwiftUI
import UIKit

// One user message's attachments, drawn outside the text bubble in official
// order (CLOSURE.md §4): the image grid first, then the file row. The file row
// itself draws failed uploads as `ArtifactPreviewCard`s before the successful
// file tiles, in one 8 pt stack (round25 `attachment-file-card.md` §0). The
// whole stack is trailing-aligned and shares the bubble's right edge; unlike
// the bubble it has no 36 pt opposite gutter, so it may extend 36 pt further
// left.

/// The attachment blocks of one user row.
struct CodeAttachmentRow: View {
    let files: [ChatMessageAttachment]
    var state: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onAttachment: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }
    var loadThumbnail: (V2AttachmentContent) async throws -> Data? = { _ in nil }

    var body: some View {
        let images = files.filter { $0.content.isImage }
        let documents = files.filter { !$0.content.isImage }
        let failedFiles = documents.filter { state($0.content) == .failed }
        let uploadedFiles = documents.filter { state($0.content) != .failed }

        VStack(alignment: .trailing, spacing: CodePageTheme.blockGap) {
            if !images.isEmpty {
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
                    if !uploadedFiles.isEmpty {
                        CodeFileTiles(files: uploadedFiles.map(\.content),
                                      state: state,
                                      onOpen: onAttachment)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
