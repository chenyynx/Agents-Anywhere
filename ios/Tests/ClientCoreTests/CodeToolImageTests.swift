import CoreGraphics
import Foundation
import Testing
@testable import ClientCore

// S2: inline tool-result images.
//
// The server keeps a tool result's structured `result` intact and replaces
// only `output` with a summary, so these tests pin the client-side reader:
// what counts as an image block, the header-only dimensions, the byte count
// derived from base64, and the exact summary text shared with the server.

private func pngData(width: Int = 10, height: Int = 20, padding: Int = 0) -> Data {
    var data = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    data.append(contentsOf: [0, 0, 0, 13])
    data.append(contentsOf: Array("IHDR".utf8))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(width).bigEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(height).bigEndian) { Array($0) })
    data.append(contentsOf: [8, 6, 0, 0, 0])
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(Data(repeating: 0, count: padding))
    return data
}

private func jpegData(width: Int = 30, height: Int = 40) -> Data {
    var data = Data([0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08])
    data.append(contentsOf: withUnsafeBytes(of: UInt16(height).bigEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(width).bigEndian) { Array($0) })
    data.append(Data(repeating: 0, count: 12))
    return data
}

private func gifData(width: Int = 12, height: Int = 34) -> Data {
    var data = Data("GIF89a".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt16(width).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(height).littleEndian) { Array($0) })
    data.append(Data(repeating: 0, count: 8))
    return data
}

private func webpData(width: Int = 90, height: Int = 123) -> Data {
    func le24(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF)]
    }
    var data = Data("RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(22).littleEndian) { Array($0) })
    data.append(contentsOf: Array("WEBP".utf8))
    data.append(contentsOf: Array("VP8X".utf8))
    data.append(contentsOf: withUnsafeBytes(of: UInt32(10).littleEndian) { Array($0) })
    data.append(contentsOf: [0, 0, 0, 0])
    data.append(contentsOf: le24(width - 1))
    data.append(contentsOf: le24(height - 1))
    data.append(0)
    return data
}

private func base64(_ data: Data) -> String {
    data.base64EncodedString()
}

private func imageBlock(_ base64: String, mediaType: String = "image/png") -> JSONValue {
    .object([
        "type": .string("image"),
        "source": .object([
            "type": .string("base64"),
            "media_type": .string(mediaType),
            "data": .string(base64),
        ]),
    ])
}

private func textBlock(_ text: String) -> JSONValue {
    .object(["type": .string("text"), "text": .string(text)])
}

private func content(_ result: [JSONValue]) -> JSONValue {
    .object(["result": .array(result)])
}

@Suite("Code tool images")
struct CodeToolImageTests {

    // MARK: Extraction

    @Test func extractsAnInlineImageFromAFlatResult() {
        let data = pngData(width: 10, height: 20)
        let images = CodeToolImages.images(
            in: content([textBlock("before"), imageBlock(base64(data))]),
            itemId: "item-1")

        #expect(images.count == 1)
        #expect(images[0].id == "item-1#1")
        #expect(images[0].mediaType == "image/png")
        #expect(images[0].byteCount == data.count)
        #expect(images[0].pixelSize == CGSize(width: 10, height: 20))
    }

    @Test func extractsFromTheToolResultWrapper() {
        let data = pngData()
        let result = JSONValue.object([
            "type": .string("tool_result"),
            "content": .array([imageBlock(base64(data))]),
        ])
        let images = CodeToolImages.images(
            in: .object(["result": result]),
            itemId: "item-1")

        #expect(images.count == 1)
        #expect(images[0].pixelSize == CGSize(width: 10, height: 20))
    }

    @Test func ignoresTextAndOtherBlocks() {
        let images = CodeToolImages.images(
            in: content([textBlock("plain output"), .object(["type": .string("text")])]),
            itemId: "item-1")

        #expect(images.isEmpty)
    }

    @Test func missingResultIsEmpty() {
        #expect(CodeToolImages.images(in: .object(["output": .string("text")]),
                                      itemId: "item-1").isEmpty)
        #expect(CodeToolImages.images(in: .object([:]), itemId: "item-1").isEmpty)
    }

    @Test func multipleImagesKeepWireOrder() {
        let images = CodeToolImages.images(
            in: content([
                imageBlock(base64(pngData())),
                imageBlock(base64(jpegData()), mediaType: "image/jpeg"),
            ]),
            itemId: "item-1")

        #expect(images.count == 2)
        #expect(images[0].mediaType == "image/png")
        #expect(images[1].mediaType == "image/jpeg")
        #expect(images[1].pixelSize == CGSize(width: 30, height: 40))
    }

    @Test func acceptsADataURLAndTakesItsMediaType() {
        let dataURL = "data:image/jpeg;base64," + base64(jpegData(width: 30, height: 40))
        let block = JSONValue.object([
            "type": .string("image"),
            "source": .object([
                "type": .string("base64"),
                "data": .string(dataURL),
            ]),
        ])

        let images = CodeToolImages.images(
            in: content([block]),
            itemId: "item-1")

        #expect(images.count == 1)
        #expect(images[0].mediaType == "image/jpeg")
        #expect(images[0].pixelSize == CGSize(width: 30, height: 40))
        #expect(CodeToolImages.summary(for: images).hasPrefix("[Image] JPEG · 30×40 · "))
    }

    @Test func malformedBase64KeepsTheBlockWithoutSize() {
        let images = CodeToolImages.images(
            in: content([imageBlock("!!!!")]),
            itemId: "item-1")

        #expect(images.count == 1)
        #expect(images[0].byteCount == nil)
        #expect(images[0].pixelSize == nil)
    }

    @Test func blockWalkIsBounded() {
        let blocks = (0..<150).map { _ in imageBlock(base64(pngData())) }
        let images = CodeToolImages.images(in: content(blocks), itemId: "item-1")

        #expect(images.count == 100)
    }

    // MARK: Dimensions

    @Test func readsDimensionsForEachSupportedHeader() {
        #expect(CodeToolImages.pixelSize(in: pngData(width: 1170, height: 4100))
            == CGSize(width: 1170, height: 4100))
        #expect(CodeToolImages.pixelSize(in: jpegData(width: 56, height: 78))
            == CGSize(width: 56, height: 78))
        #expect(CodeToolImages.pixelSize(in: gifData(width: 12, height: 34))
            == CGSize(width: 12, height: 34))
        #expect(CodeToolImages.pixelSize(in: webpData(width: 90, height: 123))
            == CGSize(width: 90, height: 123))
        #expect(CodeToolImages.pixelSize(in: Data("not an image".utf8)) == nil)
        #expect(CodeToolImages.pixelSize(in: Data()) == nil)
    }

    @Test func dimensionsComeFromTheBase64HeaderOnly() {
        let data = pngData(width: 1170, height: 4100, padding: 1_000_000)
        #expect(CodeToolImages.pixelSize(base64: base64(data))
            == CGSize(width: 1170, height: 4100))
    }

    // MARK: Byte count

    @Test func byteCountIsDerivedFromBase64Length() {
        let data = pngData(padding: 999)
        #expect(CodeToolImages.decodedByteCount(base64: base64(data)) == data.count)
        #expect(CodeToolImages.decodedByteCount(base64: "abc") == nil)
        #expect(CodeToolImages.decodedByteCount(base64: "!!!!") == nil)
    }

    // MARK: Summary

    @Test func summaryMatchesTheServerFormat() {
        let data = pngData(width: 1170, height: 4100)
        let images = CodeToolImages.images(
            in: content([imageBlock(base64(data))]),
            itemId: "item-1")

        #expect(CodeToolImages.summary(for: images)
            == "[Image] PNG · 1170×4100 · \(data.count) B")
    }

    @Test func summaryNumbersMultipleImagesOnSeparateLines() {
        let png = pngData(width: 10, height: 20)
        let jpeg = jpegData(width: 30, height: 40)
        let images = CodeToolImages.images(
            in: content([
                imageBlock(base64(png)),
                imageBlock(base64(jpeg), mediaType: "image/jpeg"),
            ]),
            itemId: "item-1")

        #expect(CodeToolImages.summary(for: images)
            == "[Image 1] PNG · 10×20 · \(png.count) B\n"
                + "[Image 2] JPEG · 30×40 · \(jpeg.count) B")
    }

    @Test func summaryOmitsSegmentsThePayloadDoesNotCarry() {
        let images = CodeToolImages.images(
            in: content([imageBlock("aGVsbG8gd29ybGQ=")]),
            itemId: "item-1")

        #expect(CodeToolImages.summary(for: images) == "[Image] PNG · 11 B")
    }

    @Test func summaryUppercasesAnUnknownSubtype() {
        let images = CodeToolImages.images(
            in: content([imageBlock("aGVsbG8gd29ybGQ=", mediaType: "image/x-weird")]),
            itemId: "item-1")

        #expect(CodeToolImages.summary(for: images) == "[Image] X-WEIRD · 11 B")
    }

    @Test func serverSummaryEqualityIgnoresSurroundingWhitespace() {
        let images = CodeToolImages.images(
            in: content([imageBlock(base64(pngData()))]),
            itemId: "item-1")
        let summary = CodeToolImages.summary(for: images)

        #expect(CodeToolImages.isServerImageSummary("\n\(summary)\n", images: images))
        #expect(!CodeToolImages.isServerImageSummary(summary + " ", images: []))
        #expect(!CodeToolImages.isServerImageSummary("[Image] PNG", images: images))
    }

    @Test func detectsAPreS1SerializedImageResult() {
        let serialized = #"[{"type":"image","source":{"type":"base64","data":"abc"}}]"#
        let spaced = #"[{"type": "image", "source": {"type": "base64", "data": "abc"}}]"#

        #expect(CodeToolImages.isSerializedImagePayload(serialized))
        #expect(CodeToolImages.isSerializedImagePayload(spaced))
        #expect(!CodeToolImages.isSerializedImagePayload("[Image] PNG · 10×20 · 33 B"))
        #expect(!CodeToolImages.isSerializedImagePayload("base64 without an image type"))
    }

    @Test func byteFormattingKeepsOneDecimalAtMost() {
        #expect(CodeToolImages.formatBytes(11) == "11 B")
        #expect(CodeToolImages.formatBytes(1024) == "1 KB")
        #expect(CodeToolImages.formatBytes(1536) == "1.5 KB")
        #expect(CodeToolImages.formatBytes(1024 * 1024) == "1 MB")
    }

    // MARK: Item-level read

    @Test func readsImagesFromATimelineItem() throws {
        let item: V2TimelineItem = try decodeItem([
            "id": "item-1",
            "sessionId": "session",
            "type": "tool",
            "status": "done",
            "content": [
                "output": CodeToolImages.summary(for: []),
                "result": [[
                    "type": "image",
                    "source": [
                        "type": "base64",
                        "media_type": "image/png",
                        "data": base64(pngData()),
                    ],
                ]],
            ],
            "source": ["itemId": "item-1"],
            "orderSeq": 1,
            "revision": 1,
            "updatedSeq": 1,
            "contentHash": "sha256:item-1",
        ])

        let images = CodeToolImages.images(in: item)
        #expect(images.count == 1)
        #expect(images[0].id == "item-1#0")
    }
}

private func decodeItem(_ object: [String: Any]) throws -> V2TimelineItem {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(V2TimelineItem.self, from: data)
}
