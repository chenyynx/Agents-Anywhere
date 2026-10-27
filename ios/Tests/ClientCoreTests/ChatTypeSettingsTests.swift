import Foundation
import Testing
@testable import ClientCore

@Suite("Chat type schemes")
struct ChatTypeSettingsTests {
    @Test("an untouched install resolves to the AA preset")
    func defaultIsCompact() {
        let scale = ChatTypeSettings.resolve(schemeRaw: nil, bodySizeRaw: nil, customRaw: nil)
        #expect(scale == ChatTypeScheme.compactScale)
        #expect(scale.body == 13)
        #expect(scale.paragraphSpacing == 20)
    }

    @Test("the AA preset keeps fenced code at the size that ships")
    func compactCodeSizeIsUnchanged() {
        let scale = ChatTypeSettings.resolve(schemeRaw: nil, bodySizeRaw: nil, customRaw: nil)
        // Pinned, not derived: deriving 12.3 against a 13pt body would have
        // shrunk it to 11.42 the moment the body dropped below the 14pt
        // reference.
        #expect(abs(scale.codeBlockSize - 12.3) < 0.0001)
        #expect(abs(scale.inlineCodeSize - 13) < 0.0001)
        // 43px baseline pitch minus the 12.3pt glyphs, held as a share of the
        // code size so a pinned size keeps its proportions.
        #expect(abs(scale.codeBlockSize * scale.codeBlockLineSpacingRatio - 2.03) < 0.0001)
    }

    @Test("the moonveil preset carries its own measured ratios")
    func moonveilPreset() {
        let scale = ChatTypeSettings.resolve(schemeRaw: "moonveil", bodySizeRaw: nil, customRaw: nil)
        #expect(scale.body == 16.5)
        #expect(abs(scale.lineSpacing - 8.25) < 0.0001)
        #expect(abs(scale.inlineCodeSize - 16.5 * 0.95) < 0.0001)
        #expect(abs(scale.codeBlockSize - 16.5 * 0.85) < 0.0001)
        #expect(scale.paragraphSpacing == 12)
        #expect(scale.headings.count == 3)
    }

    @Test("a body override re-proportions the preset but keeps its gap")
    func bodyOverrideKeepsShape() {
        let scale = ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: 20, customRaw: nil)
        #expect(scale.body == 20)
        // Leading is a ratio of the body, so it grows with it.
        #expect(abs(scale.lineSpacing - 8 * 20 / 13) < 0.0001)
        // The paragraph gap is a fixed design constant and must not drift.
        #expect(scale.paragraphSpacing == 20)
    }

    @Test("growing the body leaves a pinned code size alone")
    func pinsDoNotFollowTheBody() {
        let small = ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: 13, customRaw: nil)
        let large = ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: 20, customRaw: nil)
        #expect(abs(small.codeBlockSize - large.codeBlockSize) < 0.0001)
        // The unpinned one does follow.
        #expect(abs(large.inlineCodeSize - 20) < 0.0001)
    }

    @Test("an out-of-range body override is clamped, not rejected")
    func clamping() {
        #expect(ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: 99, customRaw: nil).body
                == ChatTypeSettings.bodySizeRange.upperBound)
        #expect(ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: 1, customRaw: nil).body
                == ChatTypeSettings.bodySizeRange.lowerBound)
        #expect(ChatTypeSettings.resolve(schemeRaw: "compact", bodySizeRaw: .nan, customRaw: nil).body == 13)
    }

    @Test("an unknown scheme falls back to the AA preset")
    func unknownScheme() {
        #expect(ChatTypeSettings.resolve(schemeRaw: "nonsense", bodySizeRaw: nil, customRaw: nil)
                == ChatTypeScheme.compactScale)
    }

    @Test("a custom scale round-trips through storage")
    func customRoundTrip() throws {
        var scale = ChatTypeScheme.compactScale
        scale.inlineCodePin = 17
        scale.codeBlockPin = nil
        let raw = ChatTypeSettings.encodeCustom(scale)
        let decoded = try #require(ChatTypeSettings.decodeCustom(raw))
        #expect(decoded == scale)
        #expect(ChatTypeSettings.resolve(schemeRaw: "custom", bodySizeRaw: nil, customRaw: raw) == scale)
    }

    @Test("a malformed custom snapshot falls back to the AA preset")
    func malformedCustom() {
        #expect(ChatTypeSettings.decodeCustom("") == nil)
        #expect(ChatTypeSettings.decodeCustom("{}") == nil)
        #expect(ChatTypeSettings.resolve(schemeRaw: "custom", bodySizeRaw: nil, customRaw: "junk")
                == ChatTypeScheme.compactScale)
    }

    @Test("a snapshot from before the ratio split still loads")
    func legacyCustomSnapshot() throws {
        // The previous build stored `inlineCode`/`codeBlock` as absolute sizes
        // and no ratios. Those keys are ignored; the scale must resolve rather
        // than collapse to the default.
        let legacy = """
        {"body":15,"lineSpacing":9,"inlineCode":14,"codeBlock":11,
         "paragraphSpacing":18,"headings":[19,17,15]}
        """
        let scale = try #require(ChatTypeSettings.decodeCustom(legacy))
        #expect(scale.body == 15)
        // No pins: old snapshots keep the frozen legacy inline-code ratio, so
        // changing the compact default does not resize an existing custom
        // scale.
        #expect(scale.inlineCodePin == nil)
        #expect(abs(scale.inlineCodeSize - 15 * 14.8 / 14) < 0.0001)
    }

    @Test("scaling a scheme leaves pinned code sizes proportional")
    func scalingPins() {
        let doubled = ChatTypeScheme.compactScale.scalingBody(to: 26)
        #expect(doubled.body == 26)
        #expect(doubled.inlineCodePin == nil)
        #expect(doubled.codeBlockPin == ChatTypeScheme.compactScale.codeBlockPin)
        #expect(abs(doubled.headings[0] - 36) < 0.0001)
    }
}
