import Foundation
import Testing
@testable import ClientCore

// The tool result's own truncation flag, not the deferred client window.
// Verified field shape (2026-11-01): a 3000-line Read carries
// `toolUseResult.file = { numLines: 1769, startLine: 1, totalLines: 3000,
// truncatedByTokenCap: true }`, which the connector now forwards as
// `content.readMetadata`.

private func makeItem(_ content: [String: Any]) throws -> V2TimelineItem {
    try decode([
        "id": "item",
        "sessionId": "session",
        "type": "tool",
        "status": "done",
        "content": content,
        "source": ["itemId": "item"],
        "orderSeq": 1,
        "revision": 1,
        "updatedSeq": 1,
        "contentHash": "item",
    ])
}

@Suite("Code tool result truncation")
struct CodeToolTruncationTests {
    @Test func tokenCappedReadIsTruncated() throws {
        let item = try makeItem([
            "toolName": "Read",
            "readMetadata": [
                "filePath": "/tmp/trunc-lines-3000.txt",
                "numLines": 1769,
                "startLine": 1,
                "totalLines": 3000,
                "truncatedByTokenCap": true,
            ],
        ])

        #expect(CodeToolTruncation.isTruncated(item))
        let metadata = try #require(
            CodeToolTruncation.readMetadata(item.raw["content"] ?? .object([:])))
        #expect(metadata.filePath == "/tmp/trunc-lines-3000.txt")
        #expect(metadata.numLines == 1769)
        #expect(metadata.startLine == 1)
        #expect(metadata.totalLines == 3000)
        #expect(metadata.isTruncated)
    }

    @Test func completeReadIsNotTruncated() throws {
        let item = try makeItem([
            "readMetadata": [
                "numLines": 12,
                "startLine": 1,
                "totalLines": 12,
                "truncatedByTokenCap": false,
            ],
        ])

        #expect(!CodeToolTruncation.isTruncated(item))
    }

    /// An intentional `offset`/`limit` slice is not a cut output: the
    /// official footnote marks the tool output limit, not a requested range.
    @Test func partialLineRangeIsNotTruncatedWithoutTheTokenCap() throws {
        let item = try makeItem([
            "readMetadata": [
                "numLines": 200,
                "startLine": 201,
                "totalLines": 5000,
                "truncatedByTokenCap": false,
            ],
        ])

        #expect(!CodeToolTruncation.isTruncated(item))
    }

    @Test func genericTruncatedFlagIsHonoured() throws {
        let item = try makeItem(["truncated": true])
        #expect(CodeToolTruncation.isTruncated(item))
    }

    /// A deferred summary is not a truncated tool result: the row was not
    /// loaded, the tool output was not cut. The two must never be conflated.
    @Test func deferredSummaryIsNotTruncation() throws {
        let item = try makeItem([
            "deferred": true,
            "outputPreview": "a bounded preview",
        ])
        #expect(!CodeToolTruncation.isTruncated(item))
    }
}
