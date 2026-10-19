import Foundation
import QuartzCore
import UIKit

/// In-app auto-run probe for the 6b spike.
///
/// Launch the app with the `aa-spike-autorun` argument (CI uses `simctl launch`).
/// The scenario drives the same controls a human would tap, then writes every
/// counter and measurement to `Documents/spike-autorun.json`. Nothing here
/// ships: the whole `Spike/` directory is deleted after the experiment.
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

        // Initial layout: viewDidLoad already applied the 1000 items.
        await settle(0.8)
        cv.layoutIfNeeded()
        await settle(0.2)

        // ---- 1. Prepend 100 while the top of the list is visible ----
        let beforePrepend = anchor(in: cv, layout: layout)
        let target0 = model.targetOffsetCalls
        let prepare0 = model.prepareForUpdatesCalls
        let finalize0 = model.finalizeUpdatesCalls

        model.prepend()
        controller.sync()
        await waitForApply(controller)
        await settle(0.4)
        cv.layoutIfNeeded()
        let afterPrepend = anchor(in: cv, layout: layout, id: beforePrepend.id)

        report["prepend"] = [
            "anchorID": beforePrepend.id,
            "anchorScreenYBefore": num(beforePrepend.screenY),
            "anchorScreenYAfter": num(afterPrepend.screenY),
            // ~0 means the reader's viewport did not move. A large positive
            // value means the content shifted by the prepended height.
            "anchorScreenDeltaY": num(afterPrepend.screenY - beforePrepend.screenY),
            "contentHeightBefore": num(beforePrepend.contentHeight),
            "contentHeightAfter": num(afterPrepend.contentHeight),
            "targetOffsetCalls": model.targetOffsetCalls - target0,
            "prepareForUpdatesCalls": model.prepareForUpdatesCalls - prepare0,
            "finalizeUpdatesCalls": model.finalizeUpdatesCalls - finalize0,
            "owed": num(model.lastOwed),
            "proposed": num(model.lastProposedOffset),
            "returned": num(model.lastReturnedOffset),
            "layoutAnchorBeforeY": num(model.anchorBeforeY),
            "layoutAnchorAfterY": num(model.anchorAfterY),
        ]

        // ---- 2. Append 100 below the viewport ----
        model.append()
        controller.sync()
        await waitForApply(controller)
        await settle(0.3)
        cv.layoutIfNeeded()
        let afterAppend = anchor(in: cv, layout: layout, id: beforePrepend.id)
        report["append"] = [
            "anchorScreenDeltaY": num(afterAppend.screenY - afterPrepend.screenY),
            "contentHeightBefore": num(afterPrepend.contentHeight),
            "contentHeightAfter": num(afterAppend.contentHeight),
        ]

        // ---- 3. Jump to the bottom from the top ----
        // Reproduces the reported "回底有一点没到底": the offset is computed
        // from estimated heights; cells that come into view then self-size.
        controller.performScroll(.bottomInstant)
        await settle(0.8)
        cv.layoutIfNeeded()
        report["bottomInstantFromTop"] = bottomMetrics(in: cv)

        // ---- 4. Streaming while the tail row is visible ----
        // `append()` moved the tail; target the current last row. The content
        // ends there, so sitting at the bottom keeps that row fully visible.
        // Otherwise its cell is never materialized and self-sizing cannot be
        // exercised at all.
        let streamID = model.items.last?.id
        model.streamingItemID = streamID
        let inset = cv.adjustedContentInset
        let maxOffset = max(-inset.top, cv.contentSize.height - cv.bounds.height + inset.bottom)
        cv.setContentOffset(CGPoint(x: 0, y: maxOffset), animated: false)
        await settle(0.4)
        cv.layoutIfNeeded()

        let should0 = model.shouldInvalidateCalls
        let invalidation0 = model.invalidationContextCalls
        let reconfigure0 = model.reconfigureCount
        let streamHeightBefore = streamID.flatMap { layout.measuredHeight(of: $0) }
        let streamContentBefore = cv.contentSize.height
        let visibleRect = CGRect(origin: cv.contentOffset, size: cv.bounds.size)
        let streamVisible: Bool = {
            guard let streamID,
                  let index = layout.itemIDs.firstIndex(of: streamID),
                  let attributes = layout.layoutAttributesForItem(at: IndexPath(item: index, section: 0))
            else { return false }
            return attributes.frame.intersects(visibleRect)
        }()

        var tickMillis: [Double] = []
        for _ in 0..<10 {
            let start = CACurrentMediaTime()
            model.growStreamingItem()
            controller.sync()
            await waitForApply(controller)
            cv.layoutIfNeeded()
            tickMillis.append((CACurrentMediaTime() - start) * 1000)
            await settle(0.12)
        }

        let streamHeightAfter = streamID.flatMap { layout.measuredHeight(of: $0) }
        report["streaming"] = [
            "ticks": tickMillis.count,
            "streamingItemVisible": streamVisible,
            "shouldInvalidateCalls": model.shouldInvalidateCalls - should0,
            "invalidationContextCalls": model.invalidationContextCalls - invalidation0,
            "reconfigureCount": model.reconfigureCount - reconfigure0,
            "contentHeightBefore": num(streamContentBefore),
            "contentHeightAfter": num(cv.contentSize.height),
            "streamingItemMeasuredHeightBefore": streamHeightBefore.map { num($0) } ?? NSNull(),
            "streamingItemMeasuredHeightAfter": streamHeightAfter.map { num($0) } ?? NSNull(),
            "tickMillisMax": tickMillis.max().map { ($0 * 100).rounded() / 100 } ?? 0,
            "tickMillisAvg": tickMillis.isEmpty ? 0 : ((tickMillis.reduce(0, +) / Double(tickMillis.count)) * 100).rounded() / 100,
            "note": "Simulator numbers are a lower bound; device cost is higher.",
        ]

        // ---- 5. Animated bottom after the content grew ----
        let didEnd0 = model.didEndScrollingAnimationCalls
        controller.performScroll(.bottomAnimated)
        await waitForDidEndScrollingAnimation(controller, baseline: didEnd0, timeout: 4)
        await settle(0.8)
        cv.layoutIfNeeded()
        var animated = bottomMetrics(in: cv)
        animated["didEndScrollingAnimationCalls"] = model.didEndScrollingAnimationCalls - didEnd0
        report["bottomAnimated"] = animated

        // Let self-sizing settle once more. A growing shortfall means the
        // target offset was computed from estimates that no longer hold.
        await settle(0.8)
        cv.layoutIfNeeded()
        report["bottomAnimatedAfterSettle"] = bottomMetrics(in: cv)

        // ---- 6. Instant bottom as a control ----
        controller.performScroll(.bottomInstant)
        await settle(0.5)
        cv.layoutIfNeeded()
        report["bottomInstantAfterSettle"] = bottomMetrics(in: cv)

        report["counters"] = [
            "targetOffsetCalls": model.targetOffsetCalls,
            "prepareForUpdatesCalls": model.prepareForUpdatesCalls,
            "finalizeUpdatesCalls": model.finalizeUpdatesCalls,
            "invalidationContextCalls": model.invalidationContextCalls,
            "shouldInvalidateCalls": model.shouldInvalidateCalls,
            "didEndScrollingAnimationCalls": model.didEndScrollingAnimationCalls,
            "reconfigureCount": model.reconfigureCount,
            "streamTicks": model.streamTicks,
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

    private static func bottomMetrics(in cv: UICollectionView) -> [String: Any] {
        let inset = cv.adjustedContentInset
        let maxOffset = max(-inset.top, cv.contentSize.height - cv.bounds.height + inset.bottom)
        return [
            "contentHeight": num(cv.contentSize.height),
            "offsetY": num(cv.contentOffset.y),
            "maxOffsetY": num(maxOffset),
            // Positive = the reader is short of the bottom.
            "shortfall": num(maxOffset - cv.contentOffset.y),
        ]
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

    private static func waitForDidEndScrollingAnimation(
        _ controller: SpikeCollectionController,
        baseline: Int,
        timeout: TimeInterval
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while controller.model.didEndScrollingAnimationCalls == baseline, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
