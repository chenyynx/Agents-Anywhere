import Foundation

/// Layout-local height reservations, keyed by the parent's width proposal.
/// A paragraph's intrinsic width is an output, never the next layout's input.
struct MarkdownBlockSizing {
    private struct Measurement {
        let width: CGFloat
        var height: CGFloat
    }
    private var measurements: [Measurement] = []

    mutating func size(proposedWidth: CGFloat?, naturalSize: CGSize, displayScale: CGFloat) -> CGSize {
        // SwiftUI may ask for minimum/ideal sizes before placing the block.
        // Those probes must not replace the reservation for its actual column.
        guard let width = proposedWidth, width.isFinite, width > 1 else { return naturalSize }
        let scale = displayScale.isFinite && displayScale > 0 ? displayScale : 1
        let naturalHeight = naturalSize.height.isFinite ? max(0, naturalSize.height) : 0
        var height = ceil(naturalHeight * scale) / scale
        if let index = measurements.firstIndex(where: { $0.width == width }) {
            height = max(height, measurements.remove(at: index).height)
        }
        measurements.append(Measurement(width: width, height: height))
        // Keep measurement probes separate without accumulating every width
        // visited by an interactive iPad split resize.
        if measurements.count > 8 { measurements.removeFirst() }
        return CGSize(width: width, height: height)
    }
}

/// Cache actual child measurements separately from the monotonic height reservation.
/// Layout.updateCache invalidates these when subviews or their environment change.
struct MarkdownMeasurementCache {
    private struct Measurement {
        let width: CGFloat?
        let size: CGSize
    }
    private var measurements: [Measurement] = []

    mutating func size(proposedWidth: CGFloat?, measure: () -> CGSize) -> CGSize {
        if let cached = measurements.first(where: { $0.width == proposedWidth }) { return cached.size }
        let result = measure()
        measurements.append(Measurement(width: proposedWidth, size: result))
        if measurements.count > 8 { measurements.removeFirst() }
        return result
    }

    mutating func invalidate() { measurements.removeAll(keepingCapacity: true) }
}

/// Process-wide block size cache.
///
/// Every cell configuration hands SwiftUI a brand-new view tree, so each
/// `MarkdownBlockLayout` starts with an empty local cache and pays the full
/// block layout again. Sizes are pure functions of (block text, width, scale,
/// dynamic type, direction), so they are shared across instances and with the
/// pre-measure pass that already laid the same block out.
nonisolated final class MarkdownBlockSizeCache: @unchecked Sendable {
    static let shared = MarkdownBlockSizeCache()
    private let lock = NSLock()
    private var storage: [String: CGSize] = [:]
    private var order: [String] = []
    private let limit = 4096

    func size(for key: String) -> CGSize? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func store(_ size: CGSize, for key: String) {
        lock.lock(); defer { lock.unlock() }
        if storage[key] == nil {
            order.append(key)
            if order.count > limit {
                for dropped in order.prefix(order.count - limit) {
                    storage.removeValue(forKey: dropped)
                }
                order.removeFirst(order.count - limit)
            }
        }
        storage[key] = size
    }
}
