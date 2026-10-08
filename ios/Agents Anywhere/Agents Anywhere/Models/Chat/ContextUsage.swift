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

/// What the composer ring should show. `ContextUsage` only describes the
/// complete case (a real `used` and a real `total`); the ring itself must also
/// survive a session that has a genuine measurement but no known window yet
/// (pp 2026-10-08: "这个圆环稳定显示，不是消失"). This three-way state keeps
/// "no measurement" distinct from "measurement, window unknown" so the view
/// can hide the former and render an honest unknown state for the latter.
enum ContextRingState: Equatable {
    /// `used` and `total` both known — the ring's normal progress arc.
    case ready(ContextUsage)
    /// A real (nonzero) measurement exists, but neither the usage-carried
    /// window nor the catalog supplies a `total`. The ring stays visible with
    /// a neutral unknown state instead of vanishing; the measurement is real
    /// so it is carried along, never fabricated.
    case unknownWindow(used: Int)
    /// No real measurement at all (a fresh session, every carrier all-zero) —
    /// the ring stays hidden, unchanged from before.
    case hidden

    /// The complete usage, when the window is known.
    var usage: ContextUsage? {
        if case let .ready(usage) = self { return usage }
        return nil
    }

    /// Whether the composer should render the ring at all. `ready` needs a
    /// positive total (`isValid`), preserving the old gate; `unknownWindow`
    /// is visible by design; `hidden` is not.
    var isVisible: Bool {
        switch self {
        case .ready(let usage): usage.isValid
        case .unknownWindow: true
        case .hidden: false
        }
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
    /// The newest item that carries *real* usage, by `orderSeq` — the whole
    /// object, because the window the engine self-reported travels with the
    /// counters it belongs to (§8 v3). Any carrier kind counts (assistant
    /// message, reasoning, tool, …), because the connector stamps the latest
    /// per-call usage on whichever item it evolves. History and live items
    /// compete in one ordering, and the newest *with* usage wins even when a
    /// still-streaming frame sits after it.
    ///
    /// Carriers whose counters are all zero are skipped: an all-zero
    /// measurement is not a measurement (宁缺勿假 — never show a fabricated
    /// empty context). Live streaming rows can briefly carry an all-zero seed
    /// that would otherwise permanently shadow the newest real measurement and
    /// flip the ring to 0, so the pick stays on the newest genuine report. A
    /// carrier with any nonzero counter still counts.
    static func latestUsage(in items: [V2TimelineItem]) -> V2MessageUsage? {
        var latest: V2MessageUsage?
        var latestSeq = Int.min
        for item in items {
            guard let usage = item.usage, usage.contextTokens > 0 else { continue }
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

extension ContextRingState {
    /// The composer ring's three-way resolution. It shares `latestUsage` and
    /// the §8 v3 window precedence with `ContextUsage.resolve`: a real
    /// measurement carries its own window and wins; the catalog window is only
    /// the fallback for data stamped before the connector reported windows.
    ///
    /// The difference is the middle state. `ContextUsage.resolve` returns nil
    /// whenever the window is unknown — indistinguishable from "no
    /// measurement", so the ring disappears. A gateway model
    /// (`deepseek-v4.1-flash`) has no catalog window, so a session sits in
    /// exactly that state between its first real report and the first window
    /// calibration. Here that resolves to `.unknownWindow` (ring visible, no
    /// progress arc) rather than vanishing.
    ///
    /// The zero-carrier skip and the measurement query are unchanged: an
    /// all-zero seed is not a measurement, so it yields `.hidden`, never an
    /// unknown-window state with a fabricated zero.
    static func resolve(items: [V2TimelineItem], windows: ContextWindowIndex?, selection: V2SelectionID?) -> ContextRingState {
        guard let usage = ContextUsage.latestUsage(in: items) else { return .hidden }
        guard let total = usage.contextWindow ?? windows?.contextWindow(forSelection: selection) else {
            return .unknownWindow(used: usage.contextTokens)
        }
        return .ready(ContextUsage(used: usage.contextTokens, total: total))
    }
}
