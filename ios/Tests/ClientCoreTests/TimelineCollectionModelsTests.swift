import Foundation
import Testing
@testable import ClientCore

// C1: pure models for the collection timeline. Every type here lives in
// `Models/Chat/TimelineCollection` so the CI test target can reach it; the
// SwiftUI/UIKit wiring arrives in C2/C3.

private func makeViewport(contentHeight: CGFloat = 2000, containerHeight: CGFloat = 600,
                      topInset: CGFloat = 0, bottomInset: CGFloat = 0,
                      offsetY: CGFloat = 0) -> TimelineViewport {
    TimelineViewport(contentHeight: contentHeight, containerHeight: containerHeight,
                     topInset: topInset, bottomInset: bottomInset, offsetY: offsetY)
}

private func heightKey(_ itemID: String = "g:a", revision: Int = 1, width: CGFloat = 390,
                       typography: Int = 7, dynamicType: String = "UICTContentSizeCategoryL",
                       direction: Int = 0) -> TimelineHeightKey {
    TimelineHeightKey(itemID: itemID, contentRevision: revision, width: width,
                      dynamicType: dynamicType, typographyRevision: typography,
                      layoutDirection: direction)
}

private func groupSignature(rowRevision: Int = 1,
                            updatedSeq: Int = 3,
                            disclosureExpanded: Bool = false,
                            inlineNotices: [TimelineInlineNoticeSignature] = [],
                            attachments: [TimelineAttachmentPreviewSignature] = [],
                            turnAction: TimelineTurnActionSignature? = nil,
                            suppression: TimelineTurnSuppression = .init(
                                isRunning: false, hasNewerItems: false, hasPendingUserMessage: false))
    -> TimelineGroupContentSignature {
    TimelineGroupContentSignature(
        rows: [TimelineRowContentSignature(id: "row-1", revision: rowRevision, updatedSeq: updatedSeq)],
        disclosureExpanded: disclosureExpanded,
        inlineNotices: inlineNotices,
        attachments: attachments,
        turnAction: turnAction,
        turnSuppression: suppression)
}

private func layout(first: String = "old", anchor: String = "old", y: CGFloat = 80,
                    edge: TimelineHistoryLayout.Edge = .top) -> TimelineHistoryLayout {
    TimelineHistoryLayout(firstRowID: first, anchorRowID: anchor, edge: edge, y: y)
}

@Suite struct TimelineItemIdentityTests {
    @Test func orderMatchesTheSwiftUIList() {
        let identity = TimelineItemIdentity.build(hasOlderPrompt: true,
            groupIDs: ["g1", "g2"], noticeIDs: ["n1"], pendingIDs: ["p1"],
            hasLatestPrompt: true, hasTail: true)
        #expect(identity.items == [.olderPrompt, .group("g1"), .group("g2"),
            .notice("n1"), .pending("p1"), .latestPrompt, .tail])
        #expect(!identity.hasDuplicates)
    }

    @Test func duplicateIDsKeepTheFirstOccurrenceAndAreReported() {
        let identity = TimelineItemIdentity.build(hasOlderPrompt: false,
            groupIDs: ["a", "b", "a"], noticeIDs: ["n", "n"], pendingIDs: ["p", "p"],
            hasLatestPrompt: false)
        #expect(identity.items == [.group("a"), .group("b"), .notice("n"), .pending("p"), .tail])
        #expect(identity.duplicateGroupIDs == ["a"])
        #expect(identity.duplicateNoticeIDs == ["n"])
        #expect(identity.duplicatePendingIDs == ["p"])
        #expect(identity.hasDuplicates)
    }

    @Test func itemIDsArePrefixedSoCategoriesCannotCollideInTheHeightCache() {
        #expect(TimelineListItem.group("x").itemID == "g:x")
        #expect(TimelineListItem.notice("x").itemID == "n:x")
        #expect(TimelineListItem.pending("x").itemID == "p:x")
        #expect(TimelineListItem.olderPrompt.itemID == "prompt:older")
        #expect(TimelineListItem.latestPrompt.itemID == "prompt:latest")
        #expect(TimelineListItem.tail.itemID == "tail")
    }
}

@Suite struct TimelineVisibilityProbeTests {
    @Test func olderPromptNeedsNinetyPercentVisible() {
        let viewport = makeViewport(offsetY: 0) // visible content: 0…600
        // [560, 604]: 40 of 44pt visible = 90.9%.
        #expect(TimelineVisibilityProbeRule.olderPromptVisible(
            TimelineVisibilityProbe(minY: 560, height: 44), in: viewport))
        // [562, 606]: 38 of 44pt visible = 86.4%.
        #expect(!TimelineVisibilityProbeRule.olderPromptVisible(
            TimelineVisibilityProbe(minY: 562, height: 44), in: viewport))
    }

    @Test func latestPromptNeedsFiftyPercentVisible() {
        let viewport = makeViewport(offsetY: 0)
        // [578, 622]: 22 of 44pt visible = exactly 50%.
        #expect(TimelineVisibilityProbeRule.latestPromptVisible(
            TimelineVisibilityProbe(minY: 578, height: 44), in: viewport))
        // [579, 623]: 21 of 44pt visible = 47.7%.
        #expect(!TimelineVisibilityProbeRule.latestPromptVisible(
            TimelineVisibilityProbe(minY: 579, height: 44), in: viewport))
    }

    @Test func tailNearMarkerUsesAOnePercentFraction() {
        // The overlay is 96pt tall above the tail's bottom edge. 1% = 0.96pt.
        var viewport = makeViewport(offsetY: 1400) // visible content: 1400…2000
        #expect(TimelineVisibilityProbeRule.tailNearVisible(
            TimelineVisibilityProbeRule.tailNear(tailBottom: 2000), in: viewport))
        #expect(viewport.visibleBottom == 2000)
        // Move the visible bottom to 1905: only 1pt of the 96pt marker shows,
        // which is just over the 1% threshold.
        viewport = makeViewport(offsetY: 1305) // 1305…1905
        #expect(TimelineVisibilityProbeRule.tailNearVisible(
            TimelineVisibilityProbeRule.tailNear(tailBottom: 2000), in: viewport))
        // 1903: the marker starts at 1904, so nothing is visible.
        viewport = makeViewport(offsetY: 1303)
        #expect(!TimelineVisibilityProbeRule.tailNearVisible(
            TimelineVisibilityProbeRule.tailNear(tailBottom: 2000), in: viewport))
    }

    @Test func tailEndMarkerNeedsHalfOfTwoPoints() {
        // The 2pt marker is [1998, 2000]; 1pt of overlap is exactly 50%.
        var viewport = makeViewport(offsetY: 1399) // 1399…1999
        #expect(TimelineVisibilityProbeRule.tailEndVisible(
            TimelineVisibilityProbeRule.tailEnd(tailBottom: 2000), in: viewport))
        viewport = makeViewport(offsetY: 1398) // 1398…1998
        #expect(!TimelineVisibilityProbeRule.tailEndVisible(
            TimelineVisibilityProbeRule.tailEnd(tailBottom: 2000), in: viewport))
    }

    @Test func unmeasuredViewportReportsNothingVisible() {
        #expect(TimelineVisibilityProbe(minY: 0, height: 44)
            .visibleFraction(in: TimelineViewport()) == 0)
        #expect(!TimelineVisibilityProbeRule.tailEndVisible(
            TimelineVisibilityProbeRule.tailEnd(tailBottom: 0), in: TimelineViewport()))
    }

    @Test func visibleFractionClampsToIntersectionOverHeight() {
        let probe = TimelineVisibilityProbe(minY: 100, height: 40)
        #expect(probe.visibleFraction(in: makeViewport()) == 1) // [100,140] inside 0…600
        #expect(TimelineVisibilityProbe(minY: 580, height: 40)
            .visibleFraction(in: makeViewport()) == 0.5) // 20 of 40pt
        #expect(TimelineVisibilityProbe(minY: 700, height: 40)
            .visibleFraction(in: makeViewport()) == 0)
    }
}

@Suite struct TimelineOffsetTargetTests {
    @Test func bottomOffsetIncludesInsets() {
        #expect(TimelineOffsetTarget.bottomOffset(contentHeight: 2000, containerHeight: 600,
            topInset: 60, bottomInset: 20) == 1420)
    }

    @Test func subViewportContentRestsAtTheTopInset() {
        #expect(TimelineOffsetTarget.bottomOffset(contentHeight: 400, containerHeight: 600,
            topInset: 60, bottomInset: 20) == -60)
        #expect(TimelineOffsetTarget.isSubViewport(contentHeight: 520, containerHeight: 600,
            topInset: 60, bottomInset: 20))
    }

    @Test func clampingRemovesOverscrollAndOvershoot() {
        let clamp: (CGFloat) -> CGFloat = {
            TimelineOffsetTarget.clamped($0, contentHeight: 2000, containerHeight: 600,
                                         topInset: 60, bottomInset: 20)
        }
        #expect(clamp(-135) == -60)
        #expect(clamp(5000) == 1420)
        #expect(clamp(700) == 700)
    }
}

@Suite struct TimelinePhaseMappingTests {
    @Test func dragAndInertiaSequence() {
        var mapping = TimelinePhaseMapping()
        var transition = mapping.apply(.willBeginDragging)
        #expect(transition.previous == .idle && transition.current == .interacting)
        #expect(transition.gestureBegan)
        transition = mapping.apply(.didEndDragging(willDecelerate: true))
        #expect(transition.current == .decelerating)
        transition = mapping.apply(.didEndDecelerating)
        #expect(transition.current == .idle && !transition.gestureBegan)
    }

    @Test func dragThatStopsWithoutInertiaEndsImmediately() {
        var mapping = TimelinePhaseMapping()
        mapping.apply(.willBeginDragging)
        #expect(mapping.userIsScrolling)
        let transition = mapping.apply(.didEndDragging(willDecelerate: false))
        #expect(transition.current == .idle)
        #expect(!mapping.userIsScrolling)
    }

    @Test func trackingIsNeverProduced() {
        let events: [TimelinePhaseMapping.Event] = [
            .willBeginDragging, .didEndDragging(willDecelerate: true), .didEndDragging(willDecelerate: false),
            .didEndDecelerating, .animationBegan, .animationEnded,
            .scrollToTopBegan, .scrollToTopEnded, .watchdogExpired,
        ]
        var mapping = TimelinePhaseMapping()
        for event in events {
            let transition = mapping.apply(event)
            #expect(transition.current != .tracking)
            // Repeat from an animating state too, so every event is exercised
            // with a non-idle predecessor.
            mapping = TimelinePhaseMapping()
            mapping.apply(.animationBegan)
            let fromAnimating = mapping.apply(event)
            #expect(fromAnimating.current != .tracking)
        }
    }

    @Test func animationCompletionComesFromTheCallback() {
        var mapping = TimelinePhaseMapping()
        mapping.apply(.animationBegan)
        let done = mapping.apply(.animationEnded)
        #expect(done.current == .idle && done.animationCompleted)
        // A late completion outside an animation is not a completion.
        let late = mapping.apply(.animationEnded)
        #expect(late.animationCompleted == false)
    }

    @Test func noOpAnimationIsSettledByTheWatchdog() {
        var mapping = TimelinePhaseMapping()
        mapping.apply(.animationBegan)
        let fired = mapping.apply(.watchdogExpired)
        #expect(fired.current == .idle && fired.animationCompleted)
        // The watchdog is inert when no animation is pending.
        let again = mapping.apply(.watchdogExpired)
        #expect(again.current == .idle && !again.animationCompleted)
    }

    @Test func statusBarScrollToTopUsesTheSameAnimationPhase() {
        var mapping = TimelinePhaseMapping()
        let began = mapping.apply(.scrollToTopBegan)
        #expect(began.current == .animating)
        let done = mapping.apply(.scrollToTopEnded)
        #expect(done.current == .idle && done.animationCompleted)
    }
}

@Suite struct TimelineContentSignatureTests {
    @Test func unchangedSnapshotReportsNoChanges() {
        var store = TimelineContentSignatures()
        let entries = [TimelineContentEntry(item: .group("g"), signature: .group(groupSignature()))]
        let first = store.update(entries)
        #expect(first.changed == [.group("g")]) // first sighting is a new item
        let second = store.update(entries)
        #expect(second.changed.isEmpty && second.removed.isEmpty)
    }

    @Test func everyHeightBearingGroupFieldChangesTheSignature() {
        let base = TimelineContentSignature.group(groupSignature())
        let variants: [TimelineContentSignature] = [
            .group(groupSignature(rowRevision: 2)),
            .group(groupSignature(disclosureExpanded: true)),
            .group(groupSignature(inlineNotices: [
                TimelineInlineNoticeSignature(id: "n", status: .open, revision: 1)
            ])),
            .group(groupSignature(attachments: [
                TimelineAttachmentPreviewSignature(id: "a", pixelWidth: 100, pixelHeight: 50)
            ])),
            .group(groupSignature(turnAction: TimelineTurnActionSignature(
                replyIDs: ["row-1"], changeIDs: [], startsMidTurn: false))),
            .group(groupSignature(suppression: TimelineTurnSuppression(
                isRunning: true, hasNewerItems: false, hasPendingUserMessage: false))),
        ]
        for variant in variants {
            #expect(variant != base)
        }
    }

    @Test func promptFlagsAllChangeTheSignature() {
        let base = TimelineContentSignature.olderPrompt(
            pullReady: false, isLoading: false, keepsPrompt: false, hasOlderItems: true)
        #expect(base != .olderPrompt(pullReady: true, isLoading: false,
                                     keepsPrompt: false, hasOlderItems: true))
        #expect(base != .olderPrompt(pullReady: false, isLoading: true,
                                     keepsPrompt: false, hasOlderItems: true))
        #expect(base != .olderPrompt(pullReady: false, isLoading: false,
                                     keepsPrompt: true, hasOlderItems: true))
        #expect(base != .olderPrompt(pullReady: false, isLoading: false,
                                     keepsPrompt: false, hasOlderItems: false))

        let latest = TimelineContentSignature.latestPrompt(
            pullReady: false, isLoading: false, hasNewerItems: false)
        #expect(latest != .latestPrompt(pullReady: true, isLoading: false, hasNewerItems: false))
        #expect(latest != .latestPrompt(pullReady: false, isLoading: true, hasNewerItems: false))
        #expect(latest != .latestPrompt(pullReady: false, isLoading: false, hasNewerItems: true))
    }

    @Test func noticePendingAndTailFieldsAreCovered() {
        let notice = TimelineContentSignature.notice(id: "n", status: .open, revision: 1)
        #expect(notice != .notice(id: "n", status: .resolved, revision: 1))
        #expect(notice != .notice(id: "n", status: .open, revision: 2))

        let pending = TimelineContentSignature.pending(id: "p", attachments: [])
        var oneFold = groupSignature()
        oneFold.expandedRowIDs = ["a"]
        var twoFolds = groupSignature()
        twoFolds.expandedRowIDs = ["a", "b"]
        var noFolds = groupSignature()
        noFolds.expandedRowIDs = []
        #expect(oneFold.contentRevision != twoFolds.contentRevision)
        #expect(oneFold.contentRevision != noFolds.contentRevision)
        var reordered = groupSignature()
        reordered.expandedRowIDs = ["b", "a"]
        #expect(twoFolds.contentRevision == reordered.contentRevision)

        #expect(pending != .pending(id: "p", attachments: [
            TimelineAttachmentPreviewSignature(id: "a", pixelWidth: 1, pixelHeight: 1)
        ]))

        let tail = TimelineContentSignature.tail(TimelineTailContentSignature(
            queue: [TimelineQueueEntrySignature(id: "q", state: "queued")],
            sendingPlaceholder: "Thinking", orbActivity: "thinking", hasNewerItems: false))
        #expect(tail != .tail(TimelineTailContentSignature(
            queue: [TimelineQueueEntrySignature(id: "q", state: "sending")],
            sendingPlaceholder: "Thinking", orbActivity: "thinking", hasNewerItems: false)))
        #expect(tail != .tail(TimelineTailContentSignature(
            queue: [TimelineQueueEntrySignature(id: "q", state: "queued")],
            sendingPlaceholder: nil, orbActivity: "thinking", hasNewerItems: false)))
        #expect(tail != .tail(TimelineTailContentSignature(
            queue: [TimelineQueueEntrySignature(id: "q", state: "queued")],
            sendingPlaceholder: "Thinking", orbActivity: "idle", hasNewerItems: false)))
        #expect(tail != .tail(TimelineTailContentSignature(
            queue: [TimelineQueueEntrySignature(id: "q", state: "queued")],
            sendingPlaceholder: "Thinking", orbActivity: "thinking", hasNewerItems: true)))
    }

    @Test func removalIsReportedOnce() {
        var store = TimelineContentSignatures()
        store.update([
            TimelineContentEntry(item: .group("g"), signature: .group(groupSignature())),
            TimelineContentEntry(item: .tail, signature: .tail(TimelineTailContentSignature(
                queue: [], sendingPlaceholder: nil, orbActivity: "idle", hasNewerItems: false))),
        ])
        let change = store.update([
            TimelineContentEntry(item: .group("g"), signature: .group(groupSignature())),
        ])
        #expect(change.changed.isEmpty)
        #expect(change.removed == [.tail])
        #expect(store.signature(for: .tail) == nil)
    }

    @Test func disclosureNoticeAndPreviewChangeTheGroupContentRevision() {
        let base = groupSignature()
        #expect(base.contentRevision != groupSignature(disclosureExpanded: true).contentRevision)
        #expect(base.contentRevision != groupSignature(inlineNotices: [
            TimelineInlineNoticeSignature(id: "n", status: .open, revision: 1)
        ]).contentRevision)
        #expect(base.contentRevision != groupSignature(attachments: [
            TimelineAttachmentPreviewSignature(id: "a", pixelWidth: 100, pixelHeight: 50)
        ]).contentRevision)
        // Every height input must move the revision, not only the whole
        // synthesized signature: the controller reuses a measured height when
        // the revision is equal.
        #expect(base.contentRevision != groupSignature(rowRevision: 2).contentRevision)
        #expect(base.contentRevision != groupSignature(updatedSeq: 4).contentRevision)
        let open = groupSignature(inlineNotices: [
            TimelineInlineNoticeSignature(id: "n", status: .open, revision: 1)
        ])
        #expect(open.contentRevision != groupSignature(inlineNotices: [
            TimelineInlineNoticeSignature(id: "n", status: .resolved, revision: 1)
        ]).contentRevision)
        #expect(open.contentRevision != groupSignature(inlineNotices: [
            TimelineInlineNoticeSignature(id: "n", status: .open, revision: 2)
        ]).contentRevision)
        let reply = TimelineTurnActionSignature(replyIDs: ["r"], changeIDs: [],
                                                startsMidTurn: false)
        #expect(base.contentRevision != groupSignature(turnAction: reply).contentRevision)
        let change1 = TimelineTurnActionSignature(replyIDs: [], changeIDs: ["c"],
            startsMidTurn: false, changeRevisions: [1])
        let change2 = TimelineTurnActionSignature(replyIDs: [], changeIDs: ["c"],
            startsMidTurn: false, changeRevisions: [2])
        #expect(groupSignature(turnAction: change1).contentRevision
            != groupSignature(turnAction: change2).contentRevision)
        for suppression in [
            TimelineTurnSuppression(isRunning: true, hasNewerItems: false,
                                    hasPendingUserMessage: false),
            TimelineTurnSuppression(isRunning: false, hasNewerItems: true,
                                    hasPendingUserMessage: false),
            TimelineTurnSuppression(isRunning: false, hasNewerItems: false,
                                    hasPendingUserMessage: true),
        ] {
            #expect(base.contentRevision
                != groupSignature(suppression: suppression).contentRevision)
        }
        // Unchanged inputs keep the revision stable so a measurement is reused.
        #expect(base.contentRevision == groupSignature().contentRevision)
    }
}

@Suite struct TimelinePreferredAttributesDecisionTests {
    @Test func pendingMeasurementCompensatesPartiallyVisibleRows() {
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: 118, cellMinY: 580, viewportTop: 600,
            isStreaming: false, isAutoScrollPinning: false,
            isTracking: false, isDecelerating: false,
            keyboardTransition: false, suppressContentOffsetAdjustment: false,
            hasCachedHeight: true)
        #expect(decision.height == .accept)
        #expect(decision.correction == 118)
    }

    @Test func pendingMeasurementBelowTheViewportDoesNotMoveTheReader() {
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: 118, cellMinY: 900, viewportTop: 600,
            isStreaming: false, isAutoScrollPinning: false,
            isTracking: false, isDecelerating: false,
            keyboardTransition: false, suppressContentOffsetAdjustment: false,
            hasCachedHeight: true)
        #expect(decision.correction == nil)
    }

    @Test func pendingMeasurementWhileStreamingAndPinnedStaysAtTheBottom() {
        let decision = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: 40, cellMinY: 900, viewportTop: 600,
            isStreaming: true, isAutoScrollPinning: true,
            isTracking: false, isDecelerating: false,
            keyboardTransition: false, suppressContentOffsetAdjustment: false,
            hasCachedHeight: true)
        #expect(decision.correction == 40)
    }

    @Test func browsingParksCachedShrinksButLetsGrowthThrough() {
        func run(delta: CGFloat, cached: Bool = true) -> TimelinePreferredAttributesDecision {
            .pendingMeasurement(delta: delta, cellMinY: -100, viewportTop: 600,
                isStreaming: false, isAutoScrollPinning: false,
                isTracking: true, isDecelerating: false,
                keyboardTransition: false, suppressContentOffsetAdjustment: false,
                hasCachedHeight: cached)
        }
        #expect(run(delta: -20).height == .deferUntilSettled)
        #expect(run(delta: 20).height == .accept)
        #expect(run(delta: 20).correction == nil)
        // An uncached row may take its first measurement.
        #expect(run(delta: -20, cached: false).height == .accept)
    }

    @Test func keyboardTransitionAndSuppressionNeverMoveTheOffset() {
        let keyboard = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: 40, cellMinY: 0, viewportTop: 600,
            isStreaming: false, isAutoScrollPinning: true,
            isTracking: false, isDecelerating: false,
            keyboardTransition: true, suppressContentOffsetAdjustment: false,
            hasCachedHeight: true)
        #expect(keyboard.height == .accept && keyboard.correction == nil)
        let suppressed = TimelinePreferredAttributesDecision.pendingMeasurement(
            delta: 40, cellMinY: 0, viewportTop: 600,
            isStreaming: false, isAutoScrollPinning: false,
            isTracking: false, isDecelerating: false,
            keyboardTransition: false, suppressContentOffsetAdjustment: true,
            hasCachedHeight: true)
        #expect(suppressed.correction == nil)
    }

    @Test func selfSizingThreeBranches() {
        func run(minY: CGFloat, maxY: CGFloat, streaming: Bool = false,
                 pinning: Bool = false, delta: CGFloat = 30, cached: Bool = true)
            -> TimelinePreferredAttributesDecision {
            .selfSizing(delta: delta, cellMinY: minY, cellMaxY: maxY,
                viewportTop: 600, viewportBottom: 1200,
                isStreaming: streaming, isAutoScrollPinning: pinning,
                isTracking: false, isDecelerating: false,
                keyboardTransition: false, hasCachedHeight: cached)
        }
        // 1. Fully above.
        #expect(run(minY: 100, maxY: 200).correction == 30)
        // 2. Visible, non-streaming.
        #expect(run(minY: 700, maxY: 900).correction == 30)
        // 2b. Visible but streaming, pinned, growth.
        #expect(run(minY: 700, maxY: 900, streaming: true, pinning: true).correction == 30)
        // 3. Streaming without pinning: no offset.
        #expect(run(minY: 700, maxY: 900, streaming: true, pinning: false).correction == nil)
        // 4. Partially visible non-streaming: corrected on the next settled frame.
        #expect(run(minY: 500, maxY: 700).correction == nil)
    }

    @Test func selfSizingGrowthIsAllowedWhileBrowsingAndShrinkParks() {
        func run(delta: CGFloat, cached: Bool = true) -> TimelinePreferredAttributesDecision {
            .selfSizing(delta: delta, cellMinY: -100, cellMaxY: 100,
                viewportTop: 600, viewportBottom: 1200,
                isStreaming: false, isAutoScrollPinning: false,
                isTracking: false, isDecelerating: true,
                keyboardTransition: false, hasCachedHeight: cached)
        }
        #expect(run(delta: -10).height == .deferUntilSettled)
        #expect(run(delta: 10).height == .accept)
        #expect(run(delta: -10, cached: false).height == .accept)
    }

    @Test func autoScrollPinningDefinition() {
        #expect(TimelinePreferredAttributesDecision.isAutoScrollPinning(
            hasArmedBottomTarget: true, interactionPresented: false,
            userIsScrolling: false, mode: .following))
        #expect(!TimelinePreferredAttributesDecision.isAutoScrollPinning(
            hasArmedBottomTarget: true, interactionPresented: true,
            userIsScrolling: false, mode: .following))
        #expect(!TimelinePreferredAttributesDecision.isAutoScrollPinning(
            hasArmedBottomTarget: true, interactionPresented: false,
            userIsScrolling: true, mode: .following))
        #expect(!TimelinePreferredAttributesDecision.isAutoScrollPinning(
            hasArmedBottomTarget: true, interactionPresented: false,
            userIsScrolling: false, mode: .reading))
    }

    @Test func onlyControlledExceptionsAcceptPreferredHeight() {
        #expect(!TimelineRowHeightPolicy.measured.acceptsPreferredHeight)
        #expect(TimelineRowHeightPolicy.interactive.acceptsPreferredHeight)
        #expect(TimelineRowHeightPolicy.tail.acceptsPreferredHeight)
    }
}

@Suite struct TimelineInsertionOwedTests {
    @Test func outwardPullOriginIsClampedToTheRestingInset() {
        var owed = TimelineInsertionOwed(generation: 7, origin: layout(), offsetY: -135, topInset: 80)
        let target = owed.update(layout: layout(first: "earlier", y: 1080))
        #expect(owed.originOffset == -80)
        // The same 920 the SwiftUI path restores: -80 + (1080 - 80).
        #expect(target == 920)
    }

    @Test func absoluteTargetIsIdempotentAcrossQueries() {
        var owed = TimelineInsertionOwed(generation: 1, origin: layout(), offsetY: 7458, topInset: 60)
        owed.update(layout: layout(first: "earlier", y: 16658 - 7458 + 80))
        let target = owed.update(layout: layout(first: "earlier", y: 9280))
        #expect(target == 16658) // origin 80, offset 7458: 7458 + 9280 - 80
        let firstQuery = owed.targetOffset(proposed: 7458)
        let secondQuery = owed.targetOffset(proposed: 7458)
        #expect(firstQuery == 16658)
        #expect(secondQuery == 16658)
    }

    @Test func appendSetsNoOwedAndPassesTheProposedOffsetThrough() {
        var owed = TimelineInsertionOwed(generation: 2, origin: layout(), offsetY: 20, topInset: 80)
        let update = owed.update(layout: layout()) // same first row: no page
        #expect(update == nil)
        let offered = owed.targetOffset(proposed: 520)
        let fallback = owed.finalizeFallback()
        #expect(offered == 520)
        #expect(fallback == nil)
        #expect(owed.isSettled)
    }

    @Test func repeatedLayoutPassesDoNotAccumulate() {
        var owed = TimelineInsertionOwed(generation: 3, origin: layout(), offsetY: 20, topInset: 80)
        let first = owed.update(layout: layout(first: "earlier", y: 580))
        let repeatPass = owed.update(layout: layout(first: "earlier", y: 580))
        // A later measurement corrects against the origin, not the previous target.
        let settled = owed.update(layout: layout(first: "earlier", y: 612))
        #expect(first == 520)
        #expect(repeatPass == 520)
        #expect(settled == 552)
    }

    @Test func anchorOrEdgeMismatchIsIgnored() {
        var owed = TimelineInsertionOwed(generation: 4,
            origin: layout(first: "old-tool", anchor: "last-tool", y: 500, edge: .bottom),
            offsetY: 100, topInset: 80)
        let otherAnchor = owed.update(layout: layout(first: "earlier-tool", anchor: "other-tool",
                                                     y: 900, edge: .bottom))
        let otherEdge = owed.update(layout: layout(first: "earlier-tool", anchor: "last-tool",
                                                   y: 800, edge: .top))
        let matching = owed.update(layout: layout(first: "earlier-tool", anchor: "last-tool",
                                                  y: 800, edge: .bottom))
        #expect(otherAnchor == nil)
        #expect(otherEdge == nil)
        #expect(matching == 400)
    }

    @Test func cancellationMakesTheSlowResponseInert() {
        var owed = TimelineInsertionOwed(generation: 5, origin: layout(), offsetY: 20, topInset: 80)
        owed.update(layout: layout(first: "earlier", y: 780))
        owed.cancel()
        #expect(owed.isCancelled && owed.isSettled)
        let offered = owed.targetOffset(proposed: 100)
        let fallback = owed.finalizeFallback()
        let lateUpdate = owed.update(layout: layout(first: "even-earlier", y: 980))
        #expect(offered == 100)
        #expect(fallback == nil)
        #expect(lateUpdate == nil)
    }

    @Test func finalizeFallbackOnlyFiresWhenNoQueryHappened() {
        var unasked = TimelineInsertionOwed(generation: 6, origin: layout(), offsetY: 20, topInset: 80)
        unasked.update(layout: layout(first: "earlier", y: 780))
        let fallback = unasked.finalizeFallback()
        let afterFallback = unasked.finalizeFallback()
        #expect(fallback == 720)
        #expect(unasked.isSettled)
        #expect(afterFallback == nil)

        var asked = TimelineInsertionOwed(generation: 7, origin: layout(), offsetY: 20, topInset: 80)
        asked.update(layout: layout(first: "earlier", y: 780))
        let offered = asked.targetOffset(proposed: 0)
        let askedFallback = asked.finalizeFallback()
        #expect(offered == 720)
        #expect(askedFallback == nil)
        #expect(asked.isSettled)
    }

    @Test func inUpdateMeasurementCorrectionFoldsIntoTheAbsoluteTarget() {
        var owed = TimelineInsertionOwed(generation: 9, origin: layout(), offsetY: 20, topInset: 80)
        _ = owed.update(layout: layout(first: "earlier", y: 780))
        let beforeAdjust = owed.targetOffset(proposed: 0)
        owed.adjustTarget(by: 30)
        let afterAdjust = owed.targetOffset(proposed: 0)
        #expect(beforeAdjust == 720)
        #expect(afterAdjust == 750)
    }

    @Test func oneShotOwedReplacesAndClears() {
        var owed = TimelineOneShotOwed()
        let first = owed.offer(proposed: 12)
        #expect(first == 12)
        owed.replace(target: 99)
        let second = owed.offer(proposed: 12)
        let third = owed.offer(proposed: 12)
        let consumed = owed.takeAfterFinalize()
        #expect(second == 99)
        #expect(third == 99)
        #expect(consumed == nil)
        owed.replace(target: 40)
        let fallback = owed.takeAfterFinalize()
        #expect(fallback == 40)
        #expect(owed.isEmpty)
    }

    @Test func correctionDirectionDiffersFromSettlementWaiting() {
        // Correction: apply only when a page actually inserted above
        // (`firstRowID != origin`). Settlement: wait until the expected first
        // row arrives (`== expected`).
        var owed = TimelineInsertionOwed(generation: 8, origin: layout(), offsetY: 20, topInset: 80)
        let sameFirstRow = owed.update(layout: layout()) // still == origin: no insertion
        let inserted = owed.update(layout: layout(first: "earlier", y: 780))
        #expect(sameFirstRow == nil)
        #expect(inserted == 720)

        var history = TimelineHistoryPosition(id: 8, layout: layout(), offsetY: 20, topInset: 80)
        history.receivedPage(firstRowID: "earlier")
        // The same layout that owed a correction does not yet finish the
        // request: settlement waits for the expected first row.
        #expect(!history.isReadyToFinish)
        _ = history.laidOut(layout(first: "earlier", y: 780), generation: 8)
        #expect(history.isReadyToFinish)
    }
}

@Suite struct TimelineHeightKeyingTests {
    @Test func widthIsQuantizedToHalfAPoint() {
        #expect(TimelineHeightKey.quantize(320.0) == 320.0)
        #expect(TimelineHeightKey.quantize(320.2) == 320.0)
        #expect(TimelineHeightKey.quantize(320.3) == 320.5)
        #expect(TimelineHeightKey.quantize(320.75) == 321.0)
        #expect(TimelineHeightKey.quantize(-10) == 0)
    }

    @Test func everyKeyFieldInvalidatesTheEntry() {
        let base = heightKey()
        #expect(heightKey(revision: 2) != base)
        #expect(heightKey(width: 391) != base)
        #expect(heightKey(typography: 8) != base)
        #expect(heightKey(dynamicType: "UICTContentSizeCategoryXXXL") != base)
        #expect(heightKey(direction: 1) != base)
        #expect(heightKey("g:b") != base)
        #expect(heightKey() == base)
    }

    @Test func typographyRevisionCoversEverySetting() {
        let base = TimelineTypographySnapshot(body: 13, lineSpacing: 8, paragraphSpacing: 20,
            headings: [18, 16, 14], inlineCodeRatio: 14.8 / 14, codeBlockRatio: 12.3 / 13,
            codeBlockLineSpacingRatio: (14.33 - 12.3) / 12.3,
            inlineCodePin: nil, codeBlockPin: 12.3,
            inlineCodeBold: false, boldText: false,
            dynamicType: "UICTContentSizeCategoryL", layoutDirection: 0)
        var variants: [TimelineTypographySnapshot] = []
        var copy = base; copy.body = 14; variants.append(copy)
        copy = base; copy.lineSpacing = 9; variants.append(copy)
        copy = base; copy.paragraphSpacing = 21; variants.append(copy)
        copy = base; copy.headings = [19, 16, 14]; variants.append(copy)
        copy = base; copy.inlineCodeRatio = 1.1; variants.append(copy)
        copy = base; copy.codeBlockRatio = 0.9; variants.append(copy)
        copy = base; copy.codeBlockLineSpacingRatio = 0.2; variants.append(copy)
        copy = base; copy.inlineCodePin = 15; variants.append(copy)
        copy = base; copy.codeBlockPin = nil; variants.append(copy)
        copy = base; copy.inlineCodeBold = true; variants.append(copy)
        copy = base; copy.boldText = true; variants.append(copy)
        copy = base; copy.dynamicType = "UICTContentSizeCategoryXXXL"; variants.append(copy)
        copy = base; copy.layoutDirection = 1; variants.append(copy)
        for variant in variants {
            #expect(variant.revision != base.revision)
        }
        #expect(base.revision == base.revision)
    }
}

@Suite struct TimelineHeightCacheTests {
    @Test func tierPriorityIsMeasuredThenPrecalcThenEstimate() {
        let cache = TimelineHeightCache()
        let key = heightKey()
        cache.set(90, for: key, tier: .estimate)
        #expect(cache.tieredHeight(for: key) == 90)
        cache.set(80, for: key, tier: .precalc)
        #expect(cache.tieredHeight(for: key) == 80)
        cache.set(70, for: key, tier: .measured)
        #expect(cache.tieredHeight(for: key) == 70)
    }

    @Test func aNewRevisionFallsBackToTheDisplayedHeightNotTheOldMeasurement() {
        let cache = TimelineHeightCache()
        let first = heightKey(revision: 1)
        cache.setCurrentKey(first)
        cache.set(300, for: first, tier: .measured)
        cache.noteDisplayedHeight(120, for: "g:a")
        // Streaming text arrives: revision 2, new key, no measured entry yet.
        let second = heightKey(revision: 2)
        cache.setCurrentKey(second)
        cache.markPending("g:a")
        // The retired key is dropped rather than retained as a second tier.
        #expect(cache.tieredHeight(for: first) == nil)
        #expect(cache.resolvedHeight(for: second, itemID: "g:a", fallback: .row) == 120)
        cache.set(180, for: second, tier: .measured)
        #expect(cache.resolvedHeight(for: second, itemID: "g:a", fallback: .row) == 180)
    }

    @Test func kindDefaultsKeepPromptsAndTailFromCollapsing() {
        let cache = TimelineHeightCache()
        #expect(cache.resolvedHeight(for: heightKey("prompt:older"), itemID: "prompt:older",
                                     fallback: .olderPrompt) == 44)
        #expect(cache.resolvedHeight(for: heightKey("tail"), itemID: "tail",
                                     fallback: .tail(statusLine: false)) == 12)
        #expect(cache.resolvedHeight(for: heightKey("tail"), itemID: "tail",
                                     fallback: .tail(statusLine: true)) == 32)
        #expect(cache.resolvedHeight(for: heightKey("g:a"), itemID: "g:a", fallback: .row) == 200)
    }

    @Test func removalAndPruningDropEveryTier() {
        let cache = TimelineHeightCache()
        let key = heightKey()
        cache.setCurrentKey(key)
        cache.set(100, for: key, tier: .measured)
        cache.noteDisplayedHeight(100, for: "g:a")
        cache.markPending("g:a")
        cache.remove(itemID: "g:a")
        #expect(cache.currentKey(for: "g:a") == nil)
        #expect(cache.displayedHeight(for: "g:a") == nil)
        #expect(cache.tieredHeight(for: key) == nil)
        #expect(!cache.isPending("g:a"))

        let kept = heightKey("g:kept")
        let dropped = heightKey("g:dropped")
        cache.setCurrentKey(kept); cache.set(50, for: kept, tier: .measured)
        cache.setCurrentKey(dropped); cache.set(60, for: dropped, tier: .measured)
        cache.prune(keeping: ["g:kept"])
        #expect(cache.tieredHeight(for: kept) == 50)
        #expect(cache.tieredHeight(for: dropped) == nil)
        #expect(cache.trackedItemIDs == ["g:kept"])
    }

    @Test func staleKeysAreDetectedForTheDebugInvariant() {
        let cache = TimelineHeightCache()
        let old = heightKey(revision: 1)
        cache.setCurrentKey(old)
        let new = heightKey(revision: 2)
        #expect(cache.staleItemIDs(expectedKeys: ["g:a": new]) == ["g:a"])
        cache.setCurrentKey(new)
        #expect(cache.staleItemIDs(expectedKeys: ["g:a": new]).isEmpty)
    }

    @Test func pendingTracksOnlyOutstandingMeasurements() {
        let cache = TimelineHeightCache()
        cache.markPending("g:a")
        #expect(cache.isPending("g:a"))
        cache.resolvePending("g:a")
        #expect(!cache.isPending("g:a"))
    }

    @Test func estimatesAreNotMeasuredCacheHits() {
        let cache = TimelineHeightCache()
        let key = heightKey()
        cache.set(200, for: key, tier: .estimate)
        #expect(!cache.hasMeasuredOrPrecalcHeight(for: key))
        cache.set(180, for: key, tier: .precalc)
        #expect(cache.hasMeasuredOrPrecalcHeight(for: key))
        cache.set(170, for: key, tier: .measured)
        #expect(cache.hasMeasuredOrPrecalcHeight(for: key))
    }
}

@Suite struct TimelineListMetricsTests {
    @Test func narrowLayoutUsesSixteenPointMargins() {
        let column = TimelineListMetrics.column(containerWidth: 390)
        #expect(TimelineListMetrics.horizontalInset(containerWidth: 390) == 16)
        #expect(column.width == 358)
        #expect(column.x == 16)
    }

    @Test func wideLayoutUsesTwentyPointMargins() {
        let column = TimelineListMetrics.column(containerWidth: 430)
        #expect(TimelineListMetrics.horizontalInset(containerWidth: 430) == 20)
        #expect(column.width == 390)
        #expect(column.x == 20)
    }

    @Test func columnsAreCappedAtSevenHundredSixtyPointsAndCentered() {
        let column = TimelineListMetrics.column(containerWidth: 1024)
        #expect(column.width == 760)
        #expect(column.x == 132)
    }

    @Test func zeroWidthDoesNotProduceANegativeColumn() {
        let column = TimelineListMetrics.column(containerWidth: 0)
        #expect(column.width == 0)
        #expect(column.x == 0)
    }

    @Test func topInsetAndItemSpacingMatchTheSwiftUILayout() {
        #expect(TimelineListMetrics.topInset == 16)
        #expect(TimelineListMetrics.itemSpacing == 20)
        #expect(TimelineListMetrics.maximumColumnWidth == 760)
    }
}

@Suite struct TimelineArmedBottomTargetTests {
    @Test func forcedCommandsIgnoreReadingModeAndInteraction() {
        var target = TimelineArmedBottomTarget()
        target.forceArm()
        let resolved = target.contentChanged(contentHeight: 2000, containerHeight: 600,
                                             topInset: 60, bottomInset: 20)
        #expect(target.source == .forced)
        #expect(resolved == 1420)
    }

    @Test func followArmingNeedsBottomRestOrAnActiveReturn() {
        var target = TimelineArmedBottomTarget()
        let readingRefused = target.armFollowing(readerRestsAtBottom: false, mode: .reading,
                                                 interactionPresented: false, requiresNoInteraction: false)
        let returningAccepted = target.armFollowing(readerRestsAtBottom: false, mode: .returning,
                                                    interactionPresented: false, requiresNoInteraction: false)
        #expect(!readingRefused)
        #expect(returningAccepted)
        #expect(target.source == .follow)
        target.disarm()
        let interactionRefused = target.armFollowing(readerRestsAtBottom: true, mode: .reading,
                                                     interactionPresented: true, requiresNoInteraction: true)
        let restingAccepted = target.armFollowing(readerRestsAtBottom: true, mode: .reading,
                                                  interactionPresented: false, requiresNoInteraction: true)
        #expect(!interactionRefused)
        #expect(restingAccepted)
    }

    @Test func followArmingNeverDowngradesForced() {
        var target = TimelineArmedBottomTarget()
        target.forceArm()
        target.armFollowing(readerRestsAtBottom: false, mode: .reading,
                            interactionPresented: true, requiresNoInteraction: true)
        #expect(target.source == .forced)
    }

    @Test func userTakeoverDisarmsAndReturningToTheBottomRearms() {
        var target = TimelineArmedBottomTarget()
        target.forceArm()
        target.disarm() // drag / pill / loadLatest / navigation change
        let disarmedResolution = target.contentChanged(contentHeight: 2000, containerHeight: 600,
                                                       topInset: 0, bottomInset: 0)
        #expect(!target.isArmed)
        #expect(disarmedResolution == nil)
        let rearmed = target.readerDidRestAtBottom(readerRestsAtBottom: true, interactionPresented: false)
        let rearmedResolution = target.contentChanged(contentHeight: 2000, containerHeight: 600,
                                                      topInset: 0, bottomInset: 0)
        #expect(rearmed)
        #expect(target.source == .follow)
        #expect(rearmedResolution == 1400)
    }

    @Test func navigationResumeRearmsOnlyWhenStillAtTheBottom() {
        var target = TimelineArmedBottomTarget()
        let awayFromBottom = target.navigationResumed(readerRestsAtBottom: false, interactionPresented: false)
        let atBottom = target.navigationResumed(readerRestsAtBottom: true, interactionPresented: false)
        #expect(!awayFromBottom)
        #expect(atBottom)
        target.disarm()
        let interaction = target.navigationResumed(readerRestsAtBottom: true, interactionPresented: true)
        #expect(!interaction)
    }

    @Test func everyContentSizeChangeRepins() {
        var target = TimelineArmedBottomTarget()
        target.forceArm()
        let first = target.contentChanged(contentHeight: 1000, containerHeight: 600,
                                          topInset: 0, bottomInset: 0)
        let second = target.contentChanged(contentHeight: 1200, containerHeight: 600,
                                           topInset: 0, bottomInset: 0)
        let subViewport = target.contentChanged(contentHeight: 500, containerHeight: 600,
                                                topInset: 0, bottomInset: 0)
        #expect(first == 400)
        #expect(second == 600)
        #expect(subViewport == 0)
        #expect(target.isArmed)
    }

    @Test func keyboardTransitionPausesThePin() {
        var target = TimelineArmedBottomTarget()
        target.forceArm()
        target.setKeyboardTransition(true)
        let paused = target.contentChanged(contentHeight: 2000, containerHeight: 500,
                                           topInset: 0, bottomInset: 300)
        target.setKeyboardTransition(false)
        let resumed = target.contentChanged(contentHeight: 2000, containerHeight: 500,
                                            topInset: 0, bottomInset: 300)
        #expect(paused == nil)
        #expect(resumed == 1800)
    }
}

@Suite struct TimelineMeasurementPipelineTests {
    private func request(_ id: String, content: TimelineMeasurementContent = .markdown,
                         cost: Int = 1, streaming: Bool = false) -> TimelineMeasurementRequest {
        TimelineMeasurementRequest(itemID: id, key: heightKey(id, revision: 1),
            content: content, isStreaming: streaming, estimatedCostMilliseconds: cost)
    }

    @Test func markdownAndComplexContentNeverTakeThePlainTextPrecalcPath() {
        #expect(TimelineMeasurementPipeline.route(for: .plainText) == .textKit2Precalc)
        #expect(TimelineMeasurementPipeline.route(for: .markdown) == .hosting)
        #expect(TimelineMeasurementPipeline.route(for: .complex) == .hosting)
        #expect(TimelineMeasurementPipeline.route(for: .interactive) == .hosting)
        #expect(TimelineMeasurementPipeline.route(for: .tail) == .hosting)
    }

    @Test func aHistoryPageIsMeasuredWholeWhenTheBudgetAllows() {
        var pipeline = TimelineMeasurementPipeline(budgetMilliseconds: 500)
        let requests = (0..<100).map { request("row-\($0)") }
        let plan = pipeline.plan(requests)
        #expect(plan.measureBeforeApply.count == 100)
        #expect(plan.pending.isEmpty)
        #expect(pipeline.pendingItemIDs.isEmpty)
    }

    @Test func exceedingTheBudgetDefersTheTailAndMarksItPending() {
        var pipeline = TimelineMeasurementPipeline(budgetMilliseconds: 80)
        let requests = (0..<100).map { request("row-\($0)") }
        let plan = pipeline.plan(requests)
        #expect(plan.measureBeforeApply.map(\.itemID) == (0..<80).map { "row-\($0)" })
        #expect(plan.pending.map(\.itemID) == (80..<100).map { "row-\($0)" })
        #expect(pipeline.pendingItemIDs.count == 20)
        let completed = pipeline.complete("row-95")
        let completedAgain = pipeline.complete("row-95")
        let stillPending = pipeline.pendingItemIDs.contains("row-95")
        #expect(completed)
        #expect(!completedAgain)
        #expect(!stillPending)
    }

    @Test func replanningClearsPendingItemsThatWereMeasured() {
        var pipeline = TimelineMeasurementPipeline(budgetMilliseconds: 2)
        let requests = (0..<4).map { request("row-\($0)") }
        _ = pipeline.plan(requests)
        #expect(pipeline.pendingItemIDs == ["row-2", "row-3"])
        let second = pipeline.plan(requests)
        #expect(second.measureBeforeApply.map(\.itemID) == ["row-0", "row-1"])
        #expect(pipeline.pendingItemIDs == ["row-2", "row-3"])
        _ = pipeline.plan([request("row-2"), request("row-3")])
        #expect(pipeline.pendingItemIDs.isEmpty)
    }

    @Test func streamingMarkdownStillRoutesThroughHosting() {
        let streaming = request("row", content: .markdown, streaming: true)
        #expect(TimelineMeasurementPipeline.route(for: streaming.content) == .hosting)
    }
}

@Suite struct TimelinePullDeferOrderingTests {
    @Test func idleHeightChangesApplyImmediately() {
        var ordering = TimelinePullDeferOrdering()
        let decision = ordering.heightChange(itemID: "a", delta: -5, hasCachedHeight: true)
        #expect(decision == .applyNow)
    }

    @Test func draggingParksCachedShrinkAndStableButLetsGrowthThrough() {
        var ordering = TimelinePullDeferOrdering()
        ordering.beginDrag()
        let shrink = ordering.heightChange(itemID: "a", delta: -5, hasCachedHeight: true)
        let stable = ordering.heightChange(itemID: "b", delta: 0, hasCachedHeight: true)
        let growth = ordering.heightChange(itemID: "c", delta: 5, hasCachedHeight: true)
        let uncached = ordering.heightChange(itemID: "d", delta: -5, hasCachedHeight: false)
        #expect(shrink == .park)
        #expect(stable == .park)
        #expect(growth == .applyNow)
        #expect(uncached == .applyNow)
        #expect(ordering.deferred.keys.sorted() == ["a", "b"])
    }

    @Test func dragEndingWithoutInertiaSettlesPullBeforeApplyingCorrections() {
        var ordering = TimelinePullDeferOrdering()
        ordering.beginDrag()
        _ = ordering.heightChange(itemID: "b", delta: -5, hasCachedHeight: true)
        _ = ordering.heightChange(itemID: "a", delta: -3, hasCachedHeight: true)
        let application = ordering.endDrag(willDecelerate: false)
        let secondApplication = ordering.endDrag(willDecelerate: false)
        let expected = TimelinePullDeferOrdering.Application(effects: [
            .settlePull,
            .apply(.init(itemID: "a", delta: -3, change: .shrink)),
            .apply(.init(itemID: "b", delta: -5, change: .shrink)),
        ])
        #expect(application == expected)
        #expect(application?.corrections.map(\.itemID) == ["a", "b"])
        #expect(ordering.deferred.isEmpty)
        #expect(secondApplication == nil)
    }

    @Test func decelerationAppliesOnlyAfterItEnds() {
        var ordering = TimelinePullDeferOrdering()
        ordering.beginDrag()
        _ = ordering.heightChange(itemID: "a", delta: -5, hasCachedHeight: true)
        let duringDeceleration = ordering.endDrag(willDecelerate: true)
        let afterDeceleration = ordering.endDeceleration()
        let secondDeceleration = ordering.endDeceleration()
        #expect(duringDeceleration == nil)
        #expect(afterDeceleration?.effects.first == .settlePull)
        #expect(secondDeceleration == nil)
    }

    @Test func concurrentStreamingGrowthStillCancelsThePull() {
        // The ordering type deliberately does not change the pull's own
        // threshold: a >2pt content-height change during the gesture cancels
        // it, exactly like the SwiftUI path today.
        var pull = TimelineHistoryPull(edge: .older)
        let origin = makeViewport(contentHeight: 2000, containerHeight: 600, offsetY: 100)
        pull.begin(at: origin, promptVisible: true, canLoad: true)
        pull.update(makeViewport(contentHeight: 2003, containerHeight: 600, offsetY: 130))
        let ready = pull.isReady
        let ended = pull.end()
        #expect(!ready)
        #expect(ended == false)
    }

    @Test func cancellationDropsParkedCorrections() {
        var ordering = TimelinePullDeferOrdering()
        ordering.beginDrag()
        _ = ordering.heightChange(itemID: "a", delta: -5, hasCachedHeight: true)
        ordering.cancel()
        #expect(ordering.phase == .idle)
        #expect(ordering.deferred.isEmpty)
    }
}

@Suite struct TimelineLayoutInvariantTests {
    @Test func staleHeightKeysAndOutstandingOwedAreReported() {
        let cache = TimelineHeightCache()
        let old = heightKey(revision: 1)
        cache.setCurrentKey(old)
        var owed = TimelineInsertionOwed(generation: 1, origin: layout(), offsetY: 0, topInset: 0)
        owed.update(layout: layout(first: "earlier", y: 100))
        let violations = TimelineLayoutInvariants.violations(
            cache: cache, expectedKeys: ["g:a": heightKey(revision: 2)], owed: owed)
        #expect(violations.contains("stale-height-key:g:a"))
        #expect(violations.contains("owed-outstanding-after-finalize"))

        cache.setCurrentKey(heightKey(revision: 2))
        owed.clear()
        #expect(TimelineLayoutInvariants.violations(
            cache: cache, expectedKeys: ["g:a": heightKey(revision: 2)], owed: owed).isEmpty)
    }
}
