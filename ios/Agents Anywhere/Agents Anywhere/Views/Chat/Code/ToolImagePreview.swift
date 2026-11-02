import SwiftUI
import UIKit

// The tool detail page's inline images.
//
// The server keeps an image tool result's structured `result` intact and
// replaces only `output` with a summary (AA server S1, 2026-11-02). This view
// decodes the base64 body from `result` on demand:
//
// - placeholder first, using the header-parsed pixel size for the aspect box;
// - `CGImageSourceCreateThumbnailAtIndex` through `ChatImageThumbnail.make`
//   (max 2048 px) off the main actor;
// - decoded thumbnails in an `NSCache` keyed by item id + content hash (+
//   block index for multi-image results).
//
// Only the full-screen tool detail renders this view: collapsed rows and row
// height plans never see it, so the timeline's row geometry is unchanged.

/// One tool-result image with its own loading / loaded / failed state.
struct ToolImagePreview: View {
    let image: CodeToolImage
    /// `itemId + contentHash (+ block index)`; stable across view updates.
    let cacheKey: String
    var index: Int = 1
    var total: Int = 1

    @State private var loadedImage: UIImage?
    @State private var isLoading = true
    @State private var failed = false
    @State private var attempt = 0

    /// The detail page's image ceiling. A 1170×4100 screenshot would otherwise
    /// take several screens; fitting first and capping height keeps the page
    /// scrollable without changing the source pixels.
    private static let maximumHeight: CGFloat = 480
    private static let cornerRadius: CGFloat = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
                .frame(maxWidth: .infinity)
                .frame(maxHeight: Self.maximumHeight)
                .background(Color(uiColor: .secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius,
                                           style: .continuous))
            if image.isDownsampled {
                Text("已降采样")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(cacheKey)#\(attempt)") {
            await load()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityLabel))
        .accessibilityValue(Text(verbatim: accessibilityValue))
        .accessibilityAddTraits(failed ? .isButton : .isImage)
        .accessibilityAction {
            if failed { attempt &+= 1 }
        }
    }

    @ViewBuilder private var content: some View {
        if let loadedImage {
            Image(uiImage: loadedImage)
                .resizable()
                .scaledToFit()
        } else {
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay {
                    if failed {
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
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                    } else {
                        ProgressView()
                    }
                }
        }
    }

    /// The placeholder box keeps the source aspect ratio, clamped so a very
    /// tall screenshot cannot produce a multi-screen placeholder before the
    /// thumbnail arrives. A missing size reads as 4:3.
    private var aspectRatio: CGFloat {
        guard let pixelSize = image.pixelSize,
              pixelSize.width > 0, pixelSize.height > 0 else {
            return 4.0 / 3.0
        }
        return min(max(pixelSize.width / pixelSize.height, 0.5), 3.0)
    }

    private var accessibilityLabel: String {
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

/// A vertical stack of a tool call's images, in wire order.
struct ToolImagePreviewSection: View {
    let images: [CodeToolImage]
    let itemId: String
    let contentHash: String

    var body: some View {
        VStack(alignment: .leading, spacing: CodePageTheme.blockSpacing) {
            ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                ToolImagePreview(
                    image: image,
                    cacheKey: "\(itemId)#\(contentHash)#\(index)",
                    index: index + 1,
                    total: images.count)
            }
        }
    }
}

/// Decoded thumbnail cache keyed by item identity. `NSCache` evicts under
/// memory pressure; the key includes `contentHash`, so a row that changes
/// (revision / completed result) never shows a previous version's image.
@MainActor
final class ToolImagePreviewCache {
    static let shared = ToolImagePreviewCache()

    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 32
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func insert(_ image: UIImage, for key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        cache.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
