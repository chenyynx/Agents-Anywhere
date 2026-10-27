import SwiftUI
import UIKit

// The official successful file attachment (`FileTile`, CLOSURE.md §2): a
// solid tile, a top-aligned icon plate with 4 pt top corners and a subtle
// shadow, and one middle-truncated file name inset 10 pt at the bottom. The
// tile carries no border, chip or badge; the file/folder glyph is the only
// type signal. The slot sizes follow the same count-only grid as images.

/// One successful file tile.
struct CodeFileTile: View {
    let file: V2AttachmentContent
    let size: CGSize
    /// Set on the fourth tile when the row overflows (`N = 总数 - 4`).
    var overflow: Int?
    var state: CodeAttachmentDisplayState = .complete
    var onOpen: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .callout) private var nameSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var nameLineHeight: CGFloat = 18.2
    // [I] The official Anthropicon side is `textScale × sizePts[.large]`
    // (`font-default-icon-size-final.md` #2), 24 pt at the default size.
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 24

    var body: some View {
        Button { onOpen(file, nil) } label: {
            ZStack(alignment: .bottom) {
                // [I] CLOSURE.md §2 fixes the structure ("solid base") but not
                // the base colour; the user row's neutral fill keeps the file
                // tile consistent with the bubble it sits under.
                CodePageTheme.userBubbleFill.resolved(for: colorScheme)
                iconPlate
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                nameLabel
                // One overlay only: the overflow tile's `TileCountOverlay`
                // carries its own status child (see CodeAttachmentTiles).
                if let overflow {
                    CodeAttachmentCountOverlay(count: overflow, state: state)
                } else {
                    CodeAttachmentStateOverlay(state: state)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: CodeAttachmentTileMetrics.cornerRadius,
                                        style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CodeAttachmentTileMetrics.cornerRadius,
                                           style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: file.name ?? String(localized: "附件")))
    }

    /// The icon plate: the official glyph at `.large` inside a 10 pt padding,
    /// on a `Color.black.opacity(0.1)` plate whose top two corners are 4 pt
    /// continuous, with a shadow (CLOSURE.md §2).
    ///
    /// CLOSURE.md §2 gives the frame, not the artwork extent: the 24x24 frame
    /// is aspect-fit, so the ink lands at the official 18x24 (file), 24x24
    /// (image/chart), 24x18 (slides/spreadsheet) and 24x20.2 (code). Drawing
    /// through `AnthropiconView` would pin the smaller preset extent instead
    /// and leave the glyph undersized inside the frame.
    private var iconPlate: some View {
        // [I] The official icon layer builds `Color.white` as its tint
        // (`file-tile-round2.md` §6), but CLOSURE.md §2 does not pair it with
        // the tile's base fill. This tile uses the user-bubble fill as its
        // base, so the glyph inherits primary and stays legible in both
        // schemes; a literal white tint would disappear on the light base.
        Image(iconName)
            .resizable()
            .scaledToFit()
            .frame(width: iconSide, height: iconSide)
            .accessibilityHidden(true)
            .padding(10)
            .background(Color.black.opacity(0.1))
            .clipShape(UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 4,
                style: .continuous))
            // [I] CLOSURE.md §2 records a shadow but not its values; the
            // failed card's official 5% / radius 2 / y 1 (CLOSURE.md §3) is
            // the closest sampled pair.
            .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    /// One line, middle truncation, 13 pt relative / 550 / 18.2 pt line box,
    /// 10 pt inset on all sides, primary label colour (CLOSURE.md §2).
    private var nameLabel: some View {
        Text(verbatim: file.name ?? String(localized: "附件"))
            .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                               size: nameSize,
                                               weight: 550)))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: nameLineHeight)
            // The 10 pt inset applies inside the tile; the outer flexible
            // frame keeps the text leading-aligned at the tile's edge.
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// `.fileExtension` (a name with an extension) draws the file glyph;
    /// `.folder` and a missing badge draw the folder glyph (CLOSURE.md §2,
    /// CORRECTIONS #84). AA has no `TypeBadge`, so the filename decides.
    private var iconName: String {
        let name = file.name ?? ""
        return (name as NSString).pathExtension.isEmpty
            ? "anthropicon.folder"
            : "anthropicon.file"
    }
}

/// One message's successful files, in the same grid as images
/// (`AttachmentTiles<UploadedAttachment>` shares the generic layout,
/// CORRECTIONS #75). A successful file has no pixel size, so the three-item
/// predicate never selects a wide tile and the official fallback is 2+1
/// squares (`attachment-tiles-arrangement.md` §1).
struct CodeFileTiles: View {
    let files: [V2AttachmentContent]
    var state: (V2AttachmentContent) -> CodeAttachmentDisplayState = { _ in .complete }
    var onOpen: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }

    var body: some View {
        let rows = CodeAttachmentGridPlan.rows(count: files.count)
        CodeAttachmentGrid(rows: rows) { placement in
            if placement.isFiller {
                Color.clear
            } else if files.indices.contains(placement.index) {
                CodeFileTile(
                    file: files[placement.index],
                    size: size(for: placement.size),
                    overflow: placement.overflow,
                    state: state(files[placement.index]),
                    onOpen: onOpen)
            }
        }
    }

    private func size(for slot: CodeAttachmentGridPlan.TileSize) -> CGSize {
        switch slot {
        case .square: return CodeAttachmentTileMetrics.square
        case .wide: return CodeAttachmentTileMetrics.wide
        case .large: return CodeAttachmentTileMetrics.largeFile
        }
    }
}
