import Foundation
import QuartzCore
import UIKit

/// In-app auto-run probe for the 6b spike.
///
/// Launch the app with the `aa-spike-autorun` argument (CI uses `simctl launch`).
/// It exercises the real cell shape (`UIHostingConfiguration` + async content),
/// both compensation predicates, an absolute owed target and a pinning bottom
/// target, then writes every counter to `Documents/spike-autorun.json`.
/// Nothing here ships: the whole `Spike/` directory is deleted after the experiment.
@MainActor
enum SpikeAutoRunner {
    static let launchArgument = "aa-spike-autorun"

    private struct Anchor {
        let id: String
        let screenY: CGFloat
        let contentHeight: CGFloat
    }

    static func run(on controller: SpikeCollectionController) async {
        let cv = controller.collectionView!
        let layout = controller.layout!
        let model = controller.model
        var report: [String: Any] = [
            "device": UIDevice.current.name,
            "system": UIDevice.current.systemVersion,
            "viewSize": "\(Int(cv.bounds.width))x\(Int(cv.bounds.height))",
            "startedAt": ISO8601DateFormatter().string(from: Date()),
        ]

        // Top inset exercises the `originOffset = max(-topInset, offsetY)` clamp.
        cv.contentInset.top = 60
        await settle(0.9)
        cv.layoutIfNeeded()
        await settle(0.2)
        report["setup"] = [
            "insetTop": num(cv.adjustedContentInset.top),
            "offsetY": num(cv.contentOffset.y),
        ]

        // ---- 1. Hosting cell: async parse, row partially visible at the top ----
        let asyncID = "item-30"
        model.markAsyncParse(asyncID)
        layout.compensationMode = .aboveOrPartial
        await scrollToPartialTop(controller, itemID: asyncID, above: 20)
        await settle(0.05)
        cv.layoutIfNeeded()
        let asyncRowBefore = anchor(in: cv, layout: layout, id: asyncID)
        let belowID = itemID(after: asyncID, in: layout)
        let belowBefore = belowID.map { anchor(in: cv, layout: layout, id: $0) }
        let asyncFirst = layout.measuredHeight(of: asyncID)
        let shouldA0 = model.shouldInvalidateCalls
        let invalA0 = model.invalidationContextCalls
        let adjA0 = model.adjustmentAppliedCount

        await settle(1.0)
        cv.layoutIfNeeded()
        let asyncRowAfter = anchor(in: cv, layout: layout, id: asyncID)
        let belowAfter = belowID.map { anchor(in: cv, layout: layout, id: $0) }
        let asyncSettled = layout.measuredHeight(of: asyncID)
        if let asyncFirst, let asyncSettled {
            model.recordAsync(first: asyncFirst, settled: asyncSettled)
        }
        report["hostingAsyncPartial"] = [
            "item": asyncID,
            "cellFirstMeasuredHeight": asyncFirst.map { num($0) } ?? NSNull(),
            "cellSettledMeasuredHeight": asyncSettled.map { num($0) } ?? NSNull(),
            "rowScreenYBefore": num(asyncRowBefore.screenY),
            "rowScreenYAfter": num(asyncRowAfter.screenY),
            "belowID": belowID ?? "",
            "belowScreenDeltaY": delta(belowBefore, belowAfter),
            "shouldInvalidateCalls": model.shouldInvalidateCalls - shouldA0,
            "invalidationContextCalls": model.invalidationContextCalls - invalA0,
            "adjustmentAppliedCalls": model.adjustmentAppliedCount - adjA0,
            "compensationMode": layout.compensationMode.rawValue,
        ]

        // ---- 2. Negative control: the old predicate on the same shape ----
        let controlID = "item-60"
        model.markAsyncParse(controlID)
        layout.compensationMode = .fullyAboveOnly
        await scrollToPartialTop(controller, itemID: controlID, above: 20)
        await settle(0.05)
        cv.layoutIfNeeded()
        let controlBelowID = itemID(after: controlID, in: layout)
        let controlBefore = controlBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        let controlFirst = layout.measuredHeight(of: controlID)
        let adjC0 = model.adjustmentAppliedCount

        await settle(1.0)
        cv.layoutIfNeeded()
        let controlAfter = controlBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        report["hostingAsyncFullyAboveOnly"] = [
            "item": controlID,
            "cellFirstMeasuredHeight": controlFirst.map { num($0) } ?? NSNull(),
            "cellSettledMeasuredHeight": layout.measuredHeight(of: controlID).map { num($0) } ?? NSNull(),
            "belowID": controlBelowID ?? "",
            "belowScreenDeltaY": delta(controlBefore, controlAfter),
            "adjustmentAppliedCalls": model.adjustmentAppliedCount - adjC0,
            "compensationMode": layout.compensationMode.rawValue,
        ]
        layout.compensationMode = .aboveOrPartial

        // ---- 3. Prepend at a mid-list position: absolute owed target ----
        let prependAnchor = anchor(in: cv, layout: layout)
        let originOffset = max(-cv.adjustedContentInset.top, cv.contentOffset.y)
        let contentBeforePrepend = cv.contentSize.height
        let target0 = model.targetOffsetCalls
        let prepare0 = model.prepareForUpdatesCalls
        let finalize0 = model.finalizeUpdatesCalls

        model.prepend()
        controller.sync()
        await waitForApply(controller)
        await settle(0.5)
        cv.layoutIfNeeded()
        let afterPrepend = anchor(in: cv, layout: layout, id: prependAnchor.id)

        report["prependMidList"] = [
            "anchorID": prependAnchor.id,
            "originOffset": num(originOffset),
            "anchorScreenYBefore": num(prependAnchor.screenY),
            "anchorScreenYAfter": num(afterPrepend.screenY),
            "anchorScreenDeltaY": num(afterPrepend.screenY - prependAnchor.screenY),
            "owedTarget": num(model.lastOwedTarget),
            "contentHeightBefore": num(contentBeforePrepend),
            "contentHeightAfter": num(cv.contentSize.height),
            "targetOffsetCalls": model.targetOffsetCalls - target0,
            "prepareForUpdatesCalls": model.prepareForUpdatesCalls - prepare0,
            "finalizeUpdatesCalls": model.finalizeUpdatesCalls - finalize0,
            "proposed": num(model.lastProposedOffset),
            "returned": num(model.lastReturnedOffset),
        ]

        // ---- 4. Append below the viewport ----
        let appendAnchorBefore = anchor(in: cv, layout: layout)
        let appendContentBefore = cv.contentSize.height
        model.append()
        controller.sync()
        await waitForApply(controller)
        await settle(0.35)
        cv.layoutIfNeeded()
        let appendAnchorAfter = anchor(in: cv, layout: layout, id: appendAnchorBefore.id)
        report["append"] = [
            "anchorID": appendAnchorBefore.id,
            "anchorScreenDeltaY": num(appendAnchorAfter.screenY - appendAnchorBefore.screenY),
            "contentHeightBefore": num(appendContentBefore),
            "contentHeightAfter": num(cv.contentSize.height),
        ]

        // ---- 5. Partial-visible synchronous growth: so aboveOrPartial ----
        let growID = "item-90"
        await scrollToPartialTop(controller, itemID: growID, above: 20)
        await settle(0.25)
        let growBelowID = itemID(after: growID, in: layout)
        let growBefore = growBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        let growAdj0 = model.adjustmentAppliedCount
        model.growItem(growID, lines: 3)
        controller.sync()
        await waitForApply(controller)
        await settle(0.6)
        cv.layoutIfNeeded()
        let growAfter = growBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        report["partialGrowthAboveOrPartial"] = [
            "item": growID,
            "belowID": growBelowID ?? "",
            "belowScreenDeltaY": delta(growBefore, growAfter),
            "adjustmentAppliedCalls": model.adjustmentAppliedCount - growAdj0,
            "compensationMode": layout.compensationMode.rawValue,
        ]

        // ---- 6. Same growth under the old fullyAboveOnly predicate ----
        let growControlID = "item-110"
        layout.compensationMode = .fullyAboveOnly
        await scrollToPartialTop(controller, itemID: growControlID, above: 20)
        await settle(0.25)
        let growControlBelowID = itemID(after: growControlID, in: layout)
        let growControlBefore = growControlBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        let growControlAdj0 = model.adjustmentAppliedCount
        model.growItem(growControlID, lines: 3)
        controller.sync()
        await waitForApply(controller)
        await settle(0.6)
        cv.layoutIfNeeded()
        let growControlAfter = growControlBelowID.map { anchor(in: cv, layout: layout, id: $0) }
        report["partialGrowthFullyAboveOnly"] = [
            "item": growControlID,
            "belowID": growControlBelowID ?? "",
            "belowScreenDeltaY": delta(growControlBefore, growControlAfter),
            "adjustmentAppliedCalls": model.adjustmentAppliedCount - growControlAdj0,
            "compensationMode": layout.compensationMode.rawValue,
        ]
        layout.compensationMode = .aboveOrPartial

        // ---- 7. Streaming at the bottom with the pinning armed target ----
        let streamID = model.items.last?.id
        model.streamingItemID = streamID
        controller.setArmedBottom(true)
        layout.isPinning = true
        controller.performScroll(.bottomInstant)
        await settle(0.6)
        cv.layoutIfNeeded()
        let streamShould0 = model.shouldInvalidateCalls
        let streamInval0 = model.invalidationContextCalls
        let streamPin0 = model.pinAdjustmentCount
        let streamAdj0 = model.adjustmentAppliedCount
        var shortfalls: [Double] = []

        for _ in 0..<10 {
            model.growStreamingItem()
            controller.sync()
            await waitForApply(controller)
            cv.layoutIfNeeded()
            let metrics = bottomMetrics(in: cv)
            let shortfall = (metrics["shortfall"] as? Double) ?? 0
            shortfalls.append(shortfall)
            model.recordBottomShortfall(CGFloat(shortfall))
            await settle(0.12)
        }
        let afterTicksShortfall = (bottomMetrics(in: cv)["shortfall"] as? Double) ?? 0
        controller.repinIfArmed()
        await settle(0.1)
        cv.layoutIfNeeded()
        let afterRepinShortfall = (bottomMetrics(in: cv)["shortfall"] as? Double) ?? 0

        report["streamingPinned"] = [
            "streamingItemVisible": true,
            "streamingItemMeasuredHeight": streamID.flatMap { layout.measuredHeight(of: $0) }.map { num($0) } ?? NSNull(),
            "shouldInvalidateCalls": model.shouldInvalidateCalls - streamShould0,
            "invalidationContextCalls": model.invalidationContextCalls - streamInval0,
            "pinAdjustmentCalls": model.pinAdjustmentCount - streamPin0,
            "adjustmentAppliedCalls": model.adjustmentAppliedCount - streamAdj0,
            "shortfallMax": shortfalls.max() ?? 0,
            "shortfallAfterTicks": afterTicksShortfall,
            "shortfallAfterRepin": afterRepinShortfall,
            "shortfalls": shortfalls,
        ]
        controller.setArmedBottom(false)
        layout.isPinning = false

        // ---- 8. Animated bottom when already at the bottom (no-op) ----
        let noopDidEnd0 = model.didEndScrollingAnimationCalls
        controller.performScroll(.bottomAnimated)
        await settle(1.5)
        report["bottomAnimatedNoop"] = [
            "didEndScrollingAnimationCalls": model.didEndScrollingAnimationCalls - noopDidEnd0,
            "shortfall": (bottomMetrics(in: cv)["shortfall"] as? Double) ?? 0,
        ]

        // ---- 9. Programmatic interruption of an animated return ----
        controller.performScroll(.top)
        await settle(0.6)
        let interruptDidEnd0 = model.didEndScrollingAnimationCalls
        controller.performScroll(.bottomAnimated)
        await settle(0.1)
        cv.setContentOffset(cv.contentOffset, animated: false)
        await settle(1.0)
        report["bottomAnimatedInterrupted"] = [
            "didEndScrollingAnimationCalls": model.didEndScrollingAnimationCalls - interruptDidEnd0,
            "shortfall": (bottomMetrics(in: cv)["shortfall"] as? Double) ?? 0,
            "note": "programmatic interruption, not a user drag",
        ]

        // ---- 10. Absolute owed is idempotent across queries ----
        layout.debugSetOwedTarget(9140)
        let firstQuery = layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 0, y: 0)).y
        let secondQuery = layout.targetContentOffset(forProposedContentOffset: CGPoint(x: 0, y: 500)).y
        layout.debugSetOwedTarget(nil)
        model.recordOwedDouble(first: firstQuery, second: secondQuery)
        report["owedDoubleQuery"] = [
            "first": num(firstQuery),
            "second": num(secondQuery),
            "same": firstQuery == secondQuery,
        ]

        report["counters"] = [
            "targetOffsetCalls": model.targetOffsetCalls,
            "prepareForUpdatesCalls": model.prepareForUpdatesCalls,
            "finalizeUpdatesCalls": model.finalizeUpdatesCalls,
            "invalidationContextCalls": model.invalidationContextCalls,
            "shouldInvalidateCalls": model.shouldInvalidateCalls,
            "didEndScrollingAnimationCalls": model.didEndScrollingAnimationCalls,
            "reconfigureCount": model.reconfigureCount,
            "streamTicks": model.streamTicks,
            "adjustmentAppliedCount": model.adjustmentAppliedCount,
            "pinAdjustmentCount": model.pinAdjustmentCount,
            "bottomShortfallMax": num(model.bottomShortfallMax),
            "asyncFirstHeight": num(model.asyncFirstHeight),
            "asyncSettledHeight": num(model.asyncSettledHeight),
            "owedDoubleQueryFirst": num(model.owedDoubleQueryFirst),
            "owedDoubleQuerySecond": num(model.owedDoubleQuerySecond),
        ]
        report["drag"] = "not_exercised: simctl cannot synthesize touches; XCUITest would be required"
        report["completed"] = true
        report["finishedAt"] = ISO8601DateFormatter().string(from: Date())

        write(report)
    }

    // MARK: - Measurements

    private static func anchor(
        in cv: UICollectionView,
        layout: SpikeTimelineLayout,
        id preferredID: String? = nil
    ) -> Anchor {
        let id: String
        if let preferredID {
            id = preferredID
        } else if let first = cv.indexPathsForVisibleItems.min(by: { $0.item < $1.item }),
                  first.item < layout.itemIDs.count {
            id = layout.itemIDs[first.item]
        } else {
            id = layout.itemIDs.first ?? ""
        }

        let screenY: CGFloat
        if let index = layout.itemIDs.firstIndex(of: id),
           let attributes = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0)) {
            screenY = attributes.frame.minY - cv.contentOffset.y
        } else {
            screenY = .nan
        }
        return Anchor(id: id, screenY: screenY, contentHeight: cv.contentSize.height)
    }

    private static func itemID(after id: String, in layout: SpikeTimelineLayout) -> String? {
        guard let index = layout.itemIDs.firstIndex(of: id), index + 1 < layout.itemIDs.count else {
            return nil
        }
        return layout.itemIDs[index + 1]
    }

    private static func delta(_ before: Anchor?, _ after: Anchor?) -> Any {
        guard let before, let after else { return NSNull() }
        return num(after.screenY - before.screenY)
    }

    private static func bottomMetrics(in cv: UICollectionView) -> [String: Any] {
        let inset = cv.adjustedContentInset
        let maxOffset = max(-inset.top, cv.contentSize.height - cv.bounds.height + inset.bottom)
        return [
            "contentHeight": num(cv.contentSize.height),
            "offsetY": num(cv.contentOffset.y),
            "maxOffsetY": num(maxOffset),
            "shortfall": num(maxOffset - cv.contentOffset.y),
        ]
    }

    // MARK: - Scrolling

    /// Puts `itemID` partially above the viewport top, re-resolving once after
    /// the first materialization changed the item's measured height.
    private static func scrollToPartialTop(
        _ controller: SpikeCollectionController,
        itemID: String,
        above: CGFloat
    ) async {
        for _ in 0..<2 {
            controller.collectionView.layoutIfNeeded()
            guard let index = controller.layout.itemIDs.firstIndex(of: itemID),
                  let attributes = controller.layout.layoutAttributesForItem(
                    at: IndexPath(item: index, section: 0)
                  ) else { return }
            let inset = controller.collectionView.adjustedContentInset
            let y = max(-inset.top, attributes.frame.minY + above)
            controller.collectionView.setContentOffset(CGPoint(x: 0, y: y), animated: false)
            await settle(0.2)
        }
    }

    // MARK: - Waiting

    private static func waitForApply(
        _ controller: SpikeCollectionController,
        timeout: TimeInterval = 3
    ) async {
        let target = controller.model.generation
        let deadline = Date().addingTimeInterval(timeout)
        while controller.lastGeneration != target, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        controller.collectionView.layoutIfNeeded()
    }

    private static func settle(_ seconds: TimeInterval) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    // MARK: - Output

    private static func num(_ value: CGFloat) -> Any {
        value.isFinite ? Double(value) : NSNull()
    }

    private static func write(_ report: [String: Any]) {
        do {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = directory.appendingPathComponent("spike-autorun.json")
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            print("AUTORUN_RESULT \(String(decoding: data, as: UTF8.self))")
        } catch {
            print("AUTORUN_WRITE_FAILED \(error)")
        }
    }
}
