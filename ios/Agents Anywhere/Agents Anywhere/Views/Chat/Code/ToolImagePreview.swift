import SwiftUI
import UIKit

// The tool detail page's inline images, in the official shape (RE of the
// Claude binary, build 1261005):
//
// - `ToolCallDetailSections.Body` puts `AttachmentBar<ImageData>` after the
//   output and before the subagent totals.
// - `AttachmentBar` is a horizontal `ScrollView` over `AttachmentBarTile`s.
//   The tile body loads `0x4058000000000000` (= 96.0) into its frame layout,
//   so a tile is 96 x 96.
// - Tapping a tile calls `onImageSelected(UUID)`; `ToolCallDetailContent`
//   stores the selection in `__imagePreview` and presents
//   `ToolCallImagePreview` with `FileGallery` / `FilePreviewPage` — a
//   full-screen gallery.
//
// Decoding is lazy and shared: the thumbnail uses a 288 px ceiling, the
// gallery page 2048 px. Both go through `ChatImageThumbnail` (ImageIO's
// `CGImageSourceCreateThumbnailAtIndex`) off the main actor and land in one
// `NSCache` keyed by item id + content hash + block index + variant.
//
// Collapsed rows and row height plans never see these views: only the pushed
// tool-detail page mounts the bar, so the timeline's geometry is unchanged.

/// One tool call's images as the official horizontal attachment bar.
struct ToolImageAttachmentBar: View {
    let images: [CodeToolImage]
    let itemId: String
    let contentHash: String

    @State private var selection: ToolImageSelection?

    /// [E] `AttachmentBarTile` body: 96.0 frame constant.
    private static let tileSize: CGFloat = 96
    /// [I] Shared attachment-grid spacing (4 pt); the bar's spacing constant
    /// was not located in the binary.
    private static let tileSpacing: CGFloat = 4

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            // Lazy: a pathological row can carry 100 blocks; only the visible
            // tiles should mount and start decoding.
            LazyHStack(spacing: Self.tileSpacing) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    Button {
                        selection = ToolImageSelection(index: index)
                    } label: {
                        ToolImageThumbnail(
                            image: image,
                            index: index + 1,
                            total: images.count,
                            cacheKey: ToolImagePreviewCache.key(
                                itemId: itemId,
                                contentHash: contentHash,
                                index: index,
                                variant: "thumb"),
                            tileSize: Self.tileSize)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("查看图片"))
                }
            }
        }
        .scrollClipDisabled()
        .fullScreenCover(item: $selection) { selection in
            ToolImageGallery(
                images: images,
                itemId: itemId,
                contentHash: contentHash,
                initialIndex: selection.index)
        }
    }
}

/// One square tile in the bar. Styling mirrors the existing official-derived
/// attachment tile (`CodeAttachmentTileMetrics` / `CodeAttachmentHairline`).
private struct ToolImageThumbnail: View {
    let image: CodeToolImage
    let index: Int
    let total: Int
    let cacheKey: String
    let tileSize: CGFloat

    @State private var loadedImage: UIImage?
    @State private var failed = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private static let cornerRadius = CodeAttachmentTileMetrics.cornerRadius
    /// 96 pt at 3x. The tile is fixed-size, so a fixed ceiling is exact.
    private nonisolated static let thumbnailPixelSize = 288

    var body: some View {
        ZStack {
            Color(.secondarySystemFill)
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable(resizingMode: .stretch)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: tileSize, height: tileSize)
                    .clipped()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: tileSize, height: tileSize)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius,
                                   style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(CodeAttachmentHairline.color.resolved(for: colorScheme),
                              lineWidth: 1 / displayScale)
        )
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius,
                                      style: .continuous))
        .task(id: cacheKey) {
            await load()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: toolImageAccessibilityLabel(
            image, index: index, total: total)))
        .accessibilityValue(Text(verbatim: failed
            ? String(localized: "图片加载失败") : ""))
        .accessibilityAddTraits(.isImage)
    }

    private func load() async {
        if let cached = ToolImagePreviewCache.shared.image(for: cacheKey) {
            loadedImage = cached
            failed = false
            return
        }
        let base64 = image.base64
        let thumbnailData: Data? = await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64) else { return nil }
            return ChatImageThumbnail.make(
                data: data, maxPixelSize: Self.thumbnailPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        if let thumbnailData, let decoded = UIImage(data: thumbnailData) {
            ToolImagePreviewCache.shared.insert(decoded, for: cacheKey)
            loadedImage = decoded
            failed = false
        } else {
            loadedImage = nil
            failed = true
        }
    }
}

/// The full-screen gallery opened by a tile tap (official
/// `ToolCallImagePreview` + `FileGallery`).
private struct ToolImageGallery: View {
    let images: [CodeToolImage]
    let itemId: String
    let contentHash: String

    @State private var index: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [CodeToolImage],
         itemId: String,
         contentHash: String,
         initialIndex: Int) {
        self.images = images
        self.itemId = itemId
        self.contentHash = contentHash
        _index = State(initialValue: min(max(initialIndex, 0),
                                        max(images.count - 1, 0)))
    }

    var body: some View {
        NavigationStack {
            TabView(selection: $index) {
                ForEach(Array(images.enumerated()), id: \.element.id) { offset, image in
                    ToolImagePreview(
                        image: image,
                        index: offset + 1,
                        total: images.count,
                        cacheKey: ToolImagePreviewCache.key(
                            itemId: itemId,
                            contentHash: contentHash,
                            index: offset,
                            variant: "full"))
                        .tag(offset)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            // The official gallery's `_BackgroundStyleModifier<Color>` is a
            // design token, not a literal black/white. Follow the app's
            // adaptive background so light mode stays light.
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .toolbar {
                SheetCloseToolbar { dismiss() }
            }
            .navigationTitle(Text(verbatim: images.count > 1
                ? "\(index + 1) / \(images.count)" : ""))
            .navigationBarTitleDisplayMode(.inline)
        }
        // No `preferredColorScheme` and no colorScheme environment override:
        // either one can leak back into the presenting tool-detail sheet and
        // leave it dark after the gallery closes.
        .statusBarHidden(true)
    }
}

/// One full-resolution page in the gallery. Rendered only by the full-screen
/// presentation, never by the detail page or a collapsed row.
private struct ToolImagePreview: View {
    let image: CodeToolImage
    let index: Int
    let total: Int
    let cacheKey: String

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()
            if let loadedImage {
                Image(uiImage: loadedImage)
                    .resizable()
                    .scaledToFit()
            } else if failed {
                Button {
                    attempt &+= 1
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: "photo.badge.exclamationmark")
                            .font(.title2)
                        Text("重试")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(cacheKey)#\(attempt)") {
            await load()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: toolImageAccessibilityLabel(
            image, index: index, total: total)))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityAddTraits(failed ? .isButton : .isImage)
        .accessibilityAction {
            if failed { attempt &+= 1 }
        }
    }

    private var accessibilityValue: String {
        if failed { return String(localized: "图片加载失败") }
        if isLoading { return String(localized: "Loading") }
        return ""
    }

    private func load() async {
        if let cached = ToolImagePreviewCache.shared.image(for: cacheKey) {
            loadedImage = cached
            isLoading = false
            failed = false
            return
        }
        isLoading = true
        failed = false
        let base64 = image.base64
        let maxPixelSize = Int(CodeToolImages.maximumDisplayPixelSize)
        let thumbnailData: Data? = await Task.detached(priority: .userInitiated) {
            guard let data = Data(base64Encoded: base64) else { return nil }
            return ChatImageThumbnail.make(data: data, maxPixelSize: maxPixelSize)
        }.value
        guard !Task.isCancelled else { return }
        if let thumbnailData, let decoded = UIImage(data: thumbnailData) {
            ToolImagePreviewCache.shared.insert(decoded, for: cacheKey)
            loadedImage = decoded
            isLoading = false
        } else {
            loadedImage = nil
            isLoading = false
            failed = true
        }
    }
}

private struct ToolImageSelection: Identifiable {
    let index: Int
    var id: Int { index }
}

/// Decoded image cache keyed by item identity + variant. `NSCache` evicts
/// under memory pressure; `contentHash` keeps a row's previous revision from
/// showing after the row changes.
@MainActor
final class ToolImagePreviewCache {
    static let shared = ToolImagePreviewCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 64
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    static func key(
        itemId: String,
        contentHash: String,
        index: Int,
        variant: String
    ) -> String {
        "\(itemId)#\(contentHash)#\(index)#\(variant)"
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
    }
}

private func toolImageAccessibilityLabel(
    _ image: CodeToolImage,
    index: Int,
    total: Int
) -> String {
    var parts = [String(localized: "图片附件")]
    if total > 1 {
        parts[0] += " \(index)/\(total)"
    }
    parts.append(CodeToolImages.typeLabel(image.mediaType))
    if let pixelSize = image.pixelSize {
        parts.append("\(Int(pixelSize.width.rounded()))×\(Int(pixelSize.height.rounded()))")
    }
    if let byteCount = image.byteCount {
        parts.append(CodeToolImages.formatBytes(byteCount))
    }
    return parts.joined(separator: ", ")
}
