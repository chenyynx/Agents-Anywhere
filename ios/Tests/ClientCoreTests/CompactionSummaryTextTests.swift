import Foundation
import Testing
@testable import ClientCore

/// The official Code page's compaction divider label (`round31-compaction-ui`
/// §4–§5): `已压缩对话`, extended with a saved/from token clause when the
/// compact marker's content carries the CLI's `compactMetadata`, or the
/// failure message.
@Suite struct CompactionSummaryTextTests {
    private func compactItem(_ content: [String: Any],
                             status: String = "done") throws -> V2TimelineItem {
        var object = try itemObject(id: "compact")
        object["type"] = "system"
        object["role"] = "system"
        object["status"] = status
        var merged: [String: Any] = ["kind": "compact", "state": "completed"]
        merged.merge(content) { _, new in new }
        object["content"] = merged
        return try decode(object, as: V2TimelineItem.self)
    }

    /// The wire sample from the connector's real-wire fixture: pre 35,134 /
    /// post 1,865 / cumulative drop 33,269 (`test_claude_commands.py`).
    @Test func savedTokensWinOverTheConversationSize() throws {
        let item = try compactItem([
            "preTokens": 35_134,
            "postTokens": 1_865,
            "cumulativeDroppedTokens": 33_269,
        ])
        let count = CompactionSummaryText.tokenCount(in: item.raw["content"])
        #expect(count == .saved(33_269))
        let label = CompactionSummaryText.label(count, locale: Locale(identifier: "en_US"))
        #expect(label.contains("节省了"))
        #expect(label.contains("33,269"))
    }

    /// "Saved 0 tokens" reads as a bug; a zero drop falls back to the
    /// conversation size, the other official variant.
    @Test func aZeroDropFallsBackToTheConversationSize() throws {
        let item = try compactItem(["preTokens": 18_000, "cumulativeDroppedTokens": 0])
        #expect(CompactionSummaryText.tokenCount(in: item.raw["content"])
            == .preCompaction(18_000))
        let label = CompactionSummaryText.label(.preCompaction(18_000),
                                                locale: Locale(identifier: "en_US"))
        #expect(label.contains("压缩前"))
        #expect(label.contains("18,000"))
    }

    /// An older connector (or a compaction with no metadata) still settles on
    /// the plain official label.
    @Test func aSummaryWithoutTokensKeepsThePlainLabel() throws {
        let item = try compactItem([:])
        #expect(CompactionSummaryText.tokenCount(in: item.raw["content"]) == nil)
        let label = CompactionSummaryText.label(nil)
        #expect(label.contains("已压缩对话"))
        #expect(!label.contains("token"))
    }

    @Test func theSettledRowUsesTheOfficialCodeLabel() throws {
        let item = try compactItem(["preTokens": 35_134, "cumulativeDroppedTokens": 33_269])
        let presentation = TimelineEntryPresentation(item: item, cwd: nil)
        #expect(presentation.kind == .compact)
        #expect(!presentation.compactFailed)
        // Compare against the helper (same locale as the presentation) rather
        // than pinning the runner's thousands separator.
        #expect(presentation.title == CompactionSummaryText.label(.saved(33_269)))
        #expect(presentation.title.contains("已压缩对话"))
    }

    @Test func aFailedCompactionUsesTheOfficialFailureMessage() throws {
        let item = try compactItem(["state": "failed"], status: "failed")
        let presentation = TimelineEntryPresentation(item: item, cwd: nil)
        #expect(presentation.compactFailed)
        #expect(presentation.title == CompactionSummaryText.failed)
        #expect(presentation.title.contains("对话压缩失败"))
    }

    /// The active row is not drawn (the working status row narrates the
    /// compaction), but its words stay the official Code page's.
    @Test func anActiveCompactionKeepsTheCompactingWords() throws {
        let item = try compactItem(["state": "started"], status: "running")
        let presentation = TimelineEntryPresentation(item: item, cwd: nil)
        #expect(presentation.kind == .compact)
        #expect(!presentation.compactFailed)
        #expect(presentation.title.contains("正在压缩对话"))
    }

    /// A non-compact marker is never a failed compaction, even when its own
    /// status is failed.
    @Test func otherMarkerRowsAreNotCompactFailures() throws {
        var object = try itemObject(id: "marker")
        object["type"] = "system"
        object["status"] = "failed"
        object["content"] = ["kind": "notice", "state": "failed"]
        let item = try decode(object, as: V2TimelineItem.self)
        let presentation = TimelineEntryPresentation(item: item, cwd: nil)
        #expect(!presentation.compactFailed)
    }
}
