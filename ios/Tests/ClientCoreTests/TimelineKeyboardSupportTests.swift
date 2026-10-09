import Foundation
import Testing
@testable import ClientCore

/// S2 (2026-10-02): pins the non-invalidating publication rules and the
/// keyboard payload parse the timeline's transition windows rely on.
/// Expectations are spelled as literals so any change to a rule turns
/// these red. (The keyboard-height follow this file once covered was reverted
/// at pp's direction; 2026-10-09 added the within-window bottom pin — a hold
/// on the bottom edge, still no keyboard-height arithmetic.)

/// The keyboard window's bottom pin: while the keyboard moves, the page's own
/// follow paths are muted, so a reader at the bottom keeps it by an explicit
/// no-animation pin rather than by the scroll view's default anchor.
@Suite struct TimelineKeyboardBottomPinTests {
    private func pin(following: Bool = true, scrolling: Bool = false, suspended: Bool = false,
                     measured: Bool = true, atBottom: Bool = false) -> Bool {
        TimelineKeyboardBottomPin.shouldPin(isFollowing: following, isScrolling: scrolling,
            navigationSuspended: suspended, isMeasured: measured, atBottom: atBottom)
    }

    @Test func aFollowingReaderKeepsTheBottomWhileTheKeyboardMoves() {
        #expect(pin())
    }

    @Test func aSampleThatAlreadyRestsAtTheBottomIsLeftAlone() {
        #expect(!pin(atBottom: true))
    }

    @Test func theReaderAndTheDrawerAlwaysWin() {
        #expect(!pin(scrolling: true))
        #expect(!pin(suspended: true))
    }

    @Test func onlyFollowingPins() {
        // A reading visit and a presented interaction both land here: neither
        // may be dragged to the bottom by a keyboard.
        #expect(!pin(following: false))
    }

    @Test func anUnmeasuredSampleNeverPins() {
        #expect(!pin(measured: false))
    }
}

@Suite struct TimelineViewportPublicationDecisionTests {
    private func viewport(content: CGFloat = 2000, container: CGFloat = 800,
                          top: CGFloat = 80, bottom: CGFloat = 120, offset: CGFloat = 0) -> TimelineViewport {
        TimelineViewport(contentHeight: content, containerHeight: container,
            topInset: top, bottomInset: bottom, offsetY: offset)
    }
    private func outcome(published: TimelineViewport, next: TimelineViewport,
                         keyboardTransitionActive: Bool = false,
                         tailChanged: Bool = false) -> TimelineViewportPublicationDecision.Outcome {
        TimelineViewportPublicationDecision.outcome(published: published, next: next,
            keyboardTransitionActive: keyboardTransitionActive, tailChanged: tailChanged)
    }

    @Test func offsetOnlySamplesNeverPublish() {
        // The rendered page does not depend on the native offset; restoration
        // reads it straight from the sample box.
        let published = viewport(offset: 1320)
        #expect(outcome(published: published, next: viewport(offset: 1000)) == .ignore)
        #expect(outcome(published: published, next: viewport(offset: 1320.25)) == .ignore)
    }

    @Test func firstMeasuredSampleWasAlwaysPublished() {
        // Opening and the instant return gate on `viewport.isMeasured`.
        let unmeasured = TimelineViewport()
        #expect(!unmeasured.isMeasured)
        #expect(outcome(published: unmeasured, next: viewport()) == .publish)
        // The case rule ① exists for: the sample already carries the content
        // height and inset but no visible height yet, so it differs from the
        // measured one by visible height alone. The first measurement must
        // still publish — even inside a transition window (① wins over ④),
        // otherwise opening waits for a second callback that may not come.
        let emptyViewport = TimelineViewport(contentHeight: 2000, containerHeight: 80,
            topInset: 80, bottomInset: 0, offsetY: 0)
        #expect(!emptyViewport.isMeasured)
        let measured = viewport()
        #expect(measured.contentHeight == emptyViewport.contentHeight && measured.topInset == emptyViewport.topInset)
        #expect(outcome(published: emptyViewport, next: measured) == .publish)
        #expect(outcome(published: emptyViewport, next: measured,
            keyboardTransitionActive: true, tailChanged: false) == .publish)
        // A still-unmeasured sample is not a first measurement.
        #expect(outcome(published: emptyViewport,
            next: TimelineViewport(contentHeight: 2000, containerHeight: 40,
                topInset: 80, bottomInset: 0, offsetY: 0)) == .ignore)
    }

    @Test func contentHeightChangePublishesDuringATransition() {
        // Streaming growth moves the follow target; withholding it while the
        // keyboard animates would stall following, not just the body.
        let published = viewport()
        #expect(outcome(published: published, next: viewport(content: 2020),
            keyboardTransitionActive: true) == .publish)
    }

    @Test func topInsetChangePublishesDuringATransition() {
        // The reader's reference line moved; that is not the keyboard.
        let published = viewport()
        #expect(outcome(published: published, next: viewport(top: 92),
            keyboardTransitionActive: true) == .publish)
    }

    @Test func keyboardVisibleHeightOnlyChangeIsWithheldUntilTheProbeFlips() {
        let published = viewport() // visibleHeight 600
        // The keyboard shrinks the container (mobile drawer path) or grows the
        // bottom inset (iPad path) frame by frame; nothing about the content
        // changed, so publishing it per frame is the body storm rule ④ removes.
        let keyboardSample = viewport(container: 500) // visibleHeight 300
        #expect(outcome(published: published, next: keyboardSample,
            keyboardTransitionActive: true) == .ignore)
        // The end probe flipping during the same transition is the bottom
        // truth moving: publish the sample with it.
        #expect(outcome(published: published, next: keyboardSample,
            keyboardTransitionActive: true, tailChanged: true) == .publish)
        // Outside a transition the same visible-height change is a rotation or
        // split-view resize and must publish.
        #expect(outcome(published: published, next: keyboardSample) == .publish)
    }

    @Test func theSettledSampleReconcilesTheWithheldHeight() {
        // Rule ⑤ is this same decision evaluated with the window closed: the
        // withheld height lands and `lastRequest` dedup cannot stay pinned to
        // a pre-keyboard value.
        let published = viewport()
        let settled = viewport(container: 500)
        #expect(outcome(published: published, next: settled,
            keyboardTransitionActive: true) == .ignore)
        #expect(outcome(published: published, next: settled,
            keyboardTransitionActive: false) == .publish)
    }
}

@Suite struct TimelineKeyboardEventTests {
    /// NSValue geometry construction is the same platform split the production
    /// parse documents: the iOS family spells it `cgRect:`, macOS `rect:`.
    private func frameValue(_ rect: CGRect) -> NSValue {
#if canImport(UIKit)
        NSValue(cgRect: rect)
#else
        NSValue(rect: rect)
#endif
    }
    /// The payload keys are deliberately spelled as the documented raw
    /// strings: the production parse reads those same strings (ClientCore also
    /// builds for macOS, where the `UIResponder` constants do not exist), so a
    /// typo in either place fails these assertions.
    private func payload(duration: NSNumber? = NSNumber(value: 0.25),
                         curve: NSNumber? = NSNumber(value: 7),
                         begin: CGRect? = nil, end: CGRect? = nil,
                         isLocal: NSNumber? = NSNumber(value: true)) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [:]
        if let duration { userInfo["UIKeyboardAnimationDurationUserInfoKey"] = duration }
        if let curve { userInfo["UIKeyboardAnimationCurveUserInfoKey"] = curve }
        if let begin { userInfo["UIKeyboardFrameBeginUserInfoKey"] = frameValue(begin) }
        if let end { userInfo["UIKeyboardFrameEndUserInfoKey"] = frameValue(end) }
        if let isLocal { userInfo["UIKeyboardIsLocalUserInfoKey"] = isLocal }
        return userInfo
    }
    private let onScreen = CGRect(x: 0, y: 564, width: 390, height: 336)
    private let offScreen = CGRect(x: 0, y: 900, width: 390, height: 336)

    @Test func willShowCarriesItsDirectionWithoutFrames() {
        let event = TimelineKeyboardEvent(source: .willShow, userInfo: payload())
        #expect(event.direction == .showing)
        #expect(event.duration == 0.25)
        #expect(event.curve == .privateSpring)
        #expect(event.isLocal)
        #expect(!event.isFinal)
    }

    @Test func willHideCarriesItsDirectionWithoutFrames() {
        let event = TimelineKeyboardEvent(source: .willHide, userInfo: payload(duration: NSNumber(value: 0.35)))
        #expect(event.direction == .hiding)
        #expect(event.duration == 0.35)
    }

    @Test func frameComparisonNamesTheDirection() {
        // Appearance: the top edge travels up from below the screen.
        let showing = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: offScreen, end: onScreen))
        #expect(showing.direction == .showing)
        // Dismissal: it travels back down.
        let hiding = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: offScreen))
        #expect(hiding.direction == .hiding)
        // A height-only change (the predictive row, a keyboard swap) keeps the
        // top edge: not an appearance or a dismissal.
        let resized = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: CGRect(x: 0, y: 564, width: 390, height: 300)))
        #expect(resized.direction == .unchanged)
    }

    @Test func emptyAndMissingFramesStaySafe() {
        // Some systems report a zero begin frame on the first presentation.
        let firstPresentation = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: .zero, end: onScreen))
        #expect(firstPresentation.direction == .showing)
        let teardown = TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen, end: .zero))
        #expect(teardown.direction == .hiding)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: .zero, end: .zero)).direction == .unchanged)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame, userInfo: payload()).direction == .unchanged)
        #expect(TimelineKeyboardEvent(source: .willChangeFrame,
            userInfo: payload(begin: onScreen)).direction == .unchanged)
    }

    @Test func missingFieldsFallBackToTheDocumentedDefaults() {
        let event = TimelineKeyboardEvent(source: .willChangeFrame, userInfo: [:])
        #expect(event.duration == 0)
        #expect(event.isFinal)
        #expect(event.curve == .easeInOut)
        #expect(event.isLocal)
        // A missing duration is a no-animation change: there is no transition
        // window to coordinate with.
        #expect(TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(duration: NSNumber(value: 0))).isFinal)
        #expect(!TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(duration: NSNumber(value: 0.01))).isFinal)
        #expect(!TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(isLocal: NSNumber(value: false))).isLocal)
        // A missing curve can never be parsed as the private spring.
        #expect(TimelineKeyboardEvent(source: .willShow,
            userInfo: payload(curve: nil)).curve == .easeInOut)
    }

    @Test func curvesMapToTheirDocumentedRawValues() {
        let expected: [(Int, TimelineKeyboardEvent.Curve)] = [
            (0, .easeInOut), (1, .easeIn), (2, .easeOut), (3, .linear), (7, .privateSpring),
        ]
        for (raw, curve) in expected {
            #expect(TimelineKeyboardEvent.Curve(rawValue: raw) == curve)
            #expect(TimelineKeyboardEvent(source: .willShow,
                userInfo: payload(curve: NSNumber(value: raw))).curve == curve)
        }
        #expect(TimelineKeyboardEvent.Curve(rawValue: 99) == .unknown(99))
    }
}
