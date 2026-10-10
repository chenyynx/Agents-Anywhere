import Foundation
import Observation

/// The windowed timeline's view-side store (P2 对策A), moved here from
/// ChatTimelineView.swift: the view file had grown past the type checker's
/// budget (round 4), and this class compiles cleanest with its own.
///
@MainActor @Observable final class TimelineWindowStore {
    struct PlannedWindowMove {
        let move: TimelineRenderWindow.Move
        let sample: TimelineWindowSample
        /// The unit that stays rendered across the move: the current first
        /// unit for an expansion, the post-move first unit for a shrink.
        let anchorUnitID: String
        /// Its pre-move content y — the correction's origin.
        let anchorY: CGFloat
        /// The pre-move render-window first unit (the signal origin).
        let renderFirstUnitID: String
    }

    private(set) var moveRevision = 0
    /// The render window's first unit right now (nil before the first bind).
    var resolvedFirstUnitID: String? { lastFrame.firstUnitID }
    /// Whether `id` is in the current render set: the gate every reported
    /// frame passes before it may touch the store (L1/L2).
    func isRendered(_ id: String) -> Bool { window.isRendered(id) }
    /// The last measured content-y of a rendered unit — the "before" an
    /// in-place data-window correction arms against (round 4: a prepend's
    /// displacement is priced where it happens, not left to accumulate).
    func lastMeasuredY(of id: String) -> CGFloat? { measurements[id]?.y }

    @ObservationIgnored private var window = TimelineRenderWindow()
    @ObservationIgnored private var heights = TimelineUnitHeightCache()
    /// The frames of the currently rendered units (y is meaningful only while
    /// the unit is rendered — pruned at every move).
    @ObservationIgnored private var measurements: [String: TimelineWindowUnitMeasurement] = [:]
    /// The rendered units' current heights, the bake source for a move.
    @ObservationIgnored private var measuredHeights: [String: CGFloat] = [:]
    @ObservationIgnored private var facts: [String: TimelineUnitHeightFacts] = [:]
    @ObservationIgnored private var lastFrame = TimelineWindowFrame(
        startRowIndex: 0, firstUnitID: nil, spacerHeight: 0, hiddenRowCount: 0, renderedRowCount: 0)
    /// The units an expand just materialised, keyed by their estimate — the
    /// diagnostics log shows their first measurement against it. Only filled
    /// while the log collects, so the hot path never pays for it.
    @ObservationIgnored private var materializing: [String: CGFloat] = [:]
    @ObservationIgnored private var signature: Signature?
    @ObservationIgnored private var lastWidthKey = 0
    @ObservationIgnored private var lastTypeScaleKey = 0

    private struct Signature: Equatable {
        let revision: Int
        let targets: String
        let width: Int
        let typeScale: Int
    }

    /// Resolves the rendered slice for the content body. Rebuilds the unit
    /// list only when the data membership, the interaction targets or the
    /// geometry keys change — never per token flush.
    func frame(rows: [ChatTimelineRowModel], revision: Int, interactionTargets: Set<String>,
               width: CGFloat, typeScaleKey: Int, typeScale: CGFloat,
               disclosures: TimelineDisclosureState) -> TimelineWindowFrame {
        _ = moveRevision // Observation hook: a committed move re-renders the slice.
        let widthKey = Int(width.rounded())
        let next = Signature(revision: revision, targets: interactionTargets.sorted().joined(separator: ","),
            width: widthKey, typeScale: typeScaleKey)
        if next != signature {
            rebuild(rows: rows, interactionTargets: interactionTargets, width: width,
                widthKey: widthKey, typeScaleKey: typeScaleKey, typeScale: typeScale, disclosures: disclosures)
            signature = next
        }
        return lastFrame
    }

    /// Records one rendered unit's frame: the measured-truth cache for the
    /// height model, the current-height bake source for moves, and the y the
    /// anchor correction reads while a move settles. Frames of units outside
    /// the render set are dropped — their y stopped being meaningful when they
    /// left, and a released unit's stale height must never be baked into the
    /// next move's spacer arithmetic.
    func recordUnitFrame(_ measurement: TimelineWindowUnitMeasurement) {
        guard window.isRendered(measurement.id) else { return }
        // A non-positive frame is a pre-layout report, not a measurement: the
        // log's `vs 0.0` rows baked it, computed a Δ against zero and wrote a
        // jump — then wrote it back 35 ms later when the real layout landed.
        // Refusing it collapses the double jump into the single correction.
        guard measurement.height > 0 else { return }
        // Diagnostics: the first measurement of a unit an expand just
        // materialised is the height model's residual for it.
        if let estimated = materializing.removeValue(forKey: measurement.id) {
            TimelineDiag.record(.materialized(id: measurement.id, estimated: estimated,
                measured: measurement.height))
        }
        measurements[measurement.id] = measurement
        measuredHeights[measurement.id] = measurement.height
        guard let unitFacts = facts[measurement.id] else { return }
        heights.record(measurement.height, for: TimelineUnitHeightKey(id: measurement.id,
            width: lastWidthKey, typeScale: lastTypeScaleKey,
            isCollapsed: unitFacts.isCollapsed, isStreaming: unitFacts.isStreaming))
    }

    /// Judges the window and prepares everything a move's anchor needs, from
    /// the pre-move state. Pure with respect to view state (cache writes
    /// only): the caller commits or drops the plan.
    func planMove(viewport: TimelineViewport) -> PlannedWindowMove? {
        guard let first = lastFrame.firstUnitID, let top = measurements[first] else { return nil }
        // The shrink arithmetic must give the spacer the heights the rendered
        // rows actually occupied, not the estimates they replaced — with
        // measured truth a shrink's displacement is zero by construction.
        window.applyMeasuredHeights(measuredHeights)
        let sample = TimelineWindowSample(viewport: viewport, windowTop: top.y)
        switch window.move(sample: sample) {
        case .none:
            return nil
        case .expand:
            // The new block materializes above the current first unit: that
            // unit survives the move and is the correction's anchor.
            return PlannedWindowMove(move: .expand, sample: sample,
                anchorUnitID: first, anchorY: top.y, renderFirstUnitID: first)
        case .shrink:
            let count = window.shrinkableCount(sample: sample)
            guard count > 0, window.start + count < window.units.count else { return nil }
            let anchorID = window.units[window.start + count].id
            guard let anchor = measurements[anchorID] else { return nil }
            return PlannedWindowMove(move: .shrink, sample: sample,
                anchorUnitID: anchorID, anchorY: anchor.y, renderFirstUnitID: first)
        }
    }

    /// Applies a planned move and publishes it. Measurements of units that
    /// just left the render set are pruned — their y stops being meaningful,
    /// and a stale y must never stand in for a fresh report.
    func commit(_ plan: PlannedWindowMove) {
        let startBefore = window.start
        let frameBefore = lastFrame
        let moved: Int
        switch plan.move {
        case .expand: moved = window.expand(sample: plan.sample)
        case .shrink: moved = window.shrink(sample: plan.sample)
        case .none: return
        }
        if moved > 0 {
            // Diagnostics: the block the move just walked, summed the way the
            // spacer accounts for it — and, for an expansion, the estimates
            // whose first measurement will show the residual.
            let range = plan.move == .expand ? window.start..<startBefore : startBefore..<window.start
            let estimated = window.units[range].reduce(CGFloat(0)) { $0 + $1.height + TimelineRenderWindow.unitSpacing }
            let measured = window.units[range].reduce(CGFloat(0)) { $0 + ($1.isMeasured ? $1.height : 0) }
            TimelineDiag.record(.plannedMove(move: plan.move == .expand ? "expand" : "shrink",
                units: moved, estimatedHeight: estimated, measuredHeight: measured))
            if plan.move == .expand, TimelineDiag.isCollecting {
                materializing = Dictionary(uniqueKeysWithValues: window.units[range].map { ($0.id, $0.height) })
            } else {
                materializing = [:]
            }
        }
        lastFrame = window.frame
        noteSliceChange(from: frameBefore)
        let rendered = Set(window.units[window.start...].map(\.id))
        measurements = measurements.filter { rendered.contains($0.key) }
        measuredHeights = measuredHeights.filter { rendered.contains($0.key) }
        moveRevision &+= 1
    }

    /// Diagnostics: records the rendered slice's change — only the two paths
    /// that can move it (a membership rebuild, a committed move) call this, so
    /// a streaming token flush never produces a line.
    private func noteSliceChange(from previous: TimelineWindowFrame) {
        let next = lastFrame
        guard next.startRowIndex != previous.startRowIndex || next.firstUnitID != previous.firstUnitID
            || next.renderedRowCount != previous.renderedRowCount else { return }
        let event = TimelineDiagEvent.Kind.sliceChange(startRowIndex: next.startRowIndex,
            boundary: next.firstUnitID, renderedUnits: window.renderedUnitCount,
            spacerHeight: next.spacerHeight)
        // This note runs inside the content body: writing the log's observed
        // state mid-update is undefined, so the append waits one runloop turn.
        DispatchQueue.main.async { TimelineDiag.record(event) }
    }

    private func rebuild(rows: [ChatTimelineRowModel], interactionTargets: Set<String>, width: CGFloat,
                         widthKey: Int, typeScaleKey: Int, typeScale: CGFloat,
                         disclosures: TimelineDisclosureState) {
        let groups = TimelineGrouping.groups(rows, interactionTargets: interactionTargets)
        // F1: each unit carries its first row's raw index — the basis the
        // content body slices `rows` on. Grouping's own count of the rows
        // behind the boundary is not that index whenever a skipped row (a
        // SubAgent child) sits above it.
        let rawStarts = TimelineGrouping.rawStartIndices(in: rows, for: groups)
        let keysMatch = widthKey == lastWidthKey && typeScaleKey == lastTypeScaleKey
        if !keysMatch {
            // Every recorded or measured height is geometry for another
            // column or type size: retire it and re-estimate.
            measurements.removeAll()
            measuredHeights.removeAll()
        }
        var carried: [String: TimelineRenderUnit] = [:]
        if keysMatch {
            carried.reserveCapacity(window.units.count)
            for unit in window.units { carried[unit.id] = unit }
        }
        var nextFacts: [String: TimelineUnitHeightFacts] = [:]
        var units: [TimelineRenderUnit] = []
        units.reserveCapacity(groups.count)
        nextFacts.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let unitFacts = Self.unitFacts(of: group, disclosures: disclosures)
            nextFacts[group.id] = unitFacts
            var height: CGFloat
            var isMeasured = false
            if let carriedUnit = carried[group.id] {
                height = carriedUnit.height
                isMeasured = carriedUnit.isMeasured
            } else {
                let key = TimelineUnitHeightKey(id: group.id, width: widthKey, typeScale: typeScaleKey,
                    isCollapsed: unitFacts.isCollapsed, isStreaming: unitFacts.isStreaming)
                if let recorded = heights.height(for: key) {
                    height = recorded
                    isMeasured = true
                } else {
                    height = TimelineUnitHeightEstimator.height(unitFacts, width: width, typeScale: typeScale)
                }
            }
            units.append(TimelineRenderUnit(id: group.id, rowCount: group.rows.count,
                height: height, isMeasured: isMeasured,
                rawStartRowIndex: index < rawStarts.count ? rawStarts[index] : nil))
        }
        facts = nextFacts
        lastWidthKey = widthKey
        lastTypeScaleKey = typeScaleKey
        let frameBefore = lastFrame
        window.adopt(units)
        lastFrame = window.frame
        noteSliceChange(from: frameBefore)
    }

    private static func unitFacts(of group: ChatTimelineGroup,
                                  disclosures: TimelineDisclosureState) -> TimelineUnitHeightFacts {
        var textLength = 0
        var attachmentCount = 0
        var isStreaming = false
        for row in group.rows {
            textLength += row.text.count
            if case let .message(message) = row.value.content {
                attachmentCount += message.attachments.count
            }
            if row.structure.isStreamingText { isStreaming = true }
        }
        let multi = group.kind != .single
        // Whether the unit currently renders header-only — the estimator's
        // one question about a fold. A group fold is keyed "group:<id>" by
        // the fold view, not by the group id; a lone message row is the
        // bubble itself and never folds; every other lone row (reasoning,
        // tool details, marker detail) folds under its own id.
        let expanded: Bool
        if multi {
            expanded = disclosures.isExpandedIfKnown("group:\(group.id)")
        } else if case .message = group.rows[0].value.content {
            expanded = true
        } else {
            expanded = disclosures.isExpandedIfKnown(group.id)
        }
        return TimelineUnitHeightFacts(kind: group.kind,
            isCollapsed: !expanded,
            rowCount: group.rows.count, textLength: textLength,
            attachmentCount: attachmentCount, isStreaming: isStreaming)
    }
}
