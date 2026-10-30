import Foundation

/// The cache-limit choices shown in Settings. `unlimited` still has a device
/// safety line (`LocalCachePolicy.effectiveLimit`).
nonisolated enum LocalCacheLimit: Int, CaseIterable, Identifiable, Sendable {
    case mb256 = 268_435_456
    case mb512 = 536_870_912
    case gb1 = 1_073_741_824
    case gb2 = 2_147_483_648
    case gb5 = 5_368_709_120
    case unlimited = -1

    static let defaultValue = LocalCacheLimit.gb1

    var id: Int { rawValue }

    var bytes: Int64? {
        self == .unlimited ? nil : Int64(rawValue)
    }

    var title: String {
        self == .unlimited
            ? String(localized: "Unlimited")
            : LocalCachePolicy.formatted(Int64(rawValue))
    }
}

nonisolated struct LocalCacheUsage: Equatable, Sendable {
    let bytes: Int64
    let sessions: Int
}

nonisolated enum LocalCachePolicy {
    static let key = "LocalTimelineStore.cacheLimitBytes"
    static let hardSafetyCeiling: Int64 = 4 * 1_073_741_824

    static var current: LocalCacheLimit {
        guard let value = UserDefaults.standard.object(forKey: key) as? Int,
              let limit = LocalCacheLimit(rawValue: value) else {
            return .defaultValue
        }
        return limit
    }

    static func set(_ value: LocalCacheLimit) {
        UserDefaults.standard.set(value.rawValue, forKey: key)
    }

    /// The limit the store enforces. An explicit choice is used as-is;
    /// `unlimited` is capped by the device's free space.
    static func effectiveLimit(freeBytes: Int64?) -> Int64 {
        if let bytes = current.bytes { return bytes }
        // If the device cannot report free space, keep the hard ceiling rather
        // than collapsing the cache to zero.
        guard let freeBytes else { return hardSafetyCeiling }
        return min(hardSafetyCeiling, max(0, freeBytes / 5))
    }

    static func formatted(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: bytes)
    }
}
