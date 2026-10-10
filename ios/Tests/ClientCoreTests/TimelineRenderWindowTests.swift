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
        // clamped into the new list rather than jumping to the tail.
        window.adopt(units(290, height: 60))
        #expect(window.frame.startRowIndex == min(startRows, 290 - 1))
        #expect(window.frame.hiddenRowCount + window.frame.renderedRowCount == 290)
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
