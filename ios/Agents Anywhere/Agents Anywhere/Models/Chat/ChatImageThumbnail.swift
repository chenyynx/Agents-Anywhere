import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum ChatImageThumbnail {
    static let maximumBubbleWidth: CGFloat = 240
    static let maximumBubbleHeight: CGFloat = 320
    static let minimumBubbleAspectRatio: CGFloat = 0.6
    static let maximumBubbleAspectRatio: CGFloat = 1.8
    /// Covers the 320pt bubble height at a 3x display scale.
    static let defaultMaximumPixelSize = 960

    static func bubbleSize(for imageSize: CGSize) -> CGSize? {
        guard imageSize.width.isFinite, imageSize.height.isFinite,
              imageSize.width > 0, imageSize.height > 0 else { return nil }
        return bubbleSize(forAspectRatio: imageSize.width / imageSize.height)
    }

    static func bubbleSize(forAspectRatio aspectRatio: CGFloat) -> CGSize? {
        guard aspectRatio.isFinite, aspectRatio > 0 else { return nil }
        let ratio = min(max(aspectRatio, minimumBubbleAspectRatio), maximumBubbleAspectRatio)
        let width = min(maximumBubbleWidth, maximumBubbleHeight * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    static func shouldAlignTop(for aspectRatio: CGFloat) -> Bool {
        aspectRatio.isFinite && aspectRatio > 0 && aspectRatio < minimumBubbleAspectRatio
    }

    static func gridCellSize(maximumWidth: CGFloat = maximumBubbleWidth, spacing: CGFloat = 4) -> CGFloat {
        max(0, (maximumWidth - spacing) / 2)
    }

    static func maximumPixelSize(for size: CGSize, displayScale: CGFloat) -> Int {
        guard size.width.isFinite, size.height.isFinite, displayScale.isFinite,
              size.width > 0, size.height > 0, displayScale > 0 else { return 1 }
        return max(1, Int(ceil(max(size.width, size.height) * displayScale)))
    }

    static func imageSize(data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return imageSize(source: source)
    }

    /// Positive whole-pixel dimensions for upload metadata, or nil when the
    /// size is missing, fractional or not a usable original-image size.
    static func pixelDimensions(for size: CGSize?) -> (width: Int, height: Int)? {
        guard let size, size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0,
              size.width == size.width.rounded(), size.height == size.height.rounded() else { return nil }
        return (Int(size.width), Int(size.height))
    }

    static func make(data: Data, maxPixelSize: Int = defaultMaximumPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let targetPixelSize = max(1, maxPixelSize)
        if let size = imageSize(source: source), max(size.width, size.height) <= CGFloat(targetPixelSize) { return data }
        return make(source: source, maxPixelSize: targetPixelSize)
    }

    static func make(url: URL, maxPixelSize: Int = defaultMaximumPixelSize) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        return make(source: source, maxPixelSize: maxPixelSize)
    }

    private static func imageSize(source: CGImageSource) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as NSDictionary?,
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let pixelWidth = CGFloat(width.doubleValue)
        let pixelHeight = CGFloat(height.doubleValue)
        guard pixelWidth.isFinite, pixelHeight.isFinite, pixelWidth > 0, pixelHeight > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: pixelHeight, height: pixelWidth)
            : CGSize(width: pixelWidth, height: pixelHeight)
    }

    private static func make(source: CGImageSource, maxPixelSize: Int) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
