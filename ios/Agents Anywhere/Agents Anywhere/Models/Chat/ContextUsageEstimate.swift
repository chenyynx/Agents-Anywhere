import Foundation

/// The pre-CLI ring's arithmetic, kept as the last-resort fallback.
///
/// The live answer needs a runtime transport; a cold session (and an offline
/// connector) has none, yet the timeline it already loaded carries the same
/// per-call usage the old composer ring read. Resolving it here keeps the ring
/// visible instead of vanishing — the value is an estimate (`timeline.estimate`
/// source), so the sheet labels it and offers a refresh once the runtime
/// answers.
enum ContextUsageEstimate {
    /// Newest item with a real measurement over its own reported window (the
    /// connector stamps the calibrated window on each usage row); the catalog
    /// window is the fallback when the row has none. A missing window yields
    /// nil — a ring must never draw a guessed denominator.
    static func resolve(
        items: [V2TimelineItem],
        catalogWindow: Int?
    ) -> V2ContextUsage? {
        let latest = items.reversed().lazy.compactMap { item -> V2MessageUsage? in
            guard let usage = item.usage, usage.contextTokens > 0 else { return nil }
            return usage
        }.first
        guard let latest else { return nil }
        guard let window = latest.contextWindow ?? catalogWindow, window > 0 else {
            return nil
        }
        let used = latest.contextTokens
        return V2ContextUsage(
            runtime: "runtime",
            totalTokens: used,
            model: latest.model,
            maxTokens: window,
            percentage: Double(used) / Double(window) * 100,
            detail: "estimate",
            source: "timeline.estimate"
        )
    }

    /// The selected model's context window out of the model catalog, matching
    /// the old `ContextWindowIndex` rules: reasoning sub-entries inherit the
    /// parent's window and disabled entries are skipped.
    static func catalogWindow(
        _ catalogs: V2SessionCatalogs,
        selection: V2SelectionID?
    ) -> Int? {
        guard let selection else { return nil }
        for model in catalogs.model.models {
            guard model.enabled != false else { continue }
            let window = model.metadata["contextWindow"]?.intValue
            guard let window, window > 0 else { continue }
            if model.selectionId == selection {
                return window
            }
            for reasoning in model.reasoningItems where reasoning.selectionId == selection {
                return window
            }
        }
        return nil
    }
}
