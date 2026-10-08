import Foundation

/// The composer ring's arithmetic (context-usage-ring §1.2): the newest
/// main-chain API call's context over the selected model's window. Both sides
/// are read by `SessionChatModel.runContextUsage`; a missing side hides the
/// ring rather than showing 0%.
struct ContextUsage: Equatable {
    let used: Int
    let total: Int

    var isValid: Bool { total > 0 }
    var fraction: Double { total > 0 ? min(max(Double(used) / Double(total), 0), 1) : 0 }
    var remainingPercent: Int { Int(((1 - fraction) * 100).rounded()) }
}

/// The five steps the ring colours by (appendix A). Boundaries read `<` on
/// the upper edge, so an exact 40% is already 正常 and an exact 90% is 将满.
enum ContextLevel: Int, Comparable, CaseIterable {
    case comfortable, normal, elevated, tight, critical

    init(fraction: Double) {
        switch fraction {
        case ..<0.40: self = .comfortable
        case ..<0.60: self = .normal
        case ..<0.75: self = .elevated
        case ..<0.90: self = .tight
        default: self = .critical
        }
    }

    /// Chinese base keys; the view layer registers them as localization keys.
    var title: String {
        switch self {
        case .comfortable: String(localized: "宽裕")
        case .normal: String(localized: "正常")
        case .elevated: String(localized: "偏高")
        case .tight: String(localized: "紧张")
        case .critical: String(localized: "将满")
        }
    }

    static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }
}

/// Counts as the popover prints them (appendix A): below 1,000 the plain
/// number, otherwise 万 with one decimal — whole 万 without one.
enum TokenFormat {
    static func wan(_ n: Int) -> String {
        guard n >= 1000 else { return "\(n)" }
        let value = Double(n) / 10_000
        if abs(value - value.rounded()) < 0.05 { return "\(Int(value.rounded()))万" }
        return String(format: "%.1f万", value)
    }
}

/// Selection → context window, resolved once per page from the model catalog
/// (`metadata.contextWindow`, §1.3). The mapping mirrors
/// `ConversationSettings.modelID(forSelection:)`: a reasoning-item selection
/// stands for its parent model, and disabled entries are not offered.
struct ContextWindowIndex {
    private let windows: [V2SelectionID: Int]

    init(_ catalogs: V2SessionCatalogs) {
        var windows: [V2SelectionID: Int] = [:]
        for model in catalogs.model.models where Self.isEnabled(model.enabled, metadata: model.metadata) {
            guard let window = Self.contextWindow(model.metadata) else { continue }
            if let selection = model.selectionId { windows[selection] = window }
            for item in model.reasoningItems where Self.isEnabled(item.enabled, metadata: item.metadata) {
                windows[item.selectionId] = window
            }
        }
        self.windows = windows
    }

    func contextWindow(forSelection selection: V2SelectionID?) -> Int? {
        guard let selection else { return nil }
        return windows[selection]
    }

    private static func isEnabled(_ enabled: Bool?, metadata: JSONValue) -> Bool {
        enabled ?? metadata["enabled"]?.boolValue ?? true
    }

    private static func contextWindow(_ metadata: JSONValue) -> Int? {
        metadata["contextWindow"]?.intValue
    }
}

extension ContextUsage {
    /// The newest item that carries usage, by `orderSeq` — the whole object,
    /// because the window the engine self-reported travels with the counters
    /// it belongs to (§8 v3). Any carrier kind counts (assistant message,
    /// reasoning, tool, …), because the connector stamps the latest per-call
    /// usage on whichever item it evolves. History and live items compete in
    /// one ordering, and the newest *with* usage wins even when a
    /// still-streaming frame sits after it.
    static func latestUsage(in items: [V2TimelineItem]) -> V2MessageUsage? {
        var latest: V2MessageUsage?
        var latestSeq = Int.min
        for item in items {
            guard let usage = item.usage else { continue }
            if latest == nil || item.orderSeq > latestSeq {
                latest = usage
                latestSeq = item.orderSeq
            }
        }
        return latest
    }

    /// The ring's `used` side: the four-counter sum of `latestUsage`.
    static func used(in items: [V2TimelineItem]) -> Int? {
        latestUsage(in: items)?.contextTokens
    }

    /// `used` and `total` together; either side missing keeps the ring hidden.
    /// `total` prefers the window the usage itself carries — measurement and
    /// window come from the same engine report, so they always agree — and
    /// falls back to the selected model's catalog window only for data stamped
    /// before the connector reported windows. An older carrier's window is
    /// never paired with a newer measurement, and windows are never inferred.
    static func resolve(items: [V2TimelineItem], windows: ContextWindowIndex?, selection: V2SelectionID?) -> ContextUsage? {
        guard let usage = latestUsage(in: items) else { return nil }
        guard let total = usage.contextWindow ?? windows?.contextWindow(forSelection: selection) else { return nil }
        return ContextUsage(used: usage.contextTokens, total: total)
    }
}
