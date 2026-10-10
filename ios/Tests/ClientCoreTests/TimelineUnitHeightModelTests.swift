import Foundation
import Testing
@testable import ClientCore

/// The windowed timeline's coarse height model: estimates in the right
/// neighbourhood, measured truth keyed by shape. Self-contained so the same
/// file runs in the Linux shadow sandbox.
@Suite struct TimelineUnitHeightModelTests {
    private func facts(kind: ChatTimelineGroup.Kind = .single, collapsed: Bool = false,
                       rows: Int = 1, text: Int = 0, attachments: Int = 0, streaming: Bool = false) -> TimelineUnitHeightFacts {
        TimelineUnitHeightFacts(kind: kind, isCollapsed: collapsed, rowCount: rows,
            textLength: text, attachmentCount: attachments, isStreaming: streaming)
    }

    @Test func messageEstimatesGrowWithTextAndStayInASaneNeighbourhood() {
        let short = TimelineUnitHeightEstimator.height(facts(text: 40), width: 343, typeScale: 1)
        let long = TimelineUnitHeightEstimator.height(facts(text: 4000), width: 343, typeScale: 1)
        #expect(short >= TimelineUnitHeightEstimator.collapsedFold)
        #expect(long > short * 10)
        // ~4000 chars ≈ 100+ lines on a phone width.
        #expect(long > 100 * TimelineUnitHeightEstimator.bodyLine)
        #expect(long < 200 * TimelineUnitHeightEstimator.bodyLine)
    }

    @Test func narrowerColumnsAndLargerTypeEstimateTaller() {
        let narrow = TimelineUnitHeightEstimator.height(facts(text: 2000), width: 260, typeScale: 1)
        let wide = TimelineUnitHeightEstimator.height(facts(text: 2000), width: 700, typeScale: 1)
        #expect(narrow > wide)
        let large = TimelineUnitHeightEstimator.height(facts(text: 2000), width: 343, typeScale: 1.35)
        let small = TimelineUnitHeightEstimator.height(facts(text: 2000), width: 343, typeScale: 0.9)
        #expect(large > small)
    }

    @Test func foldedUnitsUseTheFixedCollapsedHeightUntilExpanded() {
        let collapsed = TimelineUnitHeightEstimator.height(
            facts(kind: .tools, collapsed: true, rows: 300, text: 9000), width: 343, typeScale: 1)
        #expect(collapsed == TimelineUnitHeightEstimator.collapsedFold)
        let expanded = TimelineUnitHeightEstimator.height(
            facts(kind: .tools, collapsed: false, rows: 300, text: 9000), width: 343, typeScale: 1)
        #expect(expanded > collapsed * 10)
    }

    @Test func zeroTextMarkersAreHeaderSized() {
        let marker = TimelineUnitHeightEstimator.height(facts(rows: 1, text: 0), width: 343, typeScale: 1)
        #expect(marker == TimelineUnitHeightEstimator.collapsedFold)
        let withAttachment = TimelineUnitHeightEstimator.height(facts(rows: 1, text: 0, attachments: 1), width: 343, typeScale: 1)
        #expect(withAttachment > marker)
    }

    @Test func cacheKeysDistinguishEveryShapeDimension() {
        var cache = TimelineUnitHeightCache()
        let base = TimelineUnitHeightKey(id: "a", width: 343, typeScale: 0, isCollapsed: true, isStreaming: false)
        cache.record(44, for: base)
        #expect(cache.height(for: base) == 44)
        #expect(cache.count == 1)
        // Every dimension addresses a distinct entry.
        let variants = [
            TimelineUnitHeightKey(id: "b", width: 343, typeScale: 0, isCollapsed: true, isStreaming: false),
            TimelineUnitHeightKey(id: "a", width: 390, typeScale: 0, isCollapsed: true, isStreaming: false),
            TimelineUnitHeightKey(id: "a", width: 343, typeScale: 1, isCollapsed: true, isStreaming: false),
            TimelineUnitHeightKey(id: "a", width: 343, typeScale: 0, isCollapsed: false, isStreaming: false),
            TimelineUnitHeightKey(id: "a", width: 343, typeScale: 0, isCollapsed: true, isStreaming: true),
        ]
        for variant in variants {
            #expect(cache.height(for: variant) == nil)
            cache.record(100, for: variant)
            #expect(cache.height(for: variant) == 100)
        }
        #expect(cache.count == 1 + variants.count)
        #expect(cache.height(for: base) == 44, "re-recording a shape never rewrites its neighbours")
    }
}