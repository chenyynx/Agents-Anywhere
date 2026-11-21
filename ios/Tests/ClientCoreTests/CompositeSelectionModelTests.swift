import Foundation
import Testing
@testable import ClientCore

/// The composite selection overlay maps every point and offset through this
/// model. A silent change to the separator arithmetic would move a selection
/// into the wrong paragraph, so the boundaries are pinned here.
@Suite("Composite selection model")
struct CompositeSelectionModelTests {
    @Test("block ranges are joined by one separator")
    func blockRangesAndOffsets() {
        let model = CompositeSelectionModel(blockLengths: [3, 0, 5])
        #expect(model.totalLength == 10)
        #expect(model.segments.map(\.range) == [
            NSRange(location: 0, length: 3),
            NSRange(location: 4, length: 0),
            NSRange(location: 5, length: 5),
        ])
        #expect(model.flattenedOffset(blockIndex: 2, localOffset: 2) == 7)
        #expect(model.flattenedOffset(blockIndex: 2, localOffset: 99) == 10)
        #expect(model.flattenedOffset(blockIndex: 9, localOffset: 0) == nil)
    }

    @Test("a range spanning blocks splits into local fragments")
    func fragmentsAcrossBlocks() {
        let model = CompositeSelectionModel(blockLengths: [3, 4])
        #expect(model.fragments(in: NSRange(location: 2, length: 5)) == [
            CompositeSelectionModel.Fragment(
                blockIndex: 0, range: NSRange(location: 2, length: 1)),
            CompositeSelectionModel.Fragment(
                blockIndex: 1, range: NSRange(location: 0, length: 2)),
        ])
    }

    @Test("a separator is not selectable content")
    func separatorProducesNoFragment() {
        let model = CompositeSelectionModel(blockLengths: [3, 4])
        #expect(model.fragments(in: NSRange(location: 3, length: 1)).isEmpty)
    }

    @Test("separator offsets resolve to the previous block end")
    func separatorLocation() {
        let model = CompositeSelectionModel(blockLengths: [3, 4])
        #expect(model.location(at: 3)
            == CompositeSelectionModel.Location(blockIndex: 0, localOffset: 3))
        #expect(model.location(at: 4)
            == CompositeSelectionModel.Location(blockIndex: 1, localOffset: 0))
        #expect(model.location(at: 99)
            == CompositeSelectionModel.Location(blockIndex: 1, localOffset: 4))
    }

    @Test("empty blocks keep later offsets stable")
    func emptyBlocks() {
        let model = CompositeSelectionModel(blockLengths: [0, 4])
        #expect(model.totalLength == 5)
        #expect(model.fragments(in: NSRange(location: 0, length: 5)) == [
            CompositeSelectionModel.Fragment(
                blockIndex: 1, range: NSRange(location: 0, length: 4)),
        ])
    }

    @Test("a single block maps one-to-one")
    func singleBlock() {
        let model = CompositeSelectionModel(blockLengths: [7])
        #expect(model.totalLength == 7)
        #expect(model.fragments(in: NSRange(location: 1, length: 3)) == [
            CompositeSelectionModel.Fragment(
                blockIndex: 0, range: NSRange(location: 1, length: 3)),
        ])
        #expect(model.location(at: 6)
            == CompositeSelectionModel.Location(blockIndex: 0, localOffset: 6))
    }
}
