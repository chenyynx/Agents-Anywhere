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
    /// window is the fallback when the row has none.
    ///
    /// A measurement without any window still yields a value: the ring keeps
    /// its slot and draws only the neutral track (no arc), matching the old
    /// "unknown window" state instead of making the ring disappear. The
    /// denominator is never guessed.
    static func resolve(
        items: [V2TimelineItem],
        catalogWindow: Int?
    ) -> V2ContextUsage? {
        // One pass, not a sort: this runs on every body evaluation while the
        // transcript streams. Order-independence is kept by comparing orderSeq
        // rather than trusting the array order.
        var newest: (order: Int, usage: V2MessageUsage)?
        for item in items {
            guard let usage = item.usage, usage.contextTokens > 0 else { continue }
            if newest == nil || item.orderSeq > newest!.order {
                newest = (item.orderSeq, usage)
            }
        }
        guard let latest = newest?.usage else { return nil }
        let used = latest.contextTokens
        let rawWindow = latest.contextWindow ?? catalogWindow
        let window = rawWindow.flatMap { $0 > 0 ? $0 : nil }
        return V2ContextUsage(
            runtime: "runtime",
            totalTokens: used,
            model: latest.model,
            maxTokens: window,
            percentage: window.map { Double(used) / Double($0) * 100 },
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
            guard model.enabled != false,
                  model.metadata["enabled"]?.boolValue != false else { continue }
            let window = model.metadata["contextWindow"]?.intValue
            guard let window, window > 0 else { continue }
            if model.selectionId == selection {
                return window
            }
            for reasoning in model.reasoningItems where reasoning.selectionId == selection {
                guard reasoning.enabled != false,
                      reasoning.metadata["enabled"]?.boolValue != false else {
                    continue
                }
                return window
            }
        }
        return nil
    }
}
