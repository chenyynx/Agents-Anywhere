import SwiftUI
import UIKit

/// The composer's pending attachment tile. Official (1.261023.20, round30):
/// `AttachmentBarTile` → `FilePreview` — 96 pt height cap, 16 pt radius,
/// `bg000` fill, `border20` hairline, a 24 pt remove circle inset 8 pt, and a
/// file face of type badge + name (no byte size).
struct ChatComposerAttachment: View {
    let attachment: ChatAttachment
    let onRemove: () -> Void
    var onEdit: (() -> Void)? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: UIImage?

    /// The screenshot renders 80 pt squares; the binary caps the height at 96
    /// and lets the content decide, so 80 is the shipped-looking value.
    private let tileSize: CGFloat = 80
    private let cornerRadius: CGFloat = 16

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    var body: some View {
        tile
            .frame(width: tileSize, height: tileSize)
            .clipShape(shape)
            .overlay { shape.strokeBorder(AppTheme.composerTileBorder(colorScheme), lineWidth: 1) }
            .overlay(alignment: .topTrailing) { removeButton }
            .task(id: attachment.previewData) {
                if let data = attachment.previewData { image = UIImage(data: data) }
            }
            .accessibilityLabel(attachment.name)
    }

    @ViewBuilder
    private var tile: some View {
        if let onEdit, attachment.isImage {
            Button(action: onEdit) { face }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityHint(String(localized: "编辑图片"))
        } else {
            face
        }
    }

    private var face: some View {
        ZStack {
            AppTheme.composerTileBackground(colorScheme)
            if attachment.isImage {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    AppSymbol("photo", size: 20)
                        .foregroundStyle(AppTheme.composerSecondaryGlyph(colorScheme))
                }
            } else {
                fileFace
            }
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Color(white: 0.10)))
                .shadow(color: .black.opacity(0.15), radius: 2)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "移除 \(attachment.name)"))
    }

    private var fileFace: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let badge = typeBadge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(AppTheme.composerTileBackground(colorScheme)))
                    .overlay { Capsule().strokeBorder(AppTheme.composerTileBorder(colorScheme), lineWidth: 1) }
            }
            Spacer(minLength: 4)
            Text(attachment.name)
                // The name is secondary to the type badge; 15 pt wrapped a
                // long name into two oversized lines inside the 80 pt tile
                // (pp 2026-11-05).
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.composerControlGlyph(colorScheme))
                .lineLimit(2)
                .truncationMode(.middle)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(8)
    }

    private var typeBadge: String? {
        ComposerAttachmentBadge.text(for: attachment.name)
    }
}
