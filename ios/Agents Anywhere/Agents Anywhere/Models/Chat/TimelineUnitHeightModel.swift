import Foundation

/// What the window's coarse height model knows about one render unit. The
/// estimator is deliberately two-tier (task sheet §P2 对策A, degraded form):
/// a measured truth recorded when a unit renders, and — until then — a cheap
/// estimate from the unit's shape and text volume. Hidden blocks use a fixed
/// collapsed height (a fold that was never rendered has never been toggled).
nonisolated struct TimelineUnitHeightFacts: Equatable {
    let kind: ChatTimelineGroup.Kind
    /// Whether this unit renders as a collapsed fold right now. Single units
    /// ignore it; multi-row units (tools / reconnect / agents) use the fixed
    /// collapsed height without it and a per-row rough height with it.
    let isCollapsed: Bool
    let rowCount: Int
    /// Summed displayed-text length of the unit's rows.
    let textLength: Int
    /// Attachment count of the unit's message rows.
    let attachmentCount: Int
    /// Whether any row is still streaming its text — such a measurement is
    /// not authoritative for the settled shape the spacer will show.
    let isStreaming: Bool
}

/// The measured-truth cache key: the task sheet's (id, column width, Dynamic
/// Type, folded state) plus the streaming flag (a mid-stream measurement must
/// not stand in for the settled row). One key maps to one recorded height.
nonisolated struct TimelineUnitHeightKey: Hashable {
    let id: String
    let width: Int
    let typeScale: Int
    let isCollapsed: Bool
    let isStreaming: Bool
}

nonisolated struct TimelineUnitHeightCache {
    private var entries: [TimelineUnitHeightKey: CGFloat] = [:]

    var count: Int { entries.count }

    mutating func record(_ height: CGFloat, for key: TimelineUnitHeightKey) {
        entries[key] = height
    }

    func height(for key: TimelineUnitHeightKey) -> CGFloat? {
        entries[key]
    }
}

/// The coarse estimator. It only has to be in the right neighbourhood: any
/// error is absorbed by the window-move anchor correction, and every unit that
/// renders once is replaced by its measured truth. Documented trade-offs:
/// markdown structure, code blocks and image loading are not modelled — line
/// count from character volume is the whole story.
nonisolated enum TimelineUnitHeightEstimator {
    /// One body line at the default Dynamic Type size.
    static let bodyLine: CGFloat = 22
    /// A collapsed fold (or a zero-text marker row): one header pill.
    static let collapsedFold: CGFloat = 44
    /// Padding + minimum bubble chrome around message text.
    static let messageChrome: CGFloat = 24
    /// One attachment thumbnail strip.
    static let attachmentStrip: CGFloat = 96
    /// Average glyph width factor for the body font.
    static let glyphWidth: CGFloat = 7.2
    /// The estimator's exit clamp: no unit may *claim* more than about three
    /// screens. A genuinely tall unit renders once and is replaced by its
    /// measured truth, while an unbounded estimate poisons everything drawn
    /// in estimated points until then — the spacer, the expand/shrink
    /// hysteresis band and every anchor correction (the log's system rows,
    /// estimated 10–200× over). Roughly three phone screens; the estimate is
    /// a placeholder, never a contract.
    static let maxEstimatedHeight: CGFloat = 3 * 900

    static func height(_ facts: TimelineUnitHeightFacts, width: CGFloat, typeScale: CGFloat) -> CGFloat {
        // A collapsed unit renders its header pill and nothing else — one
        // line, whatever payload sits behind the fold. This is the whole
        // story for every kind: the log's 30 000-char fold leaders measured
        // 38 pt while the text-priced estimate sat at the 2 700 pt clamp
        // (2026-10-10).
        if facts.isCollapsed { return collapsedFold }
        let line = bodyLine * typeScale
        let estimate: CGFloat
        switch facts.kind {
        case .single:
            if facts.rowCount == 1, facts.textLength == 0, facts.attachmentCount == 0 {
                estimate = collapsedFold
            } else {
                estimate = messageChrome + CGFloat(lines(for: facts.textLength, width: width, typeScale: typeScale)) * line
                    + CGFloat(facts.attachmentCount) * attachmentStrip
            }
        case .tools, .reconnect, .agents:
            // Expanded folds are rough on purpose: the spacer refines them
            // by measurement as soon as the reader reaches them.
            estimate = collapsedFold + CGFloat(facts.rowCount) * (line * 1.2)
        }
        return min(estimate, maxEstimatedHeight)
    }

    static func lines(for textLength: Int, width: CGFloat, typeScale: CGFloat) -> Int {
        guard textLength > 0 else { return 1 }
        let usable = max(80, width - 32)
        let charactersPerLine = max(8, usable / (glyphWidth * typeScale))
        let raw = (CGFloat(textLength) / charactersPerLine).rounded(.up)
        // Markdown block spacing per ~4 wrapped lines.
        return max(1, Int(raw) + Int(raw / 4))
    }
}
