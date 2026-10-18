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

    @Test("inline code ships regular, and the bold switch is opt-in")
    func inlineCodeBoldDefaultsOff() throws {
        let defaults = try #require(UserDefaults(suiteName: #function))
        defaults.removePersistentDomain(forName: #function)
        #expect(!ChatColorSettings.inlineCodeBold(in: defaults))
        defaults.set(true, forKey: ChatColorSettings.inlineCodeBoldKey)
        #expect(ChatColorSettings.inlineCodeBold(in: defaults))
        defaults.removePersistentDomain(forName: #function)
    }

    @Test("the shipped inline-code grey is readable on both appearances")
    func shippedGreyContrast() throws {
        // 4.8:1 on the dark chat background, 3.6:1 on white. Pinned so a later
        // "nicer grey" cannot quietly drop the dark appearance below the
        // 3:1 that incidental text needs.
        let dark = try #require(ChatColorSettings.parse(ChatColorSettings.defaultBodyTemplate.dark))
        let light = try #require(ChatColorSettings.parse(ChatColorSettings.defaultBodyTemplate.light))
        #expect(contrast(light, on: (0xFF, 0xFF, 0xFF)) > 3.0)
        #expect(contrast(dark, on: (0x1C, 0x1C, 0x1E)) > 4.5)
    }

    /// WCAG relative-luminance contrast ratio for two sRGB triples.
    private func contrast(_ a: (UInt32, UInt32, UInt32), on b: (UInt32, UInt32, UInt32)) -> Double {
        func luminance(_ c: (UInt32, UInt32, UInt32)) -> Double {
            func channel(_ v: UInt32) -> Double {
                let s = Double(v) / 255
                return s <= 0.03928 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel(c.0) + 0.7152 * channel(c.1) + 0.0722 * channel(c.2)
        }
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
