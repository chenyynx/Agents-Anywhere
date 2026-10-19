import Foundation

/// The collection timeline's fixed geometry. These are the same constants the
/// SwiftUI content column used (`ChatPageContentColumn`): 16pt top inset, a
/// 16/20pt adaptive horizontal inset, a 760pt maximum column, and 20pt between
/// every top-level item.
nonisolated enum TimelineListMetrics {
    static let topInset: CGFloat = 16
    static let itemSpacing: CGFloat = 20
    static let maximumColumnWidth: CGFloat = 760
    static let wideLayoutThreshold: CGFloat = 414

    static func horizontalInset(containerWidth: CGFloat) -> CGFloat {
        containerWidth >= wideLayoutThreshold ? 20 : 16
    }

    /// The centered content column. A zero-width container still yields a
    /// zero-width column instead of a negative one during the first layout.
    static func column(containerWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let inset = horizontalInset(containerWidth: containerWidth)
        let width = max(0, min(maximumColumnWidth, containerWidth - inset * 2))
        return (x: (containerWidth - width) / 2, width: width)
    }
}
