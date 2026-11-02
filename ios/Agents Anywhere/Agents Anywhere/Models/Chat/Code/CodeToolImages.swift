import CoreGraphics
import Foundation

// Inline images inside a tool result.
//
// The server replaces a pure-image tool result's `output` with an English
// summary and keeps the structured `result` untouched (AA server S1,
// 2026-11-02). The client therefore reads the image bytes from `result` and
// never from `output`:
//
// - Claude tool results are a list of content blocks (or a wrapper mapping
//   whose `content` is that list); an image block is
//   `{"type":"image","source":{"type":"base64","media_type":...,
//   "data":...}}`.
// - Codex/DSH shapes may vary, so the walk is bounded and accepts a `result`
//   key on a wrapper too, mirroring the server's collector.
//
// This file is ClientCore (no SwiftUI/UIKit): the block walk, byte count,
// header-only dimensions and the summary text are all unit-testable. The
// detail view decodes and downsamples the bytes separately.

/// One inline image carried by a tool result.
nonisolated struct CodeToolImage: Hashable, Identifiable {
    /// Stable within the session: the timeline item id plus the block index.
    let id: String
    let mediaType: String?
    /// Raw base64 as the wire carries it (no `data:` prefix in practice).
    let base64: String
    /// Decoded byte count, derived from the base64 length without decoding.
    let byteCount: Int?
    /// Pixel size parsed from the format header; nil for unknown/corrupt data.
    let pixelSize: CGSize?

    /// True when the source exceeds the detail view's display ceiling, so the
    /// view will draw a downsampled thumbnail. A header we cannot parse falls
    /// back to the byte size: a very large body is still called out.
    var isDownsampled: Bool {
        if let pixelSize {
            return max(pixelSize.width, pixelSize.height)
                > CodeToolImages.maximumDisplayPixelSize
        }
        if let byteCount {
            return byteCount > 8 * 1024 * 1024
        }
        return false
    }
}

nonisolated enum CodeToolImages {
    /// The detail view's thumbnail ceiling (`CGImageSourceCreateThumbnailAtIndex`).
    static let maximumDisplayPixelSize: CGFloat = 2048

    private static let maximumBlocks = 100
    private static let maximumDepth = 4
    private static let headerByteCount = 64 * 1024
    private static let headerBase64Characters = ((headerByteCount + 2) / 3) * 4

    // MARK: - Extraction

    static func images(in item: V2TimelineItem) -> [CodeToolImage] {
        images(in: item.raw["content"] ?? .object([:]), itemId: item.id)
    }

    static func images(in content: JSONValue, itemId: String) -> [CodeToolImage] {
        guard let result = content["result"], result != .null else { return [] }
        var blocks: [JSONValue] = []
        collect(result, depth: 0, into: &blocks)
        return blocks.enumerated().compactMap { index, block in
            guard let object = block.objectValue else { return nil }
            let source = object["source"]?.objectValue ?? object
            guard let rawData = source["data"]?.stringValue ?? object["data"]?.stringValue,
                  !rawData.isEmpty else { return nil }
            let (data, dataURLMediaType) = normalizedBase64(rawData)
            let mediaType = source["media_type"]?.stringValue
                ?? source["mediaType"]?.stringValue
                ?? dataURLMediaType
            // Decode the header once: it validates the base64 prefix and
            // yields the aspect size. Invalid data keeps the block (the view
            // shows its failure state) but reports no size.
            let header = headerData(base64: data)
            return CodeToolImage(
                id: "\(itemId)#\(index)",
                mediaType: mediaType,
                base64: data,
                byteCount: header == nil ? nil : structuralByteCount(base64: data),
                pixelSize: header.flatMap(pixelSize(in:)))
        }
    }

    /// Bounded walk for `type=image` blocks, mirroring the server collector.
    private static func collect(
        _ value: JSONValue,
        depth: Int,
        into blocks: inout [JSONValue]
    ) {
        guard depth <= maximumDepth, blocks.count < maximumBlocks else { return }
        switch value {
        case let .object(object):
            if object["type"]?.stringValue == "image" {
                blocks.append(value)
                return
            }
            for key in ["content", "result"] {
                if let nested = object[key] {
                    collect(nested, depth: depth + 1, into: &blocks)
                }
            }
        case let .array(items):
            for item in items {
                guard blocks.count < maximumBlocks else { return }
                collect(item, depth: depth + 1, into: &blocks)
            }
        default:
            break
        }
    }

    // MARK: - Summary

    /// The same English summary the server writes into `output`:
    /// `[Image] PNG · 1170×4100 · 559 KB`; several images are numbered and
    /// separated by newlines. Segments the payload does not carry are omitted.
    static func summary(for images: [CodeToolImage]) -> String {
        images.enumerated().map { index, image in
            let prefix = images.count > 1 ? "[Image \(index + 1)]" : "[Image]"
            var segments = [typeLabel(image.mediaType)]
            if let pixelSize = image.pixelSize,
               pixelSize.width > 0, pixelSize.height > 0 {
                segments.append(
                    "\(Int(pixelSize.width.rounded()))×\(Int(pixelSize.height.rounded()))")
            }
            if let byteCount = image.byteCount {
                segments.append(formatBytes(byteCount))
            }
            return "\(prefix) " + segments.joined(separator: " · ")
        }.joined(separator: "\n")
    }

    /// Whether `text` is exactly the summary this client would generate.
    /// Used to avoid drawing the server's summary text above the images.
    static func isServerImageSummary(_ text: String, images: [CodeToolImage]) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !images.isEmpty else { return false }
        return trimmed == summary(for: images)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Formatting

    static func typeLabel(_ mediaType: String?) -> String {
        guard let mediaType, mediaType.lowercased().hasPrefix("image/") else {
            return "IMAGE"
        }
        let subtype = mediaType.split(separator: "/", maxSplits: 1)
            .last.map { String($0) }?.uppercased() ?? ""
        if subtype.isEmpty { return "IMAGE" }
        return subtype == "JPG" ? "JPEG" : subtype
    }

    static func formatBytes(_ byteCount: Int) -> String {
        guard byteCount >= 1024 else { return "\(byteCount) B" }
        var value = Double(byteCount) / 1024
        var unit = "KB"
        if value >= 1024 {
            value /= 1024
            unit = "MB"
        }
        var text = String(format: "%.1f", value)
        if text.hasSuffix(".0") { text.removeLast(2) }
        return "\(text) \(unit)"
    }

    // MARK: - Base64 and image headers

    /// Decoded size from the base64 text itself; no body copy. The header
    /// prefix is also decoded so non-base64 payloads report no size.
    static func decodedByteCount(base64: String) -> Int? {
        guard headerData(base64: base64) != nil else { return nil }
        return structuralByteCount(base64: base64)
    }

    private static func structuralByteCount(base64: String) -> Int? {
        guard !base64.isEmpty, base64.count % 4 == 0 else { return nil }
        let padding: Int
        if base64.hasSuffix("==") {
            padding = 2
        } else if base64.hasSuffix("=") {
            padding = 1
        } else {
            padding = 0
        }
        let bodyEnd = base64.count - padding
        if base64.prefix(bodyEnd).contains("=") { return nil }
        return base64.count / 4 * 3 - padding
    }

    /// Header-only pixel size for PNG / JPEG / GIF / WebP.
    static func pixelSize(base64: String) -> CGSize? {
        guard let data = headerData(base64: base64) else { return nil }
        return pixelSize(in: data)
    }

    static func pixelSize(in data: Data) -> CGSize? {
        let bytes = [UInt8](data)
        return pngSize(bytes)
            ?? gifSize(bytes)
            ?? webpSize(bytes)
            ?? jpegSize(bytes)
    }

    /// Strip a `data:<mime>;base64,` prefix, returning its media type when the
    /// block itself did not declare one. Mirrors the server's collector.
    private static func normalizedBase64(
        _ value: String
    ) -> (data: String, mediaType: String?) {
        guard value.hasPrefix("data:"), let comma = value.firstIndex(of: ",")
        else { return (value, nil) }
        let header = String(value[value.startIndex..<comma])
        guard header.lowercased().contains(";base64") else { return (value, nil) }
        let mediaType = header.dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first.map { String($0) }
        return (String(value[value.index(after: comma)...]),
                mediaType?.isEmpty == true ? nil : mediaType)
    }

    /// The first 64 KiB of decoded bytes — enough for every header parser and
    /// bounded regardless of how large the screenshot is.
    private static func headerData(base64: String) -> Data? {
        var prefix = String(base64.prefix(headerBase64Characters))
        while prefix.count % 4 != 0 { prefix.removeLast() }
        guard !prefix.isEmpty else { return nil }
        return Data(base64Encoded: prefix)
    }

    private static func pngSize(_ bytes: [UInt8]) -> CGSize? {
        guard bytes.count >= 24,
              Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
              String(bytes: bytes[12..<16], encoding: .ascii) == "IHDR" else {
            return nil
        }
        return size(bigEndian32(bytes, 16), bigEndian32(bytes, 20))
    }

    private static func gifSize(_ bytes: [UInt8]) -> CGSize? {
        guard bytes.count >= 10 else { return nil }
        let header = String(bytes: bytes[0..<6], encoding: .ascii)
        guard header == "GIF87a" || header == "GIF89a" else { return nil }
        return size(littleEndian16(bytes, 6), littleEndian16(bytes, 8))
    }

    private static func webpSize(_ bytes: [UInt8]) -> CGSize? {
        guard bytes.count >= 30,
              String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" else { return nil }
        let chunk = String(bytes: bytes[12..<16], encoding: .ascii)
        switch chunk {
        case "VP8X":
            return size(
                littleEndian24(bytes, 24) + 1,
                littleEndian24(bytes, 27) + 1)
        case "VP8 ":
            guard Array(bytes[23..<26]) == [0x9D, 0x01, 0x2A] else { return nil }
            return size(
                littleEndian16(bytes, 26) & 0x3FFF,
                littleEndian16(bytes, 28) & 0x3FFF)
        case "VP8L":
            guard bytes[20] == 0x2F else { return nil }
            let bits = UInt32(littleEndian16(bytes, 21))
                | UInt32(bytes[23]) << 16
                | UInt32(bytes[24]) << 24
            return size(
                Int(bits & 0x3FFF) + 1,
                Int((bits >> 14) & 0x3FFF) + 1)
        default:
            return nil
        }
    }

    private static let jpegStartOfFrame: Set<UInt8> = [
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    ]

    private static func jpegSize(_ bytes: [UInt8]) -> CGSize? {
        guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
        var offset = 2
        while offset + 4 <= bytes.count {
            guard bytes[offset] == 0xFF else {
                offset += 1
                continue
            }
            let marker = bytes[offset + 1]
            if marker == 0xFF {
                offset += 1
                continue
            }
            if marker == 0xD8 || marker == 0xD9 || (0xD0...0xD7).contains(marker) {
                offset += 2
                continue
            }
            if marker == 0xDA { return nil }  // start of scan: no frame header after this
            let segmentLength = Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            guard segmentLength >= 2 else { return nil }
            if jpegStartOfFrame.contains(marker) {
                guard offset + 9 <= bytes.count else { return nil }
                let height = Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6])
                let width = Int(bytes[offset + 7]) << 8 | Int(bytes[offset + 8])
                return size(width, height)
            }
            offset += 2 + segmentLength
        }
        return nil
    }

    private static func size(_ width: Int, _ height: Int) -> CGSize? {
        guard width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func bigEndian32(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
    }

    private static func littleEndian16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
    }

    private static func littleEndian24(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset])
            | Int(bytes[offset + 1]) << 8
            | Int(bytes[offset + 2]) << 16
    }
}
