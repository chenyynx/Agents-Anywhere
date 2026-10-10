import Foundation
import Testing
@testable import ClientCore

/// The windowed timeline's render-set math (P2 §P2 对策A): tail window,
/// expand/shrink hysteresis, spacer arithmetic, and the net-zero-displacement
/// invariant of a boundary move. Self-contained (no fixtures) so the same
/// file runs in the Linux shadow sandbox.
@Suite struct TimelineRenderWindowTests {
    private func unit(_ id: String, rows: Int = 1, height: CGFloat, measured: Bool = false) -> TimelineRenderUnit {
        TimelineRenderUnit(id: id, rowCount: rows, height: height, isMeasured: measured)
    }

    private func units(_ count: Int, rows: Int = 1, height: CGFloat, prefix: String = "u") -> [TimelineRenderUnit] {
        (0..<count).map { unit("\(prefix)\($0)", rows: rows, height: height) }
    }

    private func viewport(offset: CGFloat, height: CGFloat = 700, inset: CGFloat = 80) -> TimelineViewport {
        TimelineViewport(contentHeight: 40_000, containerHeight: height + inset + 120,
            topInset: inset, bottomInset: 120, offsetY: offset)
    }

    private func sample(offset: CGFloat, windowTop: CGFloat, height: CGFloat = 700) -> TimelineWindowSample {
        TimelineWindowSample(viewport: viewport(offset: offset, height: height), windowTop: windowTop)
    }

    // MARK: cold open

    @Test func coldOpenRendersTheTailExactlyAndHidesEverythingOlder() {
        var window = TimelineRenderWindow()
        window.adopt(units(3000, height: 60))
        let frame = window.frame
        // The tail is exact: the window ends at the newest unit…
        #expect(frame.renderedRowCount == 3000 - frame.hiddenRowCount)
        #expect(frame.startRowIndex == frame.hiddenRowCount)
        // …the budget is covered by whole units…
        #expect(frame.renderedRowCount >= TimelineRenderWindow.initialWindowRows)
        #expect(frame.renderedRowCount <= TimelineRenderWindow.initialWindowRows + 1)
        // …and the spacer claims the hidden arithmetic exactly, not "some" height.
        let hiddenHeight = CGFloat(frame.hiddenRowCount) * 60
        #expect(frame.spacerHeight == hiddenHeight + 20 * CGFloat(frame.hiddenRowCount) - 20)
        #expect(window.firstUnitID == "u\(frame.startRowIndex)")
    }

    @Test func shortSessionsStayFullyRendered() {
        var window = TimelineRenderWindow()
        window.adopt(units(12, height: 60))
        #expect(window.frame.spacerHeight == 0)
        #expect(window.frame.startRowIndex == 0)
        #expect(window.move(sample: sample(offset: 0, windowTop: 20)) == .none)
    }

    // MARK: boundary math and hysteresis

    @Test func expansionFiresNearTheWindowTopAndShrinksOnlyFarBelow() {
        var window = TimelineRenderWindow()
        window.adopt(units(600, height: 60))
        let screen: CGFloat = 700
        let windowTop: CGFloat = 5000
        // Rendered content above the viewport: 3 screens → dead zone.
        #expect(window.move(sample: sample(offset: windowTop + 3 * screen - 80, windowTop: windowTop)) == .none)
        // Closing to 1.4 screens → expand.
        #expect(window.move(sample: sample(offset: windowTop + 1.4 * screen - 80, windowTop: windowTop)) == .expand)
        // Six screens below → shrink.
        #expect(window.move(sample: sample(offset: windowTop + 6 * screen - 80, windowTop: windowTop)) == .shrink)
        // At the very top with the viewport above the boundary → expand.
        #expect(window.move(sample: sample(offset: windowTop - 2 * screen, windowTop: windowTop)) == .expand)
    }

    @Test func aSettledShrinkCannotImmediatelyReexpand() {
        var window = TimelineRenderWindow()
        window.adopt(units(600, height: 60))
        let screen: CGFloat = 700
        let windowTop: CGFloat = 5000
        let far = sample(offset: windowTop + 6 * screen - 80, windowTop: windowTop)
        let released = window.shrink(sample: far)
        #expect(released > 0)
        // Content below the boundary did not move, so the next window top (the
        // new first unit's y) sits exactly one released block lower…
        let releasedHeight = CGFloat(released) * (60 + TimelineRenderWindow.unitSpacing)
        let newTop = windowTop + releasedHeight
        // …which puts the reader in the stable band: no expand, no shrink.
        let settled = sample(offset: windowTop + 6 * screen - 80, windowTop: newTop)
        #expect(settled.above > TimelineRenderWindow.expandOverscanScreens * screen)
        #expect(window.move(sample: settled) == .none, "above = \(settled.above / screen) screens")
    }

    @Test func expansionIsBoundedByRowsAndByHeight() {
        // Heavy units: the height budget stops the block after a few units.
        var heavy = TimelineRenderWindow()
        heavy.adopt(units(400, height: 300))
        let movedHeavy = heavy.expand(sample: sample(offset: 0, windowTop: 0))
        #expect(movedHeavy > 0)
        #expect(movedHeavy <= Int((TimelineRenderWindow.expandBlockScreens * 700) / (300 + 20)) + 1)
        // Light units: the height budget still bounds the block, and the row
        // budget is the hard ceiling.
        var light = TimelineRenderWindow()
        light.adopt(units(400, height: 10))
        let movedLight = light.expand(sample: sample(offset: 0, windowTop: 0))
        #expect(movedLight > 0)
        #expect(movedLight <= TimelineRenderWindow.moveBlockRows)
        let lightHeight = CGFloat(movedLight) * (10 + TimelineRenderWindow.unitSpacing)
        #expect(lightHeight <= TimelineRenderWindow.expandBlockScreens * 700 + 30)
    }

    @Test func shrinkRefusesWhenTheFirstUnitAloneWouldEatTheOverscan() {
        var window = TimelineRenderWindow()
        // Put the huge unit exactly at the window's top boundary.
        window.adopt(units(140, height: 60) + [unit("huge", height: 4000)] + units(159, height: 60, prefix: "v"))
        #expect(window.firstUnitID == "huge")
        // The reader is below the shrink margin, so a shrink is considered…
        let windowTop: CGFloat = 5000
        let far = sample(offset: windowTop + 4.5 * 700 - 80, windowTop: windowTop)
        #expect(window.move(sample: far) == .none,
            "A shrink that would leave under two screens above is refused outright")
        // …but releasing "huge" would leave less than two screens rendered above.
        let released = window.shrink(sample: far)
        #expect(released == 0)
        #expect(window.firstUnitID == "huge")
    }

    @Test func rendersBoundedRegardlessOfTotalRowsAtTheBottom() {
        for total in [500, 3000] {
            var window = TimelineRenderWindow()
            window.adopt(units(total, height: 60))
            // Settle at the bottom: the reader rests at the tail (one screen of
            // visible height inside the rendered region) and shrinks converge
            // on the stable band.
            for _ in 0..<40 {
                let frame = window.frame
                let renderedHeight = CGFloat(frame.renderedRowCount) * 80
                let windowTop: CGFloat = 1000 + frame.spacerHeight + 20
                let offset = windowTop + (renderedHeight - 700) - 80
                let s = sample(offset: offset, windowTop: windowTop)
                switch window.move(sample: s) {
                case .shrink: _ = window.shrink(sample: s)
                case .expand: Issue.record("The bottom never expands")
                case .none: break
                }
            }
            let frame = window.frame
            #expect(frame.renderedRowCount <= 120, "rendered rows must not scale with the total (\(total))")
            #expect(frame.renderedRowCount >= 20)
            // The window is a suffix: everything below the boundary is rendered.
            #expect(frame.hiddenRowCount + frame.renderedRowCount == total)
        }
    }

    // MARK: the raw row basis — grouping skips rows (F1)

    /// A timeline row with no fixture dependency: grouping reads only the
    /// structure projection, and `parentItemId` alone makes a row a SubAgent
    /// child — present in `rows`, never a group of its own.
    @MainActor private func row(_ id: String, childOf parent: String? = nil) throws -> ChatTimelineRowModel {
        var object: [String: Any] = ["id": id, "sessionId": "session",
            "type": "message", "status": "done", "content": ["text": "hello"]]
        if let parent { object["content"] = ["text": "child of \(parent)", "parentItemId": parent] }
        return ChatTimelineRowModel(try JSONDecoder().decode(V2TimelineItem.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    /// `rows = [A, a1, B, b1, b2, C, c1, D]`: the child rows enter the data
    /// (live frames and recovery are unfiltered) but grouping skips them, so
    /// the grouped rows behind the boundary at C (2) is *not* C's raw index (5).
    /// Slicing `rows` on the grouped count started the list at B — the boundary
    /// unit then sat inside the spacer's claimed height *and* rendered.
    @Test @MainActor func frameStartsAtTheBoundaryUnitsRawRowIndexWhenGroupingSkipsRows() throws {
        let rows = try [row("A"), row("a1", childOf: "A"), row("B"), row("b1", childOf: "B"),
            row("b2", childOf: "B"), row("C"), row("c1", childOf: "C"), row("D")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        #expect(groups.map(\.id) == ["A", "B", "C", "D"])
        let rawStarts = TimelineGrouping.rawStartIndices(in: rows, for: groups)
        #expect(rawStarts == [0, 2, 5, 7])
        let units = zip(groups, rawStarts).map { pair in
            TimelineRenderUnit(id: pair.0.id, rowCount: pair.0.rows.count, height: 60,
                isMeasured: false, rawStartRowIndex: pair.1)
        }
        var window = TimelineRenderWindow()
        window.adopt(units, defaultRowBudget: 2) // the two newest units → boundary at C
        let frame = window.frame
        #expect(window.firstUnitID == "C")
        #expect(frame.startRowIndex == 5, "the raw index of C, not the 2 grouped rows behind the spacer")
        // The informational counters keep their grouped-row semantics.
        #expect(frame.hiddenRowCount == 2 && frame.renderedRowCount == 2)
        // What the view does with the frame: slice the raw rows on it and
        // re-group. The first group of that suffix must be the store's own
        // first rendered unit, and the whole suffix must be the units from the
        // boundary down — nothing re-rendered from inside the spacer.
        let sliced = TimelineGrouping.groups(Array(rows[frame.startRowIndex...]), interactionTargets: [])
        #expect(sliced.first?.id == window.firstUnitID)
        #expect(sliced.map(\.id) == ["C", "D"])
    }

    /// The slice lands on the first rendered unit with skipped rows only above
    /// the boundary (A, D), only below it (A), and on both sides of it (B).
    @Test @MainActor func theSliceStartsWithTheFirstRenderedUnitWithSkipsOnEitherSideOfTheBoundary() throws {
        let rows = try [row("A"), row("a1", childOf: "A"), row("B"), row("b1", childOf: "B"),
            row("b2", childOf: "B"), row("C"), row("c1", childOf: "C"), row("D")]
        let groups = TimelineGrouping.groups(rows, interactionTargets: [])
        let units = zip(groups, TimelineGrouping.rawStartIndices(in: rows, for: groups)).map { pair in
            TimelineRenderUnit(id: pair.0.id, rowCount: pair.0.rows.count, height: 60,
                isMeasured: false, rawStartRowIndex: pair.1)
        }
        // (tail budget, expected first unit, its raw row index).
        for (budget, first, raw) in [(4, "A", 0), (3, "B", 2), (1, "D", 7)] {
            var window = TimelineRenderWindow()
            window.adopt(units, defaultRowBudget: budget)
            let frame = window.frame
            #expect(window.firstUnitID == first, "budget \(budget)")
            #expect(frame.startRowIndex == raw, "raw index of \(first)")
            let sliced = TimelineGrouping.groups(Array(rows[frame.startRowIndex...]), interactionTargets: [])
            let from = try #require(groups.firstIndex { $0.id == first })
            #expect(sliced.first?.id == window.firstUnitID)
            #expect(sliced.map(\.id) == groups[from...].map(\.id))
        }
    }

    // MARK: the render set's membership gate (L1/L2)

    /// Only the rendered suffix is a valid source of reported frames: a late
    /// report from a unit the window released would hand the anchor a dead y
    /// and bake a stale height into the next move's spacer arithmetic.
    @Test func onlyTheRenderedSuffixAcceptsReportedFrames() {
        var window = TimelineRenderWindow()
        window.adopt(units(300, height: 60))
        let start = window.start
        #expect(start > 1)
        let boundary = window.units[start].id
        let above = window.units[start - 1].id
        #expect(window.isRendered(boundary), "the boundary unit keeps reporting")
        #expect(!window.isRendered(above), "the unit above it lives behind the spacer")
        #expect(!window.isRendered("ghost"))
        // Materialising the top block moves it into the set…
        #expect(window.expand(sample: sample(offset: 0, windowTop: 0)) > 0)
        #expect(window.isRendered(above))
        // …and releasing it again takes it straight back out — once the block
        // has reported its measurements (round 3: an unmeasured expansion
        // guards itself against the shrink that restarts the limit cycle).
        // Whatever the released units report from here on is stale.
        let measured = Dictionary(uniqueKeysWithValues:
            window.units[window.start...].map { ($0.id, $0.height) })
        window.applyMeasuredHeights(measured)
        #expect(window.shrink(sample: sample(offset: 60_000, windowTop: 5_000)) > 0)
        #expect(!window.isRendered(above))
    }

    // MARK: round 3 — the estimator's blast radius (on-device log, 2026-10-10)

    /// A pre-layout frame reports height 0: baking it made every Δ a jump
    /// against zero, and the real layout wrote the correction back 35 ms
    /// later — the log's double jump (`est 529.1 vs 0.0` → `Δ−583.1 wrote` →
    /// `Δ−52.1 wrote`). Neither the bake path nor a frame may accept a
    /// non-positive height.
    @Test func nonPositiveHeightsAreNeverBaked() {
        var window = TimelineRenderWindow()
        window.adopt(units(300, height: 60))
        let start = window.start
        var heights: [String: CGFloat] = [:]
        heights[window.units[start].id] = 0
        heights[window.units[start + 1].id] = -12
        heights[window.units[start + 2].id] = 64
        window.applyMeasuredHeights(heights)
        #expect(window.units[start].height == 60 && !window.units[start].isMeasured,
            "a zero frame is not a measurement")
        #expect(window.units[start + 1].height == 60 && !window.units[start + 1].isMeasured)
        #expect(window.units[start + 2].height == 64 && window.units[start + 2].isMeasured,
            "a real one still lands")
    }

    /// The log's three-second limit cycle: an expansion materialised five
    /// units whose inflated estimates kept the band inside expand range, so
    /// the shrink released them and the next sample expanded them again. A
    /// materialised block stays until it reports its measurement.
    @Test func anExpandedBlockStaysUntilItMeasures() {
        var window = TimelineRenderWindow()
        window.adopt(units(600, height: 60))
        let expandTrigger = sample(offset: 0, windowTop: 0)
        #expect(window.move(sample: expandTrigger) == .expand)
        let moved = window.expand(sample: expandTrigger)
        #expect(moved > 0)
        #expect(!window.guardedUnmeasured.isEmpty, "the block guards itself until it measures")
        // Far below the boundary a shrink is due — but not at the block that
        // has not reported yet: that is the cycle.
        let shrinkTrigger = sample(offset: 20_000, windowTop: 0)
        #expect(window.shrinkableCount(sample: shrinkTrigger) == 0)
        // Once every rendered unit reports, the band is free again.
        let measured = Dictionary(uniqueKeysWithValues:
            window.units[window.start...].map { ($0.id, $0.height) })
        window.applyMeasuredHeights(measured)
        #expect(window.guardedUnmeasured.isEmpty)
        #expect(window.shrinkableCount(sample: shrinkTrigger) > 0)
    }

    /// The floor under the hysteresis band: the return-to-bottom storm cut
    /// the set to a single row (rendered=1, spacer=39 452) because the band
    /// is drawn in estimated points. However far below the reader sits, a
    /// shrink leaves at least `minRenderedUnits` and `minRenderedScreens`.
    @Test func aShrinkNeverLeavesTheRenderSetBelowTheFloor() {
        var window = TimelineRenderWindow()
        window.adopt(units(3000, height: 60))
        let measured = Dictionary(uniqueKeysWithValues:
            window.units[window.start...].map { ($0.id, $0.height) })
        window.applyMeasuredHeights(measured)
        let far = sample(offset: 60_000, windowTop: 0)
        for _ in 0..<200 {
            guard window.shrinkableCount(sample: far) > 0 else { break }
            window.shrink(sample: far)
        }
        #expect(window.renderedUnitCount >= TimelineRenderWindow.minRenderedUnits)
        let renderedHeight = window.units[window.start...].reduce(CGFloat(0)) { $0 + $1.height }
        #expect(renderedHeight >= TimelineRenderWindow.minRenderedScreens * far.viewport.visibleHeight,
            "the floor is drawn in real points, not in the estimator's currency")
    }

    // MARK: the move gate (F3, round 2)

    /// A sample may judge (and commit) a window move while nothing but the
    /// reader owns the viewport. The reader's gesture is deliberately *not* on
    /// the list (round 2): refusing an expand mid-gesture left the history
    /// ahead of them unmaterialised, so their drag or fling ran into the top
    /// spacer — one screen of blank, then a jump when the gesture ended (device
    /// regression, 2026-10-10). What a commit arms — the anchor's point
    /// correction — is graded at its write site instead.
    @Test func theWindowMoveGateRefusesEveryOwnerExceptTheReadersGesture() {
        #expect(TimelineWindowMoveGate().allows, "nothing but the reader owns the viewport")
        #expect(!TimelineWindowMoveGate(windowingEnabled: false).allows)
        #expect(!TimelineWindowMoveGate(openingSettled: false).allows)
        #expect(!TimelineWindowMoveGate(navigationSuspended: true).allows)
        #expect(!TimelineWindowMoveGate(moveSettling: true).allows)
        #expect(!TimelineWindowMoveGate(historySettling: true).allows)
        #expect(!TimelineWindowMoveGate(historyLoadInFlight: true).allows)
        #expect(!TimelineWindowMoveGate(bottomCommandInFlight: true).allows)
        #expect(!TimelineWindowMoveGate(keyboardDrivingLayout: true).allows)
    }

    /// A refusal names the member that closed the gate — the diagnostics
    /// window shows exactly which owner held the move back.
    @Test func theGateNamesTheMemberThatRefused() {
        #expect(TimelineWindowMoveGate().refusal == nil)
        #expect(TimelineWindowMoveGate(historyLoadInFlight: true).refusal == .historyLoadInFlight)
        #expect(TimelineWindowMoveGate(keyboardDrivingLayout: true).refusal == .keyboardDrivingLayout)
        #expect(TimelineWindowMoveGate(windowingEnabled: false, moveSettling: true).refusal == .windowingEnabled,
            "the list is checked in order, first refusal wins")
    }

    /// The correction write is graded by who owns the offset, not gated away
    /// from the move itself: the residual the anchor removes (real height minus
    /// estimate) is invisible under a gesture, a correction under a finger does
    /// not end the drag, and a point target always stops a fling.
    @Test func theAnchorWritePolicyGradesTheCorrectionByWhoOwnsTheOffset() {
        let tolerance = TimelineAnchorWritePolicy.gestureTolerance
        #expect(TimelineAnchorWritePolicy.action(delta: 0.6, phase: .idle) == .write,
            "nothing owns the offset: this is the correction the anchor exists for")
        #expect(TimelineAnchorWritePolicy.action(delta: 130, phase: .idle) == .write)
        #expect(TimelineAnchorWritePolicy.action(delta: 130, phase: .animating) == .write)
        for phase in [TimelineScrollState.Phase.tracking, .interacting] {
            #expect(TimelineAnchorWritePolicy.action(delta: tolerance, phase: phase) == .absorb,
                "layout noise under a held finger is not worth a write")
            #expect(TimelineAnchorWritePolicy.action(delta: tolerance + 0.5, phase: phase) == .write)
            #expect(TimelineAnchorWritePolicy.action(delta: -tolerance - 0.5, phase: phase) == .write)
        }
        #expect(TimelineAnchorWritePolicy.action(delta: tolerance + 400, phase: .decelerating) == .absorb,
            "a point target stops the fling; a residual that rode the flight costs nothing at rest")
    }

    // MARK: the content's equatable seam (F2)

    /// A committed window move publishes only through `windowMoveRevision`:
    /// the store object is the very same object across the commit. The seam
    /// has to read as unequal then — otherwise SwiftUI skips the body,
    /// `frame()` never re-runs and the rendered slice never moves.
    @Test func aCommittedWindowMoveBreaksTheContentsEquatableSeam() {
        let atRest = ChatTimelineContentInputs(windowEnabled: true, windowMoveRevision: 0)
        let committed = ChatTimelineContentInputs(windowEnabled: true, windowMoveRevision: 1)
        #expect(atRest != committed, "the move revision alone must break equality")
        #expect(atRest == ChatTimelineContentInputs(windowEnabled: true, windowMoveRevision: 0))
        // The rest of the seam still compares by value.
        #expect(atRest != ChatTimelineContentInputs(keepsOlderPrompt: true, windowEnabled: true, windowMoveRevision: 0))
        #expect(atRest != ChatTimelineContentInputs(queueRoster: "q1", windowEnabled: true, windowMoveRevision: 0))
        #expect(atRest != ChatTimelineContentInputs(windowEnabled: false, windowMoveRevision: 0))
    }

    // MARK: data changes

    @Test func adoptingAPrependMovesThePagesIntoTheSpacerWithoutGrowingTheRenderSet() {
        var window = TimelineRenderWindow()
        window.adopt(units(300, height: 60))
        let before = window.frame
        // A backfill page prepends 150 older units above everything.
        let older = (0..<150).map { unit("p\($0)", height: 60) }
        window.adopt(older + units(300, height: 60).map { unit($0.id, rows: $0.rowCount, height: $0.height) })
        let after = window.frame
        #expect(after.renderedRowCount == before.renderedRowCount, "a prepend never grows the render set")
        #expect(window.firstUnitID == before.firstUnitID)
        #expect(after.hiddenRowCount == before.hiddenRowCount + 150)
        #expect(after.spacerHeight > before.spacerHeight)
    }

    @Test func adoptingClampsWhenTheBoundaryUnitVanished() {
        var window = TimelineRenderWindow()
        window.adopt(units(300, height: 60))
        let startRows = window.frame.startRowIndex
        // The boundary group was merged away by a regroup: the old index is
        // clamped into the new list rather than jumping to the tail — it still
        // sits at or past the tail floor, so the reader keeps their place.
        let merged = units(290, height: 60).filter { $0.id != "u140" }
        window.adopt(merged)
        #expect(window.frame.startRowIndex == min(startRows, merged.count - 1))
        #expect(window.frame.hiddenRowCount + window.frame.renderedRowCount == merged.count)
    }

    /// A vanished boundary while a large prepend lands: clamping alone pins the
    /// boundary at its old index, and the window is a suffix that ends at the
    /// newest unit — that mid-list window renders everything between the pin
    /// and the tail, growing with the history until the reader next falls below
    /// the shrink margin. The tail floor is the bounded outcome.
    @Test func adoptingAFallenBoundaryFallsBackToTheTailWindow() throws {
        var window = TimelineRenderWindow()
        window.adopt(units(3000, height: 60))
        let fallen = try #require(window.firstUnitID)
        // 5000 older units land while a regroup drops the boundary unit.
        let older = (0..<5000).map { unit("p\($0)", height: 60) }
        window.adopt(older + units(3000, height: 60).filter { $0.id != fallen })
        let floor = TimelineRenderWindow.tailStart(in: window.units,
            rowBudget: TimelineRenderWindow.initialWindowRows)
        #expect(window.start == floor, "the clamp never leaves the window above the tail floor")
        #expect(window.renderedUnitCount == TimelineRenderWindow.initialWindowRows)
        #expect(window.renderedUnitCount < window.units.count, "and never scales with the history")
    }

    @Test func summaryAndFrameCountersAgree() {
        var window = TimelineRenderWindow()
        window.adopt((0..<40).map { unit("u\($0)", rows: $0 % 3 + 1, height: 50) })
        let frame = window.frame
        let totalRows = (0..<40).reduce(0) { $0 + ($1 % 3 + 1) }
        #expect(frame.hiddenRowCount + frame.renderedRowCount == totalRows)
        #expect(window.renderedUnitCount + window.hiddenUnitCount == 40)
    }

    // MARK: spacer arithmetic — the net-displacement invariant

    /// Content y of unit `i` in the windowed world, mirroring the view's
    /// VStack: [leading][spacer][spacing][units…]. The leading block stands in
    /// for the older-prompt child above the spacer.
    private func windowedY(_ units: [TimelineRenderUnit], start: Int, spacer: CGFloat, upTo index: Int) -> CGFloat {
        var y: CGFloat = 200 + spacer + TimelineRenderWindow.unitSpacing
        for j in start..<index { y += units[j].height + TimelineRenderWindow.unitSpacing }
        return y
    }

    /// Expanding with measured == estimate moves nothing; any estimate error
    /// shows up as exactly the delta the anchor correction removes.
    @Test func expansionDisplacementEqualsTheEstimateErrorAndIsCorrectedToZero() {
        var window = TimelineRenderWindow()
        window.adopt(units(400, height: 60))
        let start = window.frame.startRowIndex
        let before = window.frame
        // A unit well inside the rendered set is the anchor.
        let anchorIndex = start + 5
        let yBefore = windowedY(window.units, start: start, spacer: before.spacerHeight, upTo: anchorIndex)
        let moved = window.expand(sample: sample(offset: 0, windowTop: 0))
        #expect(moved > 0)
        let after = window.frame
        // The real layout of the materialized block turns out 8pt/unit taller
        // than the estimate.
        var real = window.units
        for j in after.startRowIndex..<start { real[j].height = 68 }
        let yAfter = windowedY(real, start: after.startRowIndex, spacer: after.spacerHeight, upTo: anchorIndex)
        let displacement = yAfter - yBefore
        #expect(displacement == CGFloat(moved) * 8)
        // The anchor correction removes exactly that displacement…
        var anchor = TimelineHistoryPosition(
            id: 1,
            layout: TimelineHistoryLayout(firstRowID: "data", renderFirstRowID: "u\(start)",
                anchorRowID: window.units[anchorIndex].id, edge: .top, y: yBefore),
            offsetY: 5000, topInset: 80, signal: .renderWindow)
        let corrected = anchor.laidOut(
            TimelineHistoryLayout(firstRowID: "data", renderFirstRowID: window.firstUnitID ?? "",
                anchorRowID: window.units[anchorIndex].id, edge: .top, y: yAfter),
            generation: 1)
        #expect(corrected == 5000 + displacement)
        // …so the anchor's on-screen position is invariant: net displacement 0.
        #expect(yAfter - (corrected ?? 0) == yBefore - 5000)
    }

    /// Shrinking gives the spacer each released unit's *measured* height, so
    /// everything below the window top stays exactly where it was — no
    /// correction needed at all.
    @Test func shrinkDisplacementIsZeroWhenMeasuredHeightsAreBaked() {
        var window = TimelineRenderWindow()
        window.adopt(units(400, height: 60))
        let start = window.frame.startRowIndex
        let before = window.frame
        // The reader has scrolled far below; the top block is fully measured.
        let measured: [String: CGFloat] = Dictionary(uniqueKeysWithValues:
            window.units[start...].prefix(30).map { ($0.id, $0.height) })
        window.applyMeasuredHeights(measured)
        let windowTop: CGFloat = 5000
        let far = sample(offset: windowTop + 8 * 700, windowTop: windowTop)
        // The anchor is the post-move first unit: it survives the release and
        // is the reader's fixed point through it.
        let boundary = start + window.shrinkableCount(sample: far)
        let yBefore = windowedY(window.units, start: start, spacer: before.spacerHeight, upTo: boundary)
        let released = window.shrink(sample: far)
        #expect(released > 0)
        let after = window.frame
        #expect(after.startRowIndex == boundary)
        let yAfter = windowedY(window.units, start: after.startRowIndex, spacer: after.spacerHeight, upTo: boundary)
        #expect(yAfter == yBefore, "the released contribution is exactly what the spacer gained")
    }
}
