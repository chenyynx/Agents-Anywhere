import SwiftUI
import UIKit

// The official successful-file card (Claude iOS Code page, verified from
// device screenshots 2026-10-27): a 140x140 white tile with a hairline
// border, a gray thumbnail mat, a white page preview with the file glyph,
// and a two-line footer (name + extension). This is not the simple
// "Color base + icon plate + one-line name" FileTile shape from round25;
// that evidence describes a different surface. The screenshot card is the
// view the Code page actually draws for `.md` / `.txt` / `.conf` files.

/// One successful file tile.
struct CodeFileTile: View {
    let file: V2AttachmentContent
    let size: CGSize
    /// Set on the fourth tile when the row overflows (`N = 总数 - 4`).
    var overflow: Int?
    var state: CodeAttachmentDisplayState = .complete
    var onOpen: (V2AttachmentContent, UIImage?) -> Void = { _, _ in }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @ScaledMetric(relativeTo: .callout) private var nameSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var nameLineHeight: CGFloat = 18.2
    @ScaledMetric(relativeTo: .callout) private var typeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var typeLineHeight: CGFloat = 18.2

    /// Fixed footer padding measured from the official/AA pair: the name ink
    /// starts 6.5 pt below the mat and the type ink ends 6.3 pt above the card
    /// bottom, i.e. 3.0 pt above and 2.5 pt below the two line boxes. These
    /// are fixed points, not `@ScaledMetric` (the official padding does not
    /// grow with the text).
    private static let footerTopPadding: CGFloat = 3
    private static let footerBottomPadding: CGFloat = 2.5
    private static let previewTopInset: CGFloat = 12
    /// The white page's top corner is much tighter than the 14 pt outer card:
    /// the same-device screenshot gives 26 px on a 988 px card (≈3.7 pt), so
    /// the official value is 4 pt, not the 8 pt used before.
    private static let previewCornerRadius: CGFloat = 4

    var body: some View {
        Button { onOpen(file, nil) } label: {
            card
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: file.name ?? String(localized: "附件")))
    }

    /// The screenshot geometry: 140 pt tile. The footer is the two 18.2 pt
    /// line boxes plus 3 pt top and 2.5 pt bottom padding; the mat/white
    /// preview takes the rest. The preview has a 14 pt side inset and a 12 pt
    /// top inset. The glyph is centered in the whole card, not the shorter
    /// preview well (device screenshot 2026-10-27, cross-checked against the
    /// AA capture on the same 1179x2556 canvas).
    private var card: some View {
        VStack(spacing: 0) {
            thumbnail
                .frame(height: matHeight)
            texts
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .background(CodeFileCardColors.card.resolved(for: colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // Same ShadowEffect as the artifact card: opacity 0.05, radius 2,
        // y offset 1 (E values: round25/CLOSURE.md §3 and
        // file-card-style-round3.md). The successful card uses the same card
        // style [I]; the flat version read as a more-rounded card because
        // the soft edge was missing.
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CodeFileCardColors.border.resolved(for: colorScheme),
                              lineWidth: 1 / displayScale)
        )
        .overlay {
            // One overlay only: an overflow tile owns the +N overlay, which
            // carries its own status child (CodeAttachmentCountOverlay).
            if let overflow {
                CodeAttachmentCountOverlay(count: overflow, state: state)
            } else {
                CodeAttachmentStateOverlay(state: state)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// The gray mat + white page preview. The preview keeps rounded corners
    /// and a hairline border; the file glyph is the official `.large`
    /// Anthropicon (15x20 at the default size).
    private var thumbnail: some View {
        ZStack {
            CodePageTheme.userBubbleFill.resolved(for: colorScheme)
            // The official white page has rounded top corners and a square
            // bottom edge: its bottom border is absent, so the page and the
            // white footer read as one surface. A four-sided rounded border
            // (the previous shape) drew a faint line under the preview that
            // the official card does not have (CORRECTIONS #105).
            UnevenRoundedRectangle(topLeadingRadius: Self.previewCornerRadius,
                                   bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0,
                                   topTrailingRadius: Self.previewCornerRadius,
                                   style: .continuous)
                .fill(CodeFileCardColors.preview.resolved(for: colorScheme))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: Self.previewCornerRadius,
                                           bottomLeadingRadius: 0,
                                           bottomTrailingRadius: 0,
                                           topTrailingRadius: Self.previewCornerRadius,
                                           style: .continuous)
                        .strokeBorder(
                            CodeFileCardColors.previewBorder.resolved(for: colorScheme),
                            lineWidth: 1 / displayScale)
                )
                // Erase only the bottom stroke; the side strokes still run to
                // the footer boundary.
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(CodeFileCardColors.preview.resolved(for: colorScheme))
                        .frame(height: 1.5 / displayScale)
                }
                .overlay(
                    AnthropiconView(name: iconName, size: .large)
                        .foregroundStyle(CodeFileCardColors.icon.resolved(for: colorScheme))
                        // The official glyph sits on the card's vertical
                        // center (measured 0.7 pt above it), not on the
                        // shorter preview well's center.
                        .offset(y: iconCenterOffset)
                )
                .padding(.horizontal, 14)
                .padding(.top, Self.previewTopInset)
        }
    }

    private var texts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: file.name ?? String(localized: "附件"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: nameSize,
                                                    weight: 550)))
                .foregroundStyle(CodeFileCardColors.name.resolved(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: nameLineHeight)
            Text(verbatim: typeLabel)
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                    size: typeSize,
                                                    weight: 400)))
                .foregroundStyle(CodeFileCardColors.type.resolved(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: typeLineHeight)
        }
        .padding(.horizontal, 10)
        .padding(.top, Self.footerTopPadding)
        .padding(.bottom, Self.footerBottomPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var matHeight: CGFloat {
        max(0, size.height
            - (nameLineHeight + typeLineHeight
                + Self.footerTopPadding + Self.footerBottomPadding))
    }

    /// Move the glyph from the preview well's center to the card's center.
    /// The preview is `matHeight - previewTopInset` tall, so its center is
    /// `previewTopInset + (matHeight - previewTopInset) / 2`.
    private var iconCenterOffset: CGFloat {
        let previewCenter = Self.previewTopInset
            + (matHeight - Self.previewTopInset) / 2
        return max(0, size.height / 2 - previewCenter)
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

    /// The footer's second line. The official card shows the extension in
    /// caps (`MD`, `TXT`); a folder/extensionless file falls back to the
    /// localized type word.
    private var typeLabel: String {
        let ext = ((file.name ?? "") as NSString).pathExtension.uppercased()
        if !ext.isEmpty { return ext }
        return iconName == "anthropicon.folder"
            ? String(localized: "文件夹")
            : String(localized: "文件")
    }
}

/// The screenshot card colours. The light row is sampled from the official
/// device screenshots; the dark row is [I] (no dark screenshot was captured).
private nonisolated enum CodeFileCardColors {
    /// The code card surface (`CodePageTheme.codeCardFillUIColor`): white /
    /// #20201F. The file card uses the same surface and the same hairline
    /// as the fenced code card.
    static let card = CodePageTheme.SchemeColor(
        light: .white,
        dark: Color(.sRGB, red: 32.0 / 255.0,
                    green: 32.0 / 255.0, blue: 31.0 / 255.0))
    static let preview = card
    /// Exactly the code card border token, shared with the image tiles.
    static let border = CodeAttachmentHairline.color
    static let previewBorder = border
    /// File name: sampled #0B0B0B.
    static let name = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.043, green: 0.043, blue: 0.043),
        dark: Color(.sRGB, red: 0.941, green: 0.937, blue: 0.925))
    /// Extension line: sampled #52514E.
    static let type = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.322, green: 0.318, blue: 0.306),
        dark: Color(.sRGB, red: 0.765, green: 0.761, blue: 0.718))
    /// Glyph: sampled #8C8C8C.
    static let icon = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.549, green: 0.549, blue: 0.549),
        dark: Color(.sRGB, red: 0.627, green: 0.627, blue: 0.604))
}

/// One message's successful files, in the same grid as images
/// (`AttachmentTiles<UploadedAttachment>` shares the generic layout,
/// CORRECTIONS #75). A successful file has no pixel size, so the three-item
/// predicate never selects a wide tile and the official fallback is 2+1
/// squares (`attachment-tiles-arrangement.md` §1). Every file slot is the
/// official 140 pt square.
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
                    size: CodeAttachmentTileMetrics.square,
                    overflow: placement.overflow,
                    state: state(files[placement.index]),
                    onOpen: onOpen)
            }
        }
    }
}
