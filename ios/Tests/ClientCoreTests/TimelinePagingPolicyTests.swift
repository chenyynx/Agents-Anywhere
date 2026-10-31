import Foundation
import Testing
@testable import ClientCore

/// The paging/return guards as pure state (controller-independent). Every
/// case here pins a behaviour the collection controller previously scattered
/// across closures; deleting any guard turns one of these red.
@Suite struct TimelinePagingPolicyTests {
    @Test func theOpeningHoldsTheTopTriggerUntilRealContentLandsAtTheBottom() {
        var policy = TimelinePagingPolicy()
        policy.beginOpening()
        // An empty or sub-viewport window sits at its own bottom; that must
        // not release the gate (device report 03:55: the empty bottom cleared
        // the gate and the restored window paged history from the top).
        policy.noteLanding(contentIsTallerThanViewport: false, atBottom: true)
        #expect(!policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
        // Real content at the bottom releases it.
        policy.noteLanding(contentIsTallerThanViewport: true, atBottom: true)
        #expect(policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
    }

    @Test func aFiredShotNeedsANewGesture() {
        var policy = TimelinePagingPolicy()
        #expect(policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
        policy.didAutoLoadOlder()
        #expect(!policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
        // A page landing on the top edge does not re-arm it; a gesture does.
        policy.readerMoved()
        #expect(policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
    }

    @Test func aBottomReturnArmedBeforeAReaderMoveIsVoided() {
        var policy = TimelinePagingPolicy()
        policy.armBottomReturn()
        var resolve = policy.resolveBottomReturn()
        #expect(resolve)
        policy.armBottomReturn()
        policy.readerMoved()
        resolve = policy.resolveBottomReturn()
        #expect(!resolve)
    }

    @Test func anUnarmedReturnCannotLand() {
        var policy = TimelinePagingPolicy()
        let resolve = policy.resolveBottomReturn()
        #expect(!resolve)
    }

    @Test func aReaderMoveClearsTheOpeningGate() {
        var policy = TimelinePagingPolicy()
        policy.beginOpening()
        policy.readerMoved()
        #expect(policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
    }

    @Test func theFallbackReleasesTheGate() {
        var policy = TimelinePagingPolicy()
        policy.beginOpening()
        policy.openingFallbackExpired()
        #expect(policy.mayAutoLoadOlder(contentIsTallerThanViewport: true))
    }
}
