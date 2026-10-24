import Foundation
import Testing
@testable import ClientCore

// W6: pure-logic tests for the Code profile's streaming publisher.
// No UI, no timers: the clock is injected, so every gate (0.1 s leading-edge
// throttle, whole-snapshot publishing, correction, completion) is deterministic
// here.
//
// The official publisher has exactly one pacing layer: a 0.1 s leading-edge
// throttle that publishes the whole current text of the block
// (CANONICAL/03-streaming.md §5.1, §4.2–4.3). The 4–8 word / 50–100 ms cadence
// of the 60 fps demo video is an observation of network delta grouping
// (§9.2), not a client-side chunk policy, so there is no word/character
// scanner left to test. Time boundaries use `timingEpsilon` instead of exact
// floating-point equality (Q-4).

private let timingEpsilon: TimeInterval = 1e-9
private let eightWords = "one two three four five six seven eight "
private let burst = (1...20).map { "w\($0)" }.joined(separator: " ") + " "
private let fortyWordBacklog = (1...40).map { "b\($0)" }.joined(separator: " ") + " "

@Suite("Code streaming publisher")
struct CodeStreamingPublisherTests {
    private func makePublisher(_ config: CodeStreamingPublisher.Config = .init()) -> CodeStreamingPublisher {
        CodeStreamingPublisher(config: config)
    }

    /// A first snapshot is published whole, so later throttle assertions seed
    /// the publisher with a small first event at t = 0.
    private func seededPublisher() -> CodeStreamingPublisher {
        var publisher = makePublisher()
        _ = publisher.receive(delta: "seed ", at: 0)
        return publisher
    }

    // MARK: Leading-edge throttle and whole snapshots

    @Test func leadingEdgePublishesTheWholeFirstSnapshotImmediately() {
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

        // Opening a session mid-stream must show the accumulated text at once.
        #expect(snapshot?.text == fortyWordBacklog)
        #expect(!publisher.hasPendingText)
    }

    @Test func aBurstAfterTheFirstSnapshotIsPublishedWhole() {
        var publisher = seededPublisher()
        let snapshot = publisher.receive(delta: burst, at: 0.1)

        // No 4–8 word split: the snapshot is the entire current text.
        #expect(snapshot?.text == "seed " + burst)
        #expect(!publisher.hasPendingText)
        #expect(publisher.publishedText == "seed " + burst)
    }

    @Test func aPublishInsideTheThrottleWindowOnlyMarksPending() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 0)

        let blocked = publisher.receive(delta: burst, at: 0.05)
        #expect(blocked == nil)
        #expect(publisher.publishPending)
        #expect(publisher.publishedText == eightWords)
        #expect(publisher.receivedText == eightWords + burst)

        let flushed = publisher.flush(at: 0.1 + timingEpsilon)
        // The first event after the window publishes the whole text, including
        // the text that arrived inside the window.
        #expect(flushed?.text == eightWords + burst)
        #expect(!publisher.publishPending)
        #expect(!publisher.hasPendingText)
    }

    @Test func aThrottledPublishIsFlushedOnTheFirstEventAfterTheWindow() {
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

    @Test func completionPublishesTextBufferedInsideTheWindow() {
        var publisher = seededPublisher()
        _ = publisher.receive(delta: "tail ", at: 0.05)
        #expect(publisher.publishPending)

        let done = publisher.complete(at: 0.06)
        #expect(done?.text == "seed tail ")
        #expect(done?.isComplete == true)
    }

    // MARK: Snapshot content

    @Test func unspacedTextIsNeverSplit() {
        var publisher = seededPublisher()
        let text = String(repeating: "你", count: 20)

        // There is no character-count fallback: the whole run goes out on the
        // first event that opens the window.
        let snapshot = publisher.receive(delta: text, at: 0.1)
        #expect(snapshot?.text == "seed " + text)
        #expect(publisher.flush(at: 0.2 + timingEpsilon) == nil)
    }

    @Test func aLongASCIIIdentifierIsPublishedWhole() {
        var publisher = seededPublisher()
        let identifier = String(repeating: "a", count: 40)

        let snapshot = publisher.receive(delta: identifier, at: 0.1)
        #expect(snapshot?.text == "seed " + identifier)
    }

    @Test func noSnapshotIsPublishedWithoutNewTextAndAnOpenWindow() {
        var publisher = seededPublisher()

        #expect(publisher.flush(at: 0.2) == nil)
        #expect(publisher.receive(fullText: "seed ", at: 0.3) == nil)
        #expect(publisher.publishedText == "seed ")
    }

    @Test func publishRevisionAdvancesOnlyWhenASnapshotIsProduced() {
        var publisher = makePublisher()
        let first = publisher.receive(delta: "seed ", at: 0)
        #expect(first != nil)
        #expect(publisher.publishRevision == 1)

        // Throttled below the window: nothing reached the row.
        #expect(publisher.receive(delta: "one ", at: 0.05) == nil)
        #expect(publisher.publishRevision == 1)

        // The flush publishes the buffered text: one more snapshot.
        _ = publisher.flush(at: 0.1 + timingEpsilon)
        #expect(publisher.publishRevision == 2)

        // A repeated event with no new text produces no snapshot and must not
        // invalidate the row's signature.
        #expect(publisher.receive(fullText: "seed one ", at: 0.3) == nil)
        #expect(publisher.publishRevision == 2)

        _ = publisher.complete(at: 0.4)
        #expect(publisher.publishRevision == 3)
    }

    // MARK: Injected parameters

    @Test func injectedPublishIntervalDrivesTheThrottle() {
        var config = CodeStreamingPublisher.Config()
        config.publishInterval = 0.5
        var publisher = CodeStreamingPublisher(config: config)

        _ = publisher.receive(delta: "seed ", at: 0) // first snapshot, whole

        #expect(publisher.receive(delta: "one two ", at: 0.25) == nil)
        #expect(publisher.publishPending)
        let flushed = publisher.flush(at: 0.5 + timingEpsilon)
        #expect(flushed?.text == "seed one two ")
    }

    @Test func nonFinitePublishIntervalCannotBlockPublishing() {
        var config = CodeStreamingPublisher.Config()
        config.publishInterval = .nan
        var publisher = CodeStreamingPublisher(config: config)

        _ = publisher.receive(delta: "seed ", at: 0)
        let snapshot = publisher.receive(delta: "one two ", at: 0.001)
        #expect(snapshot?.text == "seed one two ")
    }

    // MARK: Completion and identity

    @Test func completionFlushesTheRestAndStopsAggregation() {
        var publisher = seededPublisher()
        _ = publisher.receive(delta: "one two ", at: 0.1)

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

    @Test func emptyInputDoesNotCreateASnapshot() {
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

    @Test func aSameLengthFullTextCorrectionReplacesTheVisibleSnapshot() {
        var publisher = makePublisher()
        _ = publisher.receive(fullText: "one two three", at: 0)

        // Same byte count, different bytes: the prefix check cannot see it,
        // so the whole text must be compared.
        let corrected = publisher.receive(fullText: "one two thref", at: 0.1)
        #expect(corrected?.text == "one two thref")
        #expect(publisher.receivedText == "one two thref")
    }

    @Test func aCorrectionBackToThePublishedTextClearsThePendingRequest() {
        var publisher = makePublisher()
        _ = publisher.receive(fullText: eightWords, at: 0)

        #expect(publisher.receive(fullText: "one two ", at: 0.05) == nil)
        #expect(publisher.publishPending)

        // The text returns to what is already on screen, so the queued
        // publish has nothing left to do.
        #expect(publisher.receive(fullText: eightWords, at: 0.06) == nil)
        #expect(!publisher.publishPending)
        #expect(!publisher.hasPendingText)
        #expect(publisher.publishedText == eightWords)
    }

    @Test func aCorrectionRespectsThePublishThrottle() {
        var publisher = makePublisher()
        _ = publisher.receive(fullText: eightWords, at: 0)

        #expect(publisher.receive(fullText: "one two ", at: 0.05) == nil)
        #expect(publisher.publishPending)
        #expect(publisher.publishedText == eightWords)

        let corrected = publisher.flush(at: 0.1 + timingEpsilon)
        #expect(corrected?.text == "one two ")
    }

    // MARK: Clock edge cases

    @Test func aClockRollbackCannotPublishFasterThanTheWindow() {
        var publisher = makePublisher()
        _ = publisher.receive(delta: eightWords, at: 1.0)

        let blocked = publisher.receive(delta: burst, at: 0.5)
        #expect(blocked == nil)
        #expect(publisher.publishPending)
        #expect(publisher.flush(at: 0.5) == nil)

        let resumed = publisher.flush(at: 1.1 + timingEpsilon)
        #expect(resumed?.text == eightWords + burst)
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
