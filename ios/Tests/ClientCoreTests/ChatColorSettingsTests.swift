import Foundation
import Testing
@testable import ClientCore

@Suite("Chat colour settings")
struct ChatColorSettingsTests {
    @Test("a stored pair round-trips")
    func roundTrip() {
        let pair = ChatColorSettings.Pair(light: "#FF6A00", dark: "#6FA8D6")
        #expect(ChatColorSettings.decode(ChatColorSettings.encode(pair), fallback: ChatColorSettings.defaultLink) == pair)
    }

    @Test("a malformed value falls back instead of rendering nothing")
    func malformedFallback() {
        #expect(ChatColorSettings.decode("", fallback: ChatColorSettings.defaultLink) == ChatColorSettings.defaultLink)
        #expect(ChatColorSettings.decode("nonsense", fallback: ChatColorSettings.defaultBodyTemplate) == ChatColorSettings.defaultBodyTemplate)
        #expect(ChatColorSettings.decode("#GGGGGG|#FFFFFF", fallback: ChatColorSettings.defaultLink) == ChatColorSettings.defaultLink)
        #expect(ChatColorSettings.decode("#FFFFFF", fallback: ChatColorSettings.defaultLink) == ChatColorSettings.defaultLink)
    }

    @Test("hex parsing accepts with and without the leading hash")
    func hexParsing() throws {
        let withHash = try #require(ChatColorSettings.parse("#FF6A00"))
        let withoutHash = try #require(ChatColorSettings.parse("ff6a00"))
        #expect(withHash == withoutHash)
        #expect(withHash == (0xFF, 0x6A, 0x00))
        #expect(ChatColorSettings.parse("#FFF") == nil)
        #expect(ChatColorSettings.parse("#GGGGGG") == nil)
    }

    @Test("normalising produces an uppercase hash form")
    func normalising() {
        #expect(ChatColorSettings.normalized("ff6a00") == "#FF6A00")
        #expect(ChatColorSettings.normalized("#ff6a00") == "#FF6A00")
        #expect(ChatColorSettings.normalized("nope") == nil)
    }

    @Test("both shipped defaults are symmetric so light and dark agree")
    func shippedDefaults() {
        #expect(ChatColorSettings.defaultBodyTemplate.isSymmetric)
        #expect(!ChatColorSettings.defaultLink.isSymmetric)
    }
}
