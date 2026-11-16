import Foundation
import Testing
@testable import ClientCore

/// The history-pull half of the retired navigation suite. The scroll state
/// machine it used to exercise was deleted on 2026-11-16 (the collection
/// engine owns scrolling now); `TimelineHistoryPull` is live product code, so
/// its coverage stays here on its own.
@Suite struct TimelineHistoryPullTests {
    private func viewport(offset: CGFloat = 0, height: CGFloat = 2000, container: CGFloat = 800) -> TimelineViewport {
        TimelineViewport(contentHeight: height, containerHeight: container, topInset: 80, bottomInset: 120, offsetY: offset)
    }

    @Test func eachHistoryEdgeNeedsOneFreshPullOnAnAlreadyVisiblePrompt() {
        for edge in [TimelineHistoryPull.Edge.older, .latest] {
            var pull = TimelineHistoryPull(edge: edge)
            let direction: CGFloat = edge == .older ? -1 : 1
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            #expect(pull.isReady)
            let first = pull.end(), second = pull.end()
            #expect(first && !second)
            pull.update(viewport(offset: direction * 60))
            let inertia = pull.end()
            #expect(!inertia)
            pull.begin(at: viewport(), promptVisible: false, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            let firstArrival = pull.end()
            #expect(!firstArrival)
            // A failed page read can be retried by a new deliberate pull.
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 30))
            let retry = pull.end()
            #expect(retry)
        }
    }

    @Test func historyPullCancelsOnResizingReversalOrExistingRequests() {
        for edge in [TimelineHistoryPull.Edge.older, .latest] {
            var pull = TimelineHistoryPull(edge: edge)
            let direction: CGFloat = edge == .older ? -1 : 1
            pull.begin(at: viewport(), promptVisible: true, canLoad: false)
            pull.update(viewport(offset: direction * 50))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 50, height: 2020))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 50, container: 500))
            #expect(!pull.isReady)
            pull.begin(at: viewport(), promptVisible: true, canLoad: true)
            pull.update(viewport(offset: direction * 40))
            pull.update(viewport(offset: direction * 5))
            let reversed = pull.end()
            #expect(!reversed)
        }
    }
}
