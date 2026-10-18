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

    @Test("the moonveil preset carries its own measured ratios")
    func moonveilPreset() {
        let scale = ChatTypeSettings.resolve(schemeRaw: "moonveil", bodySizeRaw: nil, customRaw: nil)
        #expect(scale.body == 16.5)
        #expect(abs(scale.lineSpacing - 8.25) < 0.0001)
        #expect(abs((scale.inlineCode ?? 0) - 16.5 * 0.95) < 0.0001)
        #expect(abs((scale.codeBlock ?? 0) - 16.5 * 0.85) < 0.0001)
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
        scale.inlineCode = 17
        scale.codeBlock = nil
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

    @Test("scaling a scheme leaves pinned code sizes proportional")
    func scalingPins() {
        let doubled = ChatTypeScheme.compactScale.scalingBody(to: 26)
        #expect(doubled.body == 26)
        // compact pins neither code size, so both stay unpinned.
        #expect(doubled.inlineCode == nil)
        #expect(doubled.codeBlock == nil)
        #expect(abs(doubled.headings[0] - 36) < 0.0001)
    }
}
