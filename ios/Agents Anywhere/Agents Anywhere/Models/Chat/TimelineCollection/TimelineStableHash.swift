import Foundation

/// Deterministic FNV-1a hashing for layout revisions.
///
/// Swift's `Hasher` is seeded per process, which is fine for dictionary keys
/// but makes a stored revision non-reproducible across launches and exact
/// assertions impossible. Layout revisions are compared inside one process
/// only, yet determinism is cheap and lets tests pin the contract.
nonisolated struct TimelineStableHasher {
    private static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    private static let prime: UInt64 = 0x0000_0100_0000_01b3
    private var state = Self.offsetBasis

    mutating func combine(_ value: UInt64) {
        state ^= value
        state &*= Self.prime
    }

    mutating func combine(_ value: Int) { combine(UInt64(bitPattern: Int64(value))) }

    mutating func combine(_ value: Bool) { combine(UInt64(value ? 1 : 2)) }

    mutating func combine(_ value: CGFloat) { combine(Double(value).bitPattern) }

    mutating func combine(_ value: String) {
        for byte in value.utf8 { combine(UInt64(byte)) }
        // Separator: ("ab", "c") and ("a", "bc") must not collide.
        combine(0xFFFF)
    }

    mutating func combine(optional value: CGFloat?) {
        if let value { combine(true); combine(value) } else { combine(false) }
    }

    mutating func combine(optional value: String?) {
        if let value { combine(true); combine(value) } else { combine(false) }
    }

    var revision: Int { Int(truncatingIfNeeded: state) }
}
