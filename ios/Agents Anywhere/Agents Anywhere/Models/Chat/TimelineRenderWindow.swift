import Foundation

/// One rendered unit of the windowed timeline: a whole `ChatTimelineGroup`
/// (or a single row) taken from `tl.timeline.rows`, with the height the model
/// currently believes it contributes to the content.
///
/// `height` is the view's own frame height — the same quantity the group's
/// `onGeometryChange` writes back when it renders. Estimates stand in until a
/// unit has been measured; once measured, the value is the recorded truth.
nonisolated struct TimelineRenderUnit: Equatable {
    /// The unit's first row id (the group's identity in the timeline).
    let id: String
    /// How many data rows the unit covers.
    let rowCount: Int
    /// Content height in points (measured truth or coarse estimate).
    var height: CGFloat
    /// Whether `height` came from a real layout pass rather than the estimator.
    var isMeasured: Bool
    /// Index of this unit's first row in the raw `rows` array — the basis the
    /// view slices on. Grouping skips rows (SubAgent child rows never form a
    /// group), so this is *not* the running sum of the units' `rowCount`: only
    /// the raw index lands the slice on this unit's first row, which is what
    /// keeps `groups(rows[slice…])` equal to the units from the boundary down.
    /// Nil for hand-built units (tests) — `frame` then falls back to the
    /// grouped hidden count, the same index exactly when nothing was skipped.
    var rawStartRowIndex: Int? = nil
}

/// One measured rendered unit: the frame the group reported in the timeline's
/// content coordinate space (`chat.timeline.content`).
nonisolated struct TimelineWindowUnitMeasurement: Equatable {
    let id: String
    let y: CGFloat
    let height: CGFloat
}

/// The geometry of the rendered window handed to the view: which data row the
/// window starts at, what the spacer above it must claim, and the ids the
/// anchor bookkeeping keys on.
nonisolated struct TimelineWindowFrame: Equatable {
    /// Index into `model.timeline.rows` of the first rendered row: the raw
    /// row index of the first rendered unit (not a count of the rows behind
    /// the spacer — grouping skips rows, so the two only coincide when
    /// nothing was skipped). Slicing `rows` anywhere else starts the rendered
    /// list mid-history and charges the spacer for units it then renders.
    let startRowIndex: Int
    /// The first rendered unit's id (nil when there are no rows at all).
    let firstUnitID: String?
    /// The top spacer's height in points (0 when nothing is hidden).
    let spacerHeight: CGFloat
    let hiddenRowCount: Int
    let renderedRowCount: Int
}

/// A geometry sample and the measured top of the rendered window, in the
/// timeline content's coordinate space. `above` is the rendered content the
/// reader still has between the viewport's top edge and the window's top edge.
nonisolated struct TimelineWindowSample: Equatable {
    let viewport: TimelineViewport
    let windowTop: CGFloat

    /// Points of rendered content above the viewport's top edge. Negative when
    /// the viewport has been pushed above the window's top (the reader is
    /// looking at the spacer region before an expansion lands).
    var above: CGFloat { viewport.offsetY + viewport.topInset - windowTop }
}

/// The value half of `ChatTimelineContent`'s `.equatable()` seam: every input
/// the content compares by value (the chat model and the window store are
/// compared by identity; the closures are not compared at all). Held as one
/// value so the seam is unit-testable — and because it is what carries a
/// committed render-window move across SwiftUI's skip: the store object is the
/// same object before and after a commit, only its `moveRevision` moves, so
/// without that revision in an equated value the body reads as unchanged,
/// `frame()` never re-runs and the rendered slice never moves.
nonisolated struct ChatTimelineContentInputs: Equatable {
    var latestPullReady = false
    var isLoadingLatest = false
    var olderPullReady = false
    var isLoadingOlder = false
    var keepsOlderPrompt = false
    var historyAnchor: TimelineHistoryLayout? = nil
    var queueRoster = ""
    var windowEnabled = false
    /// The window store's committed-move revision (F2): the only value a
    /// window move publishes through this seam.
    var windowMoveRevision = 0
}

/// The render-window move's guard list as one value: a geometry sample may
/// judge (and commit) a move only while nothing else owns the viewport. Pure,
/// so the list is named at the call site and each condition is pinnable.
///
/// The reader's own gesture is deliberately **not** a member (round 2). The
/// window is what keeps the history ahead of the reader materialised: refusing
/// an expand while their finger or fling is moving let them scroll straight
/// into the top spacer — the whole unloaded history collapses into that one
/// blank block (device regression, 2026-10-10). A move during a gesture is
/// legal; what it arms — the anchor's point correction — is graded where it is
/// written (see `TimelineAnchorWritePolicy`).
nonisolated struct TimelineWindowMoveGate {
    /// The §7 feature flag (`AA_TIMELINE_WINDOW=0` renders the full list).
    var windowingEnabled = true
    /// The opening's own positioning has settled; before that its instant
    /// return owns the page.
    var openingSettled = true
    /// A drawer transition owns the page.
    var navigationSuspended = false
    /// A previous window move is still settling.
    var moveSettling = false
    /// A history page's anchor is still settling.
    var historySettling = false
    /// A history load is in flight — its landing rewrites the page.
    var historyLoadInFlight = false
    /// A bottom command owns the viewport.
    var bottomCommandInFlight = false
    /// The keyboard drives the layout.
    var keyboardDrivingLayout = false

    /// Which member closed the gate (nil = the sample may judge a move). The
    /// name is what the diagnostics window shows, so a refused move on device
    /// says which owner held it back instead of "nothing happened".
    enum Refusal: String, Equatable {
        case windowingEnabled, openingSettled, navigationSuspended, moveSettling
        case historySettling, historyLoadInFlight, bottomCommandInFlight, keyboardDrivingLayout
    }

    var refusal: Refusal? {
        if !windowingEnabled { return .windowingEnabled }
        if !openingSettled { return .openingSettled }
        if navigationSuspended { return .navigationSuspended }
        if moveSettling { return .moveSettling }
        if historySettling { return .historySettling }
        if historyLoadInFlight { return .historyLoadInFlight }
        if bottomCommandInFlight { return .bottomCommandInFlight }
        if keyboardDrivingLayout { return .keyboardDrivingLayout }
        return nil
    }

    var allows: Bool { refusal == nil }
}

/// Whether the window anchor's point correction may touch the offset while a
/// move settles. The correction's displacement (`Δ` = the anchor's new
/// measured y minus its armed y) is the height model's residual error: zero
/// once every unit in the move has been measured (`heights` /
/// `measuredHeights` carry the truth forward), non-zero only for units
/// materialising for the first time (see `TimelineUnitHeightEstimator`).
///
/// Round 2: a move may commit while the reader scrolls (the gate no longer
/// refuses their gesture), so the write it arms has to respect whoever holds
/// the offset:
///
/// - nothing owns it → write. This is the correction the anchor exists for,
///   unchanged from before the gesture gate existed.
/// - a finger is down → a point write does not end a `UIScrollView` drag, and
///   text sitting displaced under a held finger is the visible failure, so a
///   Δ above the tolerance is corrected; a smaller one is noise.
/// - the fling is running → never write: a point target always stops the
///   deceleration, and acceptance is "the fling is not truncated". A Δ that
///   rides the flight is motion-masked and its resting cost is nil — the page
///   is an absolute offset away from a framing nobody can observe.
nonisolated enum TimelineAnchorWritePolicy {
    enum Action: Equatable { case write, absorb }

    /// Displacements at or below this many points are invisible under a
    /// gesture, so they are absorbed instead of written. Grounding: layout
    /// rounding and font-metric noise sit at 1–2 pt (the anchor's own dedup
    /// already drops ≤ 0.5 pt), while a virgin unit's estimator residual is
    /// tens to hundreds of points — the two populations are far apart, and
    /// this line keeps the common case (every previously measured unit) a
    /// no-op under the reader's hand.
    static let gestureTolerance: CGFloat = 8

    static func action(delta: CGFloat, phase: TimelineScrollState.Phase) -> Action {
        switch phase {
        case .idle, .animating:
            return .write
        case .tracking, .interacting:
            return abs(delta) <= gestureTolerance ? .absorb : .write
        case .decelerating:
            return .absorb
        }
    }
}

/// The render set of the windowed timeline (task sheet §P2 对策A): the data
/// stays fully in memory, while the view renders only a suffix of the data —
/// the tail window — and represents everything older with one spacer on top.
///
/// The window always ends at the newest unit (the tail sentinels, status line
/// and queue ride below the rendered groups and must stay inside the rendered
/// region). Only the top boundary moves:
///
/// - the reader approaching the window's top expands it upward in blocks, so
///   the spacer region is (re)materialized well before it becomes visible;
/// - the reader moving far below the window's top releases the far-top units
///   back into the spacer.
///
/// Both moves are anchored by the existing `TimelineHistoryPosition` machine
/// (see `Signal.renderWindow`): the spacer gives back exactly the estimates
/// that were charged to it, the real layout supplies the difference, and the
/// anchor correction pin the reader in place — the net displacement is zero.
///
/// Spacer accounting: in the fully rendered list the distance from the
/// timeline's first child to the top of unit `i` is `Σ (h_j + spacing)` over
/// the units before it (the VStack adds one gap per child). With `T` hidden
/// units the spacer and its own surrounding gaps must reproduce that distance
/// exactly, so `spacerHeight = Σ (h_j + spacing) - spacing`.
nonisolated struct TimelineRenderWindow: Equatable {
    /// The timeline content's `VStack(spacing:)`. Kept here so the spacer
    /// arithmetic and the view cannot drift apart.
    static let unitSpacing: CGFloat = 20
    /// Cold open: render at least this many rows at the tail.
    static let initialWindowRows = 160
    /// One expand/shrink move covers at most this many rows…
    static let moveBlockRows = 100
    /// …and an expansion stops early once it has added this much height, so a
    /// post-move correction stays proportional to what the reader can see.
    static let expandBlockScreens: CGFloat = 2
    /// Expand while less than this many screens of rendered content remain
    /// above the viewport.
    static let expandOverscanScreens: CGFloat = 1.5
    /// Shrink once rendered content above the viewport exceeds this many
    /// screens…
    static let shrinkMarginScreens: CGFloat = 4
    /// …but never release a unit that would leave less than this many screens
    /// above the viewport. The gap between this and `expandOverscanScreens` is
    /// the hysteresis: a settled shrink cannot immediately re-expand.
    static let shrinkKeepScreens: CGFloat = 2
    /// The render set's floor — the fuse under the hysteresis band. Both bars
    /// are drawn in points the *reader* can see, not in the estimator's
    /// currency: a poisoned estimate can walk the band down to a single row
    /// (the on-device log's return-to-bottom storm: seven cuts in 300 ms,
    /// rendered=1, spacer=39 452). A shrink may never take the set below
    /// either bar, whatever `above` claims.
    static let minRenderedUnits = 20
    static let minRenderedScreens: CGFloat = 1.5

    enum Move: Equatable {
        case expand
        case shrink
        case none
    }

    private(set) var units: [TimelineRenderUnit] = []
    /// Index of the first rendered unit; everything before it is hidden
    /// behind the spacer.
    private(set) var start = 0
    /// Σ (height + spacing) over the hidden units, maintained incrementally.
    private(set) var hiddenContribution: CGFloat = 0
    /// Units the latest expansions materialised that have not reported a
    /// measurement yet. Releasing them would hide the very block whose
    /// estimate is still inflating `above`, and the next sample would expand
    /// the same units again — the log's three-second expand/shrink limit
    /// cycle (five units, 862.7 pt estimates, over and over). A materialised
    /// unit is rendered, and the layout its own expansion caused reports its
    /// frame within a frame or two, so "until measured" is bounded in
    /// practice; until then the window keeps the block. Ids leave the set
    /// when they measure or when a rebuild drops them.
    private(set) var guardedUnmeasured: Set<String> = []

    var isEmpty: Bool { units.isEmpty }
    var firstUnitID: String? { units.indices.contains(start) ? units[start].id : nil }
    var hiddenUnitCount: Int { start }
    var renderedUnitCount: Int { max(0, units.count - start) }

    /// The spacer that stands in for every hidden unit.
    var spacerHeight: CGFloat {
        guard start > 0 else { return 0 }
        return max(0, hiddenContribution - Self.unitSpacing)
    }

    var frame: TimelineWindowFrame {
        var hidden = 0
        for unit in units[..<min(start, units.count)] { hidden += unit.rowCount }
        var rendered = 0
        for unit in units[min(start, units.count)...] { rendered += unit.rowCount }
        // The slice basis is the boundary unit's own first row: the view cuts
        // `rows` here, and re-grouping that suffix must yield exactly the
        // rendered units. Units built without a raw start fall back to the
        // grouped hidden count — identical only when grouping skipped nothing.
        let boundary = units.indices.contains(start) ? units[start].rawStartRowIndex : nil
        return TimelineWindowFrame(
            startRowIndex: boundary ?? hidden,
            firstUnitID: firstUnitID,
            spacerHeight: spacerHeight,
            hiddenRowCount: hidden,
            renderedRowCount: rendered)
    }

    /// Whether `id` belongs to the current render set. A frame reported for
    /// anything else is stale — the unit was released by a shrink, or left by
    /// a rebind — and must feed neither the anchor correction nor the height
    /// caches the next move bakes from.
    func isRendered(_ id: String) -> Bool {
        guard !units.isEmpty else { return false }
        return units[min(start, units.count)...].contains { $0.id == id }
    }

    /// Rebuilds the unit list for a data change while preserving the rendered
    /// set: the boundary sticks to its unit id, so a prepend of history pages
    /// moves into the spacer instead of growing the render set. Falls back to
    /// the default tail window on the first bind and when the boundary unit
    /// vanished (a regroup merged or dropped it).
    mutating func adopt(_ newUnits: [TimelineRenderUnit], defaultRowBudget: Int = TimelineRenderWindow.initialWindowRows) {
        let previousFirstID = firstUnitID
        units = newUnits
        if let previousFirstID, let index = newUnits.firstIndex(where: { $0.id == previousFirstID }) {
            start = index
        } else if previousFirstID != nil {
            // The boundary unit was merged away or dropped: clamp the old index
            // into the new list, then apply the tail window's own floor. The
            // clamp alone can pin the boundary far above the tail while the
            // history grows below it — the window is a suffix that always ends
            // at the newest unit, so that mid-list window renders every unit
            // between the pinned index and the tail and grows with the data
            // until the reader happens to fall below the shrink margin (and
            // nothing re-asserts them either: this path bumps no revision).
            // The floor is the bounded outcome: the reader lands on the tail.
            let clamped = min(max(0, start), max(0, newUnits.count - 1))
            start = max(clamped, Self.tailStart(in: newUnits, rowBudget: defaultRowBudget))
        } else {
            start = Self.tailStart(in: newUnits, rowBudget: defaultRowBudget)
        }
        // A rebuild is a new unit list: guards of units that no longer exist
        // would block a shrink for nothing.
        guardedUnmeasured.formIntersection(newUnits.lazy.map(\.id))
        rebuildHiddenContribution()
    }

    /// The tail-anchored default: walk up from the end until the budget is
    /// covered, taking whole units.
    static func tailStart(in units: [TimelineRenderUnit], rowBudget: Int) -> Int {
        var index = units.count
        var rows = 0
        while index > 0, rows < rowBudget {
            index -= 1
            rows += units[index].rowCount
        }
        return index
    }

    /// Applies measured heights to rendered units before a move is planned or
    /// executed: the shrink arithmetic must give the spacer the heights the
    /// rows actually occupied, not the estimates they replaced. A non-positive
    /// height is not a measurement — it is a pre-layout frame (the log's
    /// `vs 0.0` rows, whose Δ then wrote a jump 35 ms before the real layout
    /// arrived) — so it is refused rather than baked.
    mutating func applyMeasuredHeights(_ heights: [String: CGFloat]) {
        guard !heights.isEmpty else { return }
        for index in start..<units.count {
            if let height = heights[units[index].id], height > 0 {
                units[index].height = height
                units[index].isMeasured = true
                guardedUnmeasured.remove(units[index].id)
            }
        }
    }

    /// The expand/shrink decision for one geometry sample. Pure — the view
    /// evaluates it per frame and writes state only when a move is due.
    func move(sample: TimelineWindowSample) -> Move {
        guard sample.viewport.isMeasured, !units.isEmpty else { return .none }
        let screen = sample.viewport.visibleHeight
        if start > 0, sample.above < Self.expandOverscanScreens * screen {
            return .expand
        }
        if sample.above > Self.shrinkMarginScreens * screen,
           shrinkableCount(sample: sample) > 0 {
            return .shrink
        }
        return .none
    }

    /// How many top units a shrink would release right now (0 = refused).
    /// Whole units move, never a partial group.
    func shrinkableCount(sample: TimelineWindowSample) -> Int {
        guard sample.viewport.isMeasured, start < units.count else { return 0 }
        let screen = sample.viewport.visibleHeight
        let keep = Self.shrinkKeepScreens * screen
        let floorHeight = Self.minRenderedScreens * screen
        var remainingHeight: CGFloat = 0
        for index in start..<units.count { remainingHeight += units[index].height + Self.unitSpacing }
        var index = start
        var rows = 0
        var released: CGFloat = 0
        var count = 0
        while index < units.count, rows < Self.moveBlockRows {
            // A block the last expansion materialised stays until it measures:
            // releasing it puts the inflated estimate straight back on top,
            // and the next sample expands the same units again.
            guard !guardedUnmeasured.contains(units[index].id) else { break }
            let next = released + units[index].height + Self.unitSpacing
            guard sample.above - next >= keep else { break }
            // The floor: whatever would stay rendered clears both bars — a
            // unit count and a measured height, never the estimator's points.
            let after = remainingHeight - (units[index].height + Self.unitSpacing)
            guard units.count - (index + 1) >= Self.minRenderedUnits, after >= floorHeight else { break }
            released = next
            remainingHeight = after
            rows += units[index].rowCount
            index += 1
            count += 1
        }
        return count
    }

    /// Materializes the top block: whole units until the row budget or the
    /// height budget is reached, at least one. Returns the unit count moved
    /// out of the spacer (0 when nothing is hidden).
    mutating func expand(sample: TimelineWindowSample) -> Int {
        guard start > 0 else { return 0 }
        let heightBudget = Self.expandBlockScreens * sample.viewport.visibleHeight
        var index = start
        var rows = 0
        var height: CGFloat = 0
        while index > 0, rows < Self.moveBlockRows, height < heightBudget {
            index -= 1
            rows += units[index].rowCount
            height += units[index].height + Self.unitSpacing
        }
        let count = start - index
        guard count > 0 else { return 0 }
        // The block just materialised guards itself until it measures (see
        // `guardedUnmeasured`): an unmeasured shrink would put its estimate
        // straight back on top and expand it again next sample.
        let materialized = (index..<start).filter { !units[$0].isMeasured }.map { units[$0].id }
        guardedUnmeasured.formUnion(materialized)
        // The reader is corrected by the difference between these estimates
        // and the real layout; the spacer gives back exactly what it charged.
        hiddenContribution -= contribution(of: index..<start)
        start = index
        return count
    }

    /// Releases the top block back into the spacer. Returns the unit count
    /// hidden (0 when the move is refused: releasing would eat the overscan).
    mutating func shrink(sample: TimelineWindowSample) -> Int {
        let count = shrinkableCount(sample: sample)
        guard count > 0 else { return 0 }
        let given = min(start + count, units.count)
        hiddenContribution += contribution(of: start..<given)
        start = given
        return count
    }

    private func contribution(of range: Range<Int>) -> CGFloat {
        var total: CGFloat = 0
        for unit in units[range] { total += unit.height + Self.unitSpacing }
        return total
    }

    private mutating func rebuildHiddenContribution() {
        hiddenContribution = contribution(of: 0..<min(start, units.count))
    }
}
