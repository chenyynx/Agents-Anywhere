import Foundation

/// Maps one message body's flattened text back to the blocks that draw it.
///
/// The Code page draws each paragraph / list item / quote as its own TextKit
/// view. Cross-block selection needs one coordinate space over all of them:
/// this model concatenates the block lengths with a one-character separator
/// (a newline) between blocks, then converts a flattened UTF-16 range into the
/// per-block local ranges the views can answer geometry for.
///
/// Pure value logic on purpose: the selection overlay owns gestures and
/// geometry, this type owns the offset arithmetic and is unit-tested.
struct CompositeSelectionModel: Equatable {
    struct Segment: Equatable {
        let blockIndex: Int
        /// Range in the flattened text occupied by the block itself.
        let range: NSRange
    }

    struct Fragment: Equatable {
        let blockIndex: Int
        /// Range inside that block's own string.
        let range: NSRange
    }

    struct Location: Equatable {
        let blockIndex: Int
        let localOffset: Int
    }

    /// One newline joins each pair of blocks in the flattened text.
    static let separatorLength = 1

    let segments: [Segment]
    let totalLength: Int

    init(blockLengths: [Int]) {
        var segments: [Segment] = []
        segments.reserveCapacity(blockLengths.count)
        var offset = 0
        for (index, length) in blockLengths.enumerated() {
            if index > 0 { offset += Self.separatorLength }
            let clamped = max(0, length)
            segments.append(Segment(
                blockIndex: index,
                range: NSRange(location: offset, length: clamped)))
            offset += clamped
        }
        self.segments = segments
        self.totalLength = offset
    }

    var blockLengths: [Int] { segments.map(\.range.length) }

    /// Flattened offset for a local offset inside one block.
    func flattenedOffset(blockIndex: Int, localOffset: Int) -> Int? {
        guard segments.indices.contains(blockIndex) else { return nil }
        let segment = segments[blockIndex]
        let clamped = min(max(localOffset, 0), segment.range.length)
        return segment.range.location + clamped
    }

    /// The block that owns a flattened offset. Offsets in a separator (or at
    /// the very end) resolve to the end of the previous non-empty block;
    /// offsets before any block resolve to the first one's start.
    func location(at offset: Int) -> Location? {
        guard !segments.isEmpty else { return nil }
        let clamped = min(max(offset, 0), totalLength)
        for segment in segments where segment.range.length > 0
            && segment.range.location <= clamped
            && clamped < NSMaxRange(segment.range) {
            return Location(blockIndex: segment.blockIndex,
                            localOffset: clamped - segment.range.location)
        }
        for segment in segments.reversed() where segment.range.length > 0
            && NSMaxRange(segment.range) <= clamped {
            return Location(blockIndex: segment.blockIndex,
                            localOffset: segment.range.length)
        }
        return Location(blockIndex: segments[0].blockIndex, localOffset: 0)
    }

    /// Split a flattened range into the per-block local ranges it covers.
    /// Separators contribute nothing, so a selection of only separators
    /// yields no fragments.
    func fragments(in range: NSRange) -> [Fragment] {
        guard range.length > 0, !segments.isEmpty else { return [] }
        let start = min(max(range.location, 0), totalLength)
        let end = min(max(NSMaxRange(range), start), totalLength)
        guard end > start else { return [] }
        var fragments: [Fragment] = []
        for segment in segments where segment.range.length > 0 {
            let from = max(start, segment.range.location)
            let to = min(end, NSMaxRange(segment.range))
            guard to > from else { continue }
            fragments.append(Fragment(
                blockIndex: segment.blockIndex,
                range: NSRange(location: from - segment.range.location,
                               length: to - from)))
        }
        return fragments
    }
}
