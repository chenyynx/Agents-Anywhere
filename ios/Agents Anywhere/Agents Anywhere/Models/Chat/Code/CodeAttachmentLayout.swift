import Foundation

/// The official user-attachment tile geometry, shared by the Code row's
/// height measurer and its view.
///
/// The official user message draws its attachments outside the text bubble as
/// two sibling blocks: an `AttachmentTiles` image grid, then a
/// `SendUserMessageAttachmentRow` file grid (CLOSURE.md §4). Both grids use
/// the same fixed tile sizes — `square` 140x140, `wide` 288x140, one 8 pt gap
/// — and the layout rule depends only on the tile count: 1 → one `large` tile
/// (a 200x200 box, aspect preserved and clamped 2/3–3/2), 2 → one square row,
/// 3 → wide on top / wide on the bottom / 2+1 squares, 4 and up → two rows
/// (CLOSURE.md §1, CORRECTIONS #92). The closed-form heights below are the
/// exact vertical sum of those rows, so the first frame and the settled frame
/// cannot disagree.
nonisolated enum CodeAttachmentLayout {
    /// Grid spacing, horizontal and vertical (CLOSURE.md §1: E).
    static let tileSpacing: CGFloat = 8
    /// The `square` tile side (CLOSURE.md §1: 140x140, E).
    static let squareSide: CGFloat = 140
    /// The `wide` tile width; its height is `squareSide`
    /// (CLOSURE.md §1: 288x140, E).
    static let wideWidth: CGFloat = 288
    /// The single-image `large` box (CLOSURE.md §1: 200x200 cap, E).
    static let largeBox: CGFloat = 200
    /// A single image with no usable pixel size draws at 4:3 inside the box
    /// (CLOSURE.md §1: 无尺寸用 4/3).
    static let defaultImageAspect: CGFloat = 4.0 / 3.0
    /// The aspect clamp for a single image (CLOSURE.md §1: 2/3–3/2).
    static let minimumImageAspect: CGFloat = 2.0 / 3.0
    static let maximumImageAspect: CGFloat = 3.0 / 2.0

    // MARK: - Grids

    /// The height of one `AttachmentTiles` image grid, in draw order.
    static func imageGridHeight(pixelSizes: [CGSize?]) -> CGFloat {
        gridHeight(count: pixelSizes.count,
                   largeHeight: largeImageHeight(pixelSize: pixelSizes.first ?? nil))
    }

    /// The height of one `AttachmentTiles<UploadedAttachment>` file grid. A
    /// file has no pixel size; the official card is the square 140 pt tile
    /// (device screenshots 2026-10-27), so the single-item `large` slot is
    /// also 140, not the image 200 box.
    static func fileGridHeight(count: Int) -> CGFloat {
        gridHeight(count: count, largeHeight: squareSide)
    }

    /// The vertical sum of the tile grid's rows.
    ///
    /// 1 → the large tile alone; 2 → one square row; 3 (wide + 2 square),
    /// 4 (2x2) and 5+ (2x2 with `+N`) all occupy two square rows separated by
    /// one gap, and `wide` has the square row's height.
    static func gridHeight(count: Int, largeHeight: CGFloat) -> CGFloat {
        switch count {
        case ..<1:
            return 0
        case 1:
            return largeHeight
        case 2:
            return squareSide
        default:
            return 2 * squareSide + tileSpacing
        }
    }

    /// The single image's box height: it fits a 200x200 box with its aspect
    /// clamped to 2/3–3/2, so a landscape image is box-width and a portrait
    /// image is box-height. A missing or malformed size reads as 4:3.
    static func largeImageHeight(pixelSize: CGSize?) -> CGFloat {
        guard let pixelSize, pixelSize.width > 0, pixelSize.height > 0 else {
            return largeBox / defaultImageAspect
        }
        let aspect = min(max(pixelSize.width / pixelSize.height,
                             minimumImageAspect), maximumImageAspect)
        return aspect >= 1 ? largeBox / aspect : largeBox
    }

    // MARK: - Blocks

    /// The heights of the attachment blocks one `.attachments` model block
    /// draws. Images and files are separate grids (CLOSURE.md §4), so a
    /// message with both pays two block heights and one block gap between
    /// them. `pixelSize` lets the caller prefer a locally decoded preview size
    /// over the server's reported dimensions; both are original pixels.
    ///
    /// A failed document is not part of the successful file grid: the
    /// official row draws it as an `ArtifactPreviewCard` before the tiles
    /// (`attachment-file-card.md` §0). The caller supplies both the state and
    /// the card height so the pending estimate and the view agree; a settled
    /// message leaves both defaults and sees only grids.
    ///
    /// Main-actor isolated because it reads the shared
    /// `V2AttachmentContent.isImage` extension, which is main-actor isolated
    /// under the package's default isolation; the measurer and the row view
    /// are both main-actor, so no call site crosses an actor.
    @MainActor static func blockHeights(
        files: [V2AttachmentContent],
        pixelSize: (V2AttachmentContent) -> CGSize? = { $0.serverPixelSize },
        isFailed: (V2AttachmentContent) -> Bool = { _ in false },
        failedCardHeight: ((V2AttachmentContent) -> CGFloat)? = nil
    ) -> [CGFloat] {
        let images = files.filter { $0.isImage }
        let documents = files.filter { !$0.isImage }
        var heights: [CGFloat] = []
        if !images.isEmpty {
            heights.append(imageGridHeight(pixelSizes: images.map(pixelSize)))
        }
        // The view's file block stacks failed cards first, then the
        // successful file grid; each is a child of the same 8 pt VStack.
        var failedDocuments: [V2AttachmentContent] = []
        var uploadedDocuments: [V2AttachmentContent] = []
        for file in documents {
            if isFailed(file) { failedDocuments.append(file) } else { uploadedDocuments.append(file) }
        }
        for file in failedDocuments {
            heights.append(failedCardHeight?(file) ?? Self.failedCardHeight())
        }
        if !uploadedDocuments.isEmpty {
            heights.append(fileGridHeight(count: uploadedDocuments.count))
        }
        return heights
    }

    // MARK: - Failed upload card

    /// `ArtifactPreviewCard`'s width cap (CLOSURE.md §3: E).
    static let failedCardMaxWidth: CGFloat = 520

    /// The failed upload card's height: top 6 / bottom 8 padding around the
    /// two text lines (name 15/21 + artifactType 13/18.2, CLOSURE.md §3).
    ///
    /// The leading `Color` box has a **width only** — `min(ScaledMetric, 84)`
    /// — so the HStack is sized by the two text lines, not by 84
    /// (`file-card-geometry.md` #5: no explicit height; the type alias is
    /// `Color.frame(width:)`). At the default size that is 6 + 8 + 39.2.
    ///
    /// [I] This closed form uses the default line heights; a call site that
    /// scales for Dynamic Type passes its own line heights in. Pinned by
    /// `CodeRowHeightPlanTests`.
    static func failedCardHeight(nameLineHeight: CGFloat = 21,
                                 typeLineHeight: CGFloat = 18.2,
                                 topPadding: CGFloat = 6,
                                 bottomPadding: CGFloat = 8) -> CGFloat {
        topPadding + bottomPadding + max(0, nameLineHeight + typeLineHeight)
    }
}
