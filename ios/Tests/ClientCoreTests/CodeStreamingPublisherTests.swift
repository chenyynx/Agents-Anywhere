import Foundation
import Testing
@testable import ClientCore

// W6: pure-logic tests for the Code profile's chunked streaming publisher.
// No UI, no timers: the clock is injected, so every gate (chunk size, chunk
// wait, 0.1 s leading-edge throttle, catch-up, completion) is deterministic
// here.
//
// The chunk parameters under test are the official video observation
// (CANONICAL/03-streaming.md §9.2): 4–8 English words, 50–100 ms apart, with a
// character fallback for text that has no word boundaries. Time boundaries use
// `timingEpsilon` instead of exact floating-point equality (Q-4).

private let timingEpsilon: TimeInterval = 1e-9
private let eightWords = "one two three four five six seven eight "
private let burst = (1...20).map { "w\($0)" }.joined(separator: " ") + " "
private let firstEightOfBurst = (1...8).map { "w\($0)" }.joined(separator: " ") + " "
private let firstSixteenOfBurst = (1...16).map { "w\($0)" }.joined(separator: " ") + " "
private let fortyWordBacklog = (1...40).map { "b\($0)" }.joined(separator: " ") + " "

@Suite("Code streaming publisher")
struct CodeStreamingPublisherTests {
    private func makePublisher(_ config: CodeStreamingPublisher.Config = .init()) -> CodeStreamingPublisher {
        CodeStreamingPublisher(config: config)
    }

    /// A first snapshot is published whole, so later chunk assertions seed the
    /// publisher with a small first event and then measure the second one.
    private func seededPublisher() -> CodeStreamingPublisher {
        var publisher = makePublisher()
        _ = publisher.receive(delta: "seed ", at: 0)
        return publisher
    }

    // MARK: Leading-edge throttle and catch-up

    @Test func leadingEdgePublishesAReadyChunkImmediately() {
        var publisher = makePublisher()
        let snapshot = publisher.receive(delta: eightWords, at: 0)

        #expect(snapshot?.text == eightWords)
        #expect(snapshot?.id == CodeStreamingSnapshot.streamingRowID)
        #expect(snapshot?.isComplete == false)
        #expect(publisher.publishedText == eightWords)
        #expect(!publisher.hasPendingText)
        #expect(!publisher.publishPending)
    }

    @Test func theFirstSnapshotPublishesTheWholeBacklog() {
        var publisher = makePublisher()
        let snapshot = publisher.receive(delta: fortyWordBacklog, at: 0)

        // Opening a session mid-stream must not replay 40 words at 8/0.1 s.
        #expect(snapshot?.text == fortyWordBacklog)
        #expect(!publisher.hasPendingText)
    }

    @Test func anOversizedBacklogAfterTheFirstSnapshotIsPublishedWhole() {
        var publisher = seededPublisher()
        let snapshot = publisher.receive(delta: fortyWordBacklog, at: 0.1)

        #expect(snapshot?.text == "seed " + fortyWordBacklog)
        #expect(!publisher.hasPendingText)
    }

    @Test func aPublishInsideTheThrottleWindowOnlyMarksPending() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 0)

        let blocked = publisher.receive(delta: eightWords, at: 0.05)
        #expect(blocked == nil)
        #expect(publisher.publishPending)
        #expect(publisher.publishedText == eightWords)
        #expect(publisher.receivedText == eightWords + eightWords)

        let flushed = publisher.flush(at: 0.1 + timingEpsilon)
        #expect(flushed?.text == eightWords + eightWords)
        #expect(!publisher.publishPending)
    }

    @Test func aThrottledChunkIsFlushedOnTheFirstEventAfterTheWindow() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 0)

        let blocked = publisher.receive(
            delta: "nine ten eleven twelve thirteen fourteen fifteen sixteen ", at: 0.05)
        #expect(blocked == nil)
        #expect(publisher.publishPending)

        #expect(publisher.flush(at: 0.1 - timingEpsilon) == nil)
        #expect(publisher.publishPending)

        let flushed = publisher.flush(at: 0.1 + timingEpsilon)
        #expect(flushed?.text == eightWords
            + "nine ten eleven twelve thirteen fourteen fifteen sixteen ")
        #expect(!publisher.publishPending)
        #expect(publisher.flush(at: 0.1 + timingEpsilon) == nil)
    }

    @Test func completionIsExemptFromTheThrottle() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 0)

        let done = publisher.complete(at: 0.01)
        #expect(done?.text == eightWords)
        #expect(done?.isComplete == true)
    }

    // MARK: Chunk size and wait

    @Test func aBurstIsSplitIntoChunksOfAtMostEightWords() {
        var publisher = seededPublisher()

        let first = publisher.receive(delta: burst, at: 0.1)
        #expect(first?.text == "seed " + firstEightOfBurst)
        #expect(publisher.receivedText == "seed " + burst)

        let second = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(second?.text == "seed " + firstSixteenOfBurst)

        let third = publisher.flush(at: 0.3 + timingEpsilon)
        #expect(third?.text == "seed " + burst)
        #expect(!publisher.hasPendingText)
    }

    @Test func aShortChunkWaitsForTheMaximumWait() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "one two three ", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.15 - timingEpsilon) == nil)
        #expect(publisher.flush(at: 0.2 - timingEpsilon) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed one two three ")
    }

    @Test func fourWordsMayBeReleasedAtTheMinimumWait() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "one two three four ", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.15 - timingEpsilon) == nil)
        let snapshot = publisher.flush(at: 0.15 + timingEpsilon)
        #expect(snapshot?.text == "seed one two three four ")
    }

    @Test func consecutiveDeltasMergeIntoOneChunk() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "one ", at: 0.1) == nil)
        #expect(publisher.receive(delta: "two ", at: 0.11) == nil)
        #expect(publisher.receive(delta: "three ", at: 0.12) == nil)
        #expect(publisher.receive(delta: "four ", at: 0.13) == nil)

        let snapshot = publisher.flush(at: 0.15 + timingEpsilon)
        #expect(snapshot?.text == "seed one two three four ")
        #expect(publisher.receivedText == "seed one two three four ")
    }

    @Test func anASCIIWordInProgressIsNotSplit() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "stream", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.15) == nil)
        #expect(publisher.receive(delta: "ing ", at: 0.16) == nil)

        // Released at maximumWait, but as one whole word.
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed streaming ")
    }

    @Test func aLongASCIIIdentifierIsPublishedWholeAtTheMaximumWait() {
        var publisher = seededPublisher()
        let identifier = String(repeating: "a", count: 40)

        #expect(publisher.receive(delta: identifier, at: 0.1) == nil)
        #expect(publisher.flush(at: 0.2 - timingEpsilon) == nil)

        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        // Never cut into 16-character pieces; the whole word goes out.
        #expect(snapshot?.text == "seed " + identifier)
    }

    @Test func textWithoutWordBoundariesFallsBackToCharacters() {
        var publisher = seededPublisher()
        let text = String(repeating: "你", count: 20)

        // charactersPerWord = 2: max 8 words = 16 characters.
        let first = publisher.receive(delta: text, at: 0.1)
        #expect(first?.text == "seed " + String(repeating: "你", count: 16))

        let rest = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(rest?.text == "seed " + text)
    }

    @Test func aShortCJKChunkIsHeldUntilTheMaximumWait() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "你好世界", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.15 - timingEpsilon) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed 你好世界")
    }

    @Test func aSingleCJKCharacterIsHeldUntilTheMaximumWait() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "你", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.2 - timingEpsilon) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed 你")
    }

    @Test func aSingleASCIIWordIsPublishedWholeAtTheMaximumWait() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "a", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.2 - timingEpsilon) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed a")
    }

    // MARK: Leading whitespace must not stall (P1)

    @Test func leadingNewlinesBeforeCJKDoNotStall() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "\n\n你好", at: 0.1) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed " + "\n\n你好")
    }

    @Test func leadingSpacesBeforeCJKDoNotStall() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "  " + "你好世界", at: 0.1) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed " + "  " + "你好世界")
    }

    @Test func punctuationAfterALeadingNewlineDoesNotStall() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "\n---", at: 0.1) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed \n---")
    }

    @Test func aLeadingNewlineBeforeAnASCIIWordStillHolds() {
        var publisher = seededPublisher()

        #expect(publisher.receive(delta: "\nstream", at: 0.1) == nil)
        #expect(publisher.flush(at: 0.2 - timingEpsilon) == nil)

        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed \nstream")
    }

    // MARK: Injected parameters and overflow safety

    @Test func injectedParametersDriveEveryGate() {
        var config = CodeStreamingPublisher.Config()
        config.publishInterval = 0.5
        config.chunk.minimumWords = 2
        config.chunk.maximumWords = 3
        config.chunk.minimumWait = 0.01
        config.chunk.maximumWait = 0.02
        config.chunk.charactersPerWord = 3
        config.catchUpWordThreshold = 100
        var publisher = CodeStreamingPublisher(config: config)

        _ = publisher.receive(delta: "seed ", at: 0) // first snapshot, whole

        // minimumWords = 2: two words are enough at minimumWait = 0.01.
        #expect(publisher.receive(delta: "one two ", at: 0.5) == nil)
        let early = publisher.flush(at: 0.52)
        #expect(early?.text == "seed one two ")

        // maximumWords = 3 caps a four-word chunk.
        #expect(publisher.receive(delta: "a b c d ", at: 0.53) == nil)
        #expect(publisher.publishPending)
        let capped = publisher.flush(at: 1.03)
        #expect(capped?.text == "seed one two a b c ")

        // The fourth word stays buffered; flush it before the CJK probe so the
        // two scripts are measured separately.
        let leftover = publisher.flush(at: 1.54)
        #expect(leftover?.text == "seed one two a b c d ")

        // charactersPerWord = 3: at most 3 * 3 = 9 CJK characters per chunk.
        let cjk = String(repeating: "你", count: 10)
        #expect(publisher.receive(delta: cjk, at: 1.55) == nil)
        let characters = publisher.flush(at: 2.06)
        #expect(characters?.text == "seed one two a b c d "
            + String(repeating: "你", count: 9))
    }

    @Test func catchUpThresholdIsInjectable() {
        var config = CodeStreamingPublisher.Config()
        config.catchUpWordThreshold = 5
        var publisher = CodeStreamingPublisher(config: config)

        _ = publisher.receive(delta: "seed ", at: 0)
        let sixWords = "a b c d e f "
        let snapshot = publisher.receive(delta: sixWords, at: 0.1)

        // Six word-units reach the injected threshold of five, so the whole
        // buffer goes out instead of waiting for a four-word chunk.
        #expect(snapshot?.text == "seed " + sixWords)
    }

    @Test func extremeChunkParametersDoNotOverflow() {
        var config = CodeStreamingPublisher.Config()
        config.chunk.minimumWords = .max
        config.chunk.maximumWords = .max
        config.chunk.charactersPerWord = .max
        config.catchUpWordThreshold = .max
        var publisher = CodeStreamingPublisher(config: config)

        _ = publisher.receive(delta: "seed ", at: 0)
        #expect(publisher.publishedText == "seed ")

        let cjk = String(repeating: "你", count: 20)
        #expect(publisher.receive(delta: cjk, at: 0.1) == nil)
        let snapshot = publisher.flush(at: 0.2 + timingEpsilon)
        #expect(snapshot?.text == "seed " + cjk)
    }

    // MARK: Completion and identity

    @Test func completionFlushesTheRestAndStopsAggregation() {
        var publisher = seededPublisher()
        #expect(publisher.receive(delta: "one two ", at: 0.1) == nil)

        let done = publisher.complete(at: 0.12)
        #expect(done?.text == "seed one two ")
        #expect(done?.isComplete == true)
        #expect(done?.id == CodeStreamingSnapshot.streamingRowID)

        #expect(publisher.receive(delta: "three ", at: 0.13) == nil)
        #expect(publisher.receive(fullText: "seed one two three ", at: 0.14) == nil)
        #expect(publisher.complete(at: 0.15) == nil)
        #expect(publisher.receivedText == "seed one two ")
    }

    @Test func theStreamingRowIdentityNeverChangesOnCompletion() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 0)
        let done = publisher.complete(at: 0.01)

        #expect(done?.id == "streamingText")
        #expect(publisher.publishedText == eightWords)
    }

    @Test func emptyInputDoesNotCreateAChunk() {
        var publisher = makePublisher()

        #expect(publisher.receive(delta: "", at: 0) == nil)
        #expect(publisher.receive(fullText: "", at: 0.01) == nil)
        #expect(publisher.flush(at: 1) == nil)
        #expect(publisher.receivedText.isEmpty)
        #expect(!publisher.hasPendingText)
    }

    @Test func emptyCompletionStillReportsTheCompletionState() {
        var publisher = makePublisher()
        let snapshot = publisher.complete(at: 0)

        #expect(snapshot?.text == "")
        #expect(snapshot?.isComplete == true)
    }

    // MARK: Full text and corrections

    @Test func cumulativeFullTextTakesOnlyTheNewSuffix() {
        var publisher = makePublisher()

        let first = publisher.receive(fullText: eightWords, at: 0)
        #expect(first?.text == eightWords)

        let second = publisher.receive(fullText: eightWords + "nine ten eleven twelve "
                                        + "thirteen fourteen fifteen sixteen ", at: 0.1)
        #expect(second?.text == eightWords + "nine ten eleven twelve "
            + "thirteen fourteen fifteen sixteen ")
    }

    @Test func aShorterFullTextReplacesTheVisibleSnapshot() {
        var publisher = makePublisher()
        _ = publisher.receive(fullText: eightWords, at: 0)

        let corrected = publisher.receive(fullText: "one two ", at: 0.1)
        #expect(corrected?.text == "one two ")
        #expect(publisher.receivedText == "one two ")
    }

    @Test func aCorrectionRespectsThePublishThrottle() {
        var publisher = makePublisher()
        _ = publisher.receive(fullText: eightWords, at: 0)

        #expect(publisher.receive(fullText: "one two ", at: 0.05) == nil)
        #expect(publisher.publishPending)

        let corrected = publisher.flush(at: 0.1 + timingEpsilon)
        #expect(corrected?.text == "one two ")
    }

    // MARK: Clock edge cases

    @Test func aClockRollbackCannotPublishFasterThanTheWindow() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 1.0)

        let blocked = publisher.receive(delta: eightWords, at: 0.5)
        #expect(blocked == nil)
        #expect(publisher.publishPending)
        #expect(publisher.flush(at: 0.5) == nil)

        let resumed = publisher.flush(at: 1.1 + timingEpsilon)
        #expect(resumed?.text == eightWords + eightWords)
    }

    @Test func repeatedCallsAtTheSameInstantAreIdempotent() {
        var publisher = makePublisher()
        let first = publisher.receive(delta: eightWords, at: 0)
        #expect(first != nil)

        #expect(publisher.flush(at: 0) == nil)
        #expect(publisher.receive(fullText: eightWords, at: 0) == nil)
        #expect(publisher.flush(at: 0) == nil)
        #expect(publisher.receivedText == eightWords)
    }
}
