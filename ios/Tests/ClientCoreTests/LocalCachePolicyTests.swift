import Foundation
import Testing
@testable import ClientCore

@Suite struct LocalCachePolicyTests {
    @Test func limitOptionsExposeBytesAndUnlimited() {
        #expect(LocalCacheLimit.defaultValue == .gb1)
        #expect(LocalCacheLimit.gb1.bytes == 1_073_741_824)
        #expect(LocalCacheLimit.mb256.bytes == 268_435_456)
        #expect(LocalCacheLimit.unlimited.bytes == nil)
        #expect(LocalCacheLimit.allCases.count == 6)
    }

    @Test func effectiveLimitPrefersTheUserChoiceThenTheDeviceSafetyLine() {
        let previous = LocalCachePolicy.current
        defer { LocalCachePolicy.set(previous) }

        LocalCachePolicy.set(.gb1)
        #expect(LocalCachePolicy.effectiveLimit(freeBytes: 10_000_000_000) == 1_073_741_824)

        LocalCachePolicy.set(.unlimited)
        #expect(LocalCachePolicy.effectiveLimit(freeBytes: 10_000_000_000) == 2_000_000_000)
        #expect(LocalCachePolicy.effectiveLimit(freeBytes: 100_000_000_000) == 4_294_967_296)
        #expect(LocalCachePolicy.effectiveLimit(freeBytes: nil) == 4_294_967_296)
    }
}
