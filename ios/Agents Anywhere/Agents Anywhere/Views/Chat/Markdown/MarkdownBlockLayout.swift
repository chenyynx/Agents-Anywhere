import SwiftUI

/// Measures and places Textual with the same column width in one layout pass.
/// No geometry callback writes into View state or schedules a second layout.
struct MarkdownBlockLayout: Layout {
    let dynamicType: DynamicTypeSize
    let displayScale: CGFloat
    let direction: LayoutDirection
    /// Content identity (the block's digest plus the font that draws it).
    /// `nil` disables the shared cache — streaming blocks change every frame.
    var cacheKey: String? = nil

    struct Cache {
        var dynamicType: DynamicTypeSize
        var displayScale: CGFloat
        var direction: LayoutDirection
        var sizing = MarkdownBlockSizing()
        var measurements = MarkdownMeasurementCache()
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(dynamicType: dynamicType, displayScale: displayScale, direction: direction)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        if cache.dynamicType != dynamicType || cache.displayScale != displayScale || cache.direction != direction {
            cache = makeCache(subviews: subviews)
        }
        // A subview change (including asynchronous attachments/highlighting)
        // invalidates actual measurements, while scroll/translation alone does not.
        cache.measurements.invalidate()
        // Appends and Textual's asynchronous highlighter/attachment updates
        // retain the last real height. Authoritative replacements recreate the
        // enclosing row's layout generation, and therefore this cache as well.
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = proposal.width.flatMap { $0.isFinite ? max(0, $0) : nil }
#if DEBUG
        MarkdownLayoutStats.calls += 1
#endif
        let sharedKey = cacheKey.map {
            "\($0)|\(width ?? -1)|\(displayScale)|\(dynamicType)|\(direction)"
        }
        if let sharedKey, let cached = MarkdownBlockSizeCache.shared.size(for: sharedKey) {
#if DEBUG
            MarkdownLayoutStats.cacheHits += 1
#endif
            return cached
        }
        let natural = cache.measurements.size(proposedWidth: width) {
#if DEBUG
            MarkdownLayoutStats.measured += 1
#endif
            return content.sizeThatFits(.init(width: width, height: nil))
        }
        let size = cache.sizing.size(proposedWidth: width, naturalSize: natural, displayScale: displayScale)
        if let sharedKey { MarkdownBlockSizeCache.shared.store(size, for: sharedKey) }
        return size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
            proposal: .init(width: bounds.width, height: nil))
    }
}

#if DEBUG
/// Per-layout-pass counters for the scroll benchmark: how often a block is
/// asked for its size, and how often the instance-local cache actually saved
/// the text layout. Reported by the simulator scroll run; never ships.
nonisolated(unsafe) enum MarkdownLayoutStats {
    static var calls = 0
    static var measured = 0
    static var cacheHits = 0
    static func reset() { calls = 0; measured = 0; cacheHits = 0 }
}
#endif
