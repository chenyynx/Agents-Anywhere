import SwiftUI
import UIKit

// The official failed-upload card (`ArtifactPreviewCard`, CLOSURE.md §3): a
// 520 pt-wide rounded card over a translucent neutral fill, with a clear
// leading thumbnail box, the file name and its type, and the artifact icon.
// The failed state is the card's own 0.5 opacity plus the warning glyph and an
// accessibility-only `upload_failed` label - there is no visible failure text.

/// One failed upload card.
struct CodeArtifactPreviewCard: View {
    let file: V2AttachmentContent
    /// The card is only reachable from the file row's `uploadFailed` list, so
    /// it is failed unless a caller renders a non-failed artifact preview.
    var isFailed: Bool = true

    @ScaledMetric(relativeTo: .body) private var scaledBoxWidth: CGFloat = 84
    @ScaledMetric(relativeTo: .subheadline) private var nameSize: CGFloat = 15
    @ScaledMetric(relativeTo: .subheadline) private var nameLineHeight: CGFloat = 21
    @ScaledMetric(relativeTo: .callout) private var typeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .callout) private var typeLineHeight: CGFloat = 18.2
    // [I] The official Anthropicon side is `textScale × sizePts[.large]`
    // (`font-default-icon-size-final.md` #2), 24 pt at the default size.
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 24
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        cardContent
            .opacity(isFailed ? 0.5 : 1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(accessibilityValue)
    }

    private var cardContent: some View {
        HStack(spacing: 20) {
            // The official leading box is a thumbnail slot with a width
            // constraint only: `Color.frame(width: min(ScaledMetric, 84))`
            // (`file-card-geometry.md` #5). The HStack's height comes from
            // the two text lines, not from an 84 pt box.
            Color.clear
                .frame(width: min(scaledBoxWidth, 84))
                .accessibilityHidden(true)
            texts
            // [U] The type alias carries `Spacer?`; whether the official body
            // instantiates it is not evidenced. It costs no height here.
            Spacer(minLength: 0)
            icon
        }
        .padding(.leading, 20)
        .padding(.trailing, 16)
        .padding(.top, 6)
        .padding(.bottom, 8)
        .frame(maxWidth: 520, alignment: .leading)
        .background(background,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        // CLOSURE.md §3: shadow radius 2 / x 0 / y 1 / 5 %.
        .shadow(color: .black.opacity(0.05), radius: 2, x: 0, y: 1)
    }

    /// The two text lines: name 15/400/21.0 and artifactType 13/400/18.2, with
    /// no extra line gap so the row's closed-form height matches
    /// `CodeAttachmentLayout.failedCardHeight` (CLOSURE.md §3).
    private var texts: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: file.name ?? String(localized: "附件"))
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                   size: nameSize,
                                                   weight: 400)))
                .foregroundStyle(CodeArtifactCardColors.name.resolved(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(height: nameLineHeight)
            Text(verbatim: artifactType)
                .font(Font(MarkdownFontFactory.font(name: CodePageTheme.sansFontName,
                                                   size: typeSize,
                                                   weight: 400)))
                .foregroundStyle(CodeArtifactCardColors.type.resolved(for: colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(height: typeLineHeight)
        }
    }

    /// The `#FAFCFF` artifact glyph (CLOSURE.md §3), always the UTType icon:
    /// `file-card-icon-deep.md` §1 and `attachment-badge-failure-deep.md` §3.3
    /// put the `anthropicon.warning` glyph on the attachment-tile overlay, not
    /// on this card. The failed card is marked by its own 0.5 opacity and the
    /// accessibility-only `upload_failed` label; its icon stays the artifact
    /// type.
    ///
    /// CLOSURE.md §3's `.large` 24x24 is a frame, so the glyph is aspect-fit
    /// into it (the same rule as the FileTile plate), not pinned to the
    /// smaller preset extent.
    private var icon: some View {
        Image(CodeArtifactIcon.name(for: file))
            .resizable()
            .scaledToFit()
            .frame(width: iconSide, height: iconSide)
            .foregroundStyle(CodeArtifactCardColors.iconTint.resolved(for: colorScheme))
            .accessibilityHidden(true)
    }

    /// The official type line. AA has no `artifactType` on the wire; the
    /// official value is a localized type word (`file-card-icon-deep.md` §3.2
    /// names the English leaves image/presentation/spreadsheet/diagram/
    /// document/code/file). [I] The filename extension is this client's
    /// stand-in, and a file without one reads as 文件.
    private var artifactType: String {
        let ext = ((file.name ?? "") as NSString).pathExtension.uppercased()
        return ext.isEmpty ? String(localized: "文件") : ext
    }

    private var background: Color {
        colorScheme == .dark
            ? Color(.sRGB, red: 1, green: 1, blue: 1).opacity(0.2)
            : Color(.sRGB, red: 0.043, green: 0.043, blue: 0.043).opacity(0.2)
    }

    private var accessibilityLabel: Text {
        isFailed ? Text(verbatim: String(localized: "upload_failed"))
                 : Text(verbatim: file.name ?? String(localized: "附件"))
    }

    /// The official card carries an `accessibilityValue` after the
    /// `upload_failed` label (`file-card-fonts-icon.md` §3); the value is the
    /// file name, so VoiceOver says which upload failed.
    private var accessibilityValue: Text {
        isFailed ? Text(verbatim: file.name ?? "") : Text(verbatim: "")
    }
}

/// The official card colours (CLOSURE.md §3: E).
private nonisolated enum CodeArtifactCardColors {
    static let name = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.043, green: 0.043, blue: 0.043),
        dark: Color(.sRGB, red: 0.941, green: 0.937, blue: 0.925))
    static let type = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.322, green: 0.318, blue: 0.306),
        dark: Color(.sRGB, red: 0.765, green: 0.761, blue: 0.718))
    static let iconTint = CodePageTheme.SchemeColor(
        light: Color(.sRGB, red: 0.98, green: 0.988, blue: 1),
        dark: Color(.sRGB, red: 0.98, green: 0.988, blue: 1))
}

/// The card's six artifact glyphs (CLOSURE.md §3, `file-card-icon-deep.md`):
/// image / chart / slides / spreadsheet / code / file. DOCX, PDF, TXT and
/// unknown types fall through to the file glyph.
nonisolated enum CodeArtifactIcon {
    static func name(for file: V2AttachmentContent) -> String {
        if file.mediaType?.hasPrefix("image/") == true { return "anthropicon.image" }
        switch ((file.name ?? "") as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "bmp", "svg":
            return "anthropicon.image"
        case "mmd", "mermaid", "chart", "diagram":
            return "anthropicon.chart"
        case "ppt", "pptx", "key", "odp":
            return "anthropicon.slides"
        case "csv", "xls", "xlsx", "numbers", "ods":
            return "anthropicon.spreadsheet"
        case "swift", "m", "mm", "py", "rb", "php", "js", "ts", "tsx", "jsx", "json",
             "html", "css", "scss", "rs", "go", "java", "kt", "c", "cpp", "h", "hpp",
             "sh", "bash", "zsh", "yaml", "yml", "toml", "sql", "xml", "pl", "lua",
             "dart", "cs":
            return "anthropicon.code"
        default:
            return "anthropicon.file"
        }
    }
}
