import Foundation
import Testing
@testable import ClientCore

/// The timeline's on-device decision log: the ring's cap and order, the
/// transcript's one-line-per-event shape, and the facade's two disciplines —
/// free while it is off, appending while it is on. Self-contained, so the
/// same file runs in the Linux shadow sandbox.
@Suite struct TimelineDiagnosticsTests {
    @Test func theRingKeepsTheNewestEntriesWithinItsCap() {
        var buffer = TimelineDiagBuffer(capacity: 4)
        for index in 0..<10 {
            buffer.append(.prependLanding(addedRows: index, presentedRows: 100), at: Double(index))
        }
        #expect(buffer.events.count == 4, "a storm cannot grow the log past its cap")
        #expect(buffer.events.map(\.id) == [7, 8, 9, 10], "the head drops; the sequence keeps counting")
        #expect(buffer.events.first?.at == 6 && buffer.events.last?.at == 9, "oldest first")
    }

    @Test func theTranscriptIsOneLinePerEventOldestFirst() {
        var buffer = TimelineDiagBuffer(capacity: 10)
        buffer.append(.gateRefused(item: "historyLoadInFlight", phase: "decelerating"), at: 1.5)
        buffer.append(.plannedMove(move: "expand", units: 14, estimatedHeight: 2380, measuredHeight: 0), at: 2)
        let lines = buffer.formatted().split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines[0] == "1.500 gate refused: historyLoadInFlight (decelerating)")
        #expect(lines[1] == "2.000 move: expand 14 units, est 2380.0pt measured 0.0pt",
            "the measured half is the block's bake coverage — the next log's question")
    }

    @Test func everyKindFormatsTheFieldsItCarries() {
        var buffer = TimelineDiagBuffer(capacity: 20)
        buffer.append(.correction(anchor: "u12", delta: -32.5, targetOffset: 4820, phase: "tracking", wrote: false), at: 3)
        buffer.append(.materialized(id: "u12", estimated: 170, measured: 302.5), at: 4)
        buffer.append(.prependLanding(addedRows: 27, presentedRows: 412), at: 5)
        buffer.append(.sliceChange(startRowIndex: 118, boundary: "u12", renderedUnits: 43, spacerHeight: 9440), at: 6)
        let lines = buffer.formatted().split(separator: "\n").map(String.init)
        #expect(lines[0] == "3.000 correct: u12 Δ−32.5 → 4820.0 (tracking) absorbed")
        #expect(lines[1] == "4.000 measured: u12 est 170.0 vs 302.5 Δ+132.5")
        #expect(lines[2] == "5.000 prepend: +27 rows (presented 412)")
        #expect(lines[3] == "6.000 slice: start=118 boundary=u12 rendered=43 spacer=9440.0")
        // A slice with no boundary (empty window) still reads.
        buffer.removeAll()
        buffer.append(.sliceChange(startRowIndex: 0, boundary: nil, renderedUnits: 0, spacerHeight: 0), at: 7)
        #expect(buffer.formatted().hasSuffix("slice: start=0 boundary=- rendered=0 spacer=0.0"))
    }

    @Test func clearEmptiesTheRingAndKeepsTheSequence() {
        var buffer = TimelineDiagBuffer(capacity: 8)
        buffer.append(.plannedMove(move: "shrink", units: 3, estimatedHeight: 240, measuredHeight: 240), at: 1)
        buffer.removeAll()
        #expect(buffer.isEmpty && buffer.formatted().isEmpty)
        buffer.append(.plannedMove(move: "expand", units: 1, estimatedHeight: 80, measuredHeight: 0), at: 2)
        #expect(buffer.events.map(\.id) == [2], "clearing does not rewind the ids")
    }

    /// Off (the default — no stored switch, no env override): a record call
    /// evaluates nothing, so not one payload field is built on the hot path.
    @Test @MainActor func theFacadeDropsEverythingWhileTheLogIsOff() {
        let diag = TimelineDiag.shared
        diag.refresh()
        guard !diag.isEnabled else { return } // AA_TIMELINE_DIAG=1 makes this vacuous
        diag.record(.sliceChange(startRowIndex: 9, boundary: "x", renderedUnits: 1, spacerHeight: 1))
        #expect(diag.snapshot().isEmpty)
        #expect(diag.formatted().isEmpty)
        #expect(!diag.isCollecting)
    }

    @Test @MainActor func theFacadeAppendsFormatsAndClearsWhileTheLogIsOn() {
        let diag = TimelineDiag.shared
        UserDefaults.standard.set(true, forKey: TimelineDiag.enabledKey)
        diag.refresh()
        defer {
            UserDefaults.standard.set(false, forKey: TimelineDiag.enabledKey)
            diag.refresh()
        }
        guard diag.isCollecting else { return } // an env override can only force it on
        diag.record(.correction(anchor: "u7", delta: 12.5, targetOffset: 900, phase: "idle", wrote: true))
        #expect(diag.snapshot().contains { $0.kind == .correction(anchor: "u7", delta: 12.5,
            targetOffset: 900, phase: "idle", wrote: true) })
        #expect(diag.formatted().contains("correct: u7 Δ+12.5 → 900.0 (idle) wrote"))
        diag.clear()
        #expect(diag.snapshot().isEmpty)
    }
}
