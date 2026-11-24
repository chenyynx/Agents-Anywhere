import CoreGraphics

/// Which rows an apply measures synchronously, before its snapshot lands.
///
/// A row the height cache has no real height for needs a measurement, but not
/// all of them belong in the apply's main-thread pass:
///
/// - A row with layout attributes keeps the viewport rule: a row far above the
///   reader keeps its estimate until it can be seen.
/// - A row with no attributes at all belongs to the first layout of a window.
///   Measuring every unmeasured row there pays the whole history's text
///   layout before the first frame (588-item session: ~0.8 s, device log
///   2026-11-24). The reader opens at the tail, so only a bounded tail is
///   measured; the rest stays pending and the offscreen pass skips it until
///   it approaches the viewport — the path history pages already use.
///   The caller decides when that applies: a mid-list insertion also leaves
///   attribute-less rows, and those keep the old rule (limit = item count) so
///   a row inserted above the viewport is measured before it is scrolled to.
///
/// Pure so the selection can be tested without a collection view.
nonisolated enum TimelineSynchronousMeasurementSelection {
    /// Attribute-less items an opening apply measures. About three screens of
    /// tall rows; the opening anchor is the bottom of the window.
    static let openingTailLimit = 24

    static func shouldMeasure(index: Int,
                              itemCount: Int,
                              needsMeasurement: Bool,
                              attributesMaxY: CGFloat?,
                              skipAbove: CGFloat,
                              tailLimit: Int = openingTailLimit) -> Bool {
        guard needsMeasurement else { return false }
        if let attributesMaxY { return attributesMaxY >= skipAbove }
        return index >= itemCount - tailLimit
    }
}
