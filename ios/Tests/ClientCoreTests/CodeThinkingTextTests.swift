import Foundation
import Testing
@testable import ClientCore

// The official live thinking row: five tiers read from `0x102a89080`, the
// closed label `思考了 X` built with `Duration.UnitsFormatStyle`
// (`0x102a891bc`), and the `max(1, round(Δ))` closed duration
// (`0x102a88f60-f90`). Thresholds and format parameters are pinned by
// `EVIDENCE/round24/live-thinking-timer.md` §3–§4.

@Suite("Code thinking text")
struct CodeThinkingTextTests {
    @Test(arguments: [
        (0.0, CodeThinkingText.LiveTier.thinking),
        (1.0, .thinking),
        (14.0, .thinking),
        (14.9, .thinking),
        (15.0, .stillThinking),
        (29.0, .stillThinking),
        (29.9, .stillThinking),
        (30.0, .thinkingMore),
        (44.0, .thinkingMore),
        (44.9, .thinkingMore),
        (45.0, .thinkingSomeMore),
        (59.0, .thinkingSomeMore),
        (59.9, .thinkingSomeMore),
        (60.0, .almostDone),
        (63.0, .almostDone),
        (3723.0, .almostDone),
        (-4.0, .thinking),
    ])
    func liveTierBoundaries(elapsed: Double, expected: CodeThinkingText.LiveTier) {
        #expect(CodeThinkingText.liveTier(elapsed: elapsed) == expected)
    }

    @Test(arguments: [
        (0.4, 1),
        (0.0, 1),
        (-0.6, 1),
        (2.5, 3),
        (14.4, 14),
        (14.5, 15),
        (59.5, 60),
        (59.6, 60),
        (3600.0, 3600),
    ])
    func closedSecondsRoundHalfAwayFromZero(interval: Double, expected: Int) {
        #expect(CodeThinkingText.closedSeconds(interval) == expected)
    }

    @Test func closedSecondsRejectsNonFiniteSpans() {
        #expect(CodeThinkingText.closedSeconds(.infinity) == 1)
        #expect(CodeThinkingText.closedSeconds(.nan) == 1)
    }

    /// `allowed {h,m,s}`, `.narrow`, `maximumUnitCount: 2`,
    /// `zeroValueUnits: .hide`, `fractionalPart: .hide`.
    /// ICU's narrow-unit spacing differs between the Linux probe and Apple
    /// platforms, so the assertion compares content with whitespace removed;
    /// unit choice and order stay pinned.
    @Test(arguments: [
        (1, "1s", "1秒"),
        (14, "14s", "14秒"),
        (59, "59s", "59秒"),
        (60, "1m", "1分钟"),
        (63, "1m 3s", "1分钟3秒"),
        (3723, "1h 2m", "1小时2分钟"),
    ])
    func durationTextUsesTwoNarrowUnits(seconds: Int,
                                       english: String,
                                       simplifiedChinese: String) {
        let en = CodeThinkingText.durationText(seconds: seconds,
                                               locale: Locale(identifier: "en_US"))
        let zh = CodeThinkingText.durationText(seconds: seconds,
                                               locale: Locale(identifier: "zh_Hans_CN"))
        #expect(en.replacingOccurrences(of: " ", with: "")
            == english.replacingOccurrences(of: " ", with: ""))
        #expect(zh.replacingOccurrences(of: " ", with: "")
            == simplifiedChinese.replacingOccurrences(of: " ", with: ""))
    }
}
