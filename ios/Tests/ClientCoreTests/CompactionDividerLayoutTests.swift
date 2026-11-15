import Foundation
import Testing
@testable import ClientCore

/// The compaction divider is a standalone group watched by the collection
/// list. Every row around it (Code/chat message and step rows) draws its own
/// 5 pt vertical margins and pays no list gap; the divider draws 16 pt of
/// its own padding. It has to follow the same "self-margined" rule, or the
/// default 20 pt gap applies on its trailing side only and the divider sits
/// visibly closer to the reply above it than to the row below (pp
/// 2026-11-15, b1248: copy/share was a red herring — that reply was
/// mid-turn and never had an action bar).
@Suite @MainActor struct CompactionDividerLayoutTests {
    private func row(_ id: String, type: String = "message", role: String = "assistant",
                     order: Int = 1, content: [String: Any]) throws -> ChatTimelineRowModel {
        var value = try itemObject(id: id, order: order)
        value["type"] = type
        value["status"] = "done"
        value["role"] = role
        value["content"] = content
        return ChatTimelineRowModel(try decode(value))
    }

    private func compactMarker(order: Int = 2) throws -> ChatTimelineRowModel {
        try row("compact", type: "marker", role: "system", order: order,
                content: ["kind": "compact", "state": "completed",
                          "compactResult": "success",
                          "cumulativeDroppedTokens": 703_473])
    }

    private func assistantMessage(order: Int = 1) throws -> ChatTimelineRowModel {
        try row("msg", order: order,
                content: ["format": "markdown", "kind": "markdown", "text": "reply"])
    }

    @Test func standaloneCompactGroupIsSelfMargined() throws {
        let group = ChatTimelineGroup(kind: .single, rows: [try compactMarker()])
        #expect(group.isStandaloneCompactDivider)
        #expect(group.isSelfMargined)
        // 16 pt padding + 5 pt neighbour margin on each side, no list gap.
        #expect(group.listSpacing == 0)
        #expect(TimelineListMetrics.itemSpacing == 20)
    }

    @Test func messageGroupsAreSelfMargined() throws {
        let group = ChatTimelineGroup(kind: .single, rows: [try assistantMessage()],
                                      explicitID: "m1")
        #expect(!group.isStandaloneCompactDivider)
        #expect(group.isSelfMargined)
        #expect(group.listSpacing == 0)
    }

    @Test func otherStandaloneGroupsKeepTheListGap() throws {
        let tool = try row("t1", type: "tool", role: "tool",
                           content: ["kind": "command", "command": "pwd"])
        let group = ChatTimelineGroup(kind: .single, rows: [tool])
        #expect(!group.isStandaloneCompactDivider)
        #expect(!group.isSelfMargined)
        #expect(group.listSpacing == TimelineListMetrics.itemSpacing)
    }

    @Test func anInteractionAnchorStandaloneIsSelfMargined() throws {
        let tool = try row("t1", type: "tool", role: "tool",
                           content: ["kind": "command", "command": "pwd"])
        let group = ChatTimelineGroup(kind: .single, rows: [tool],
                                      isInteractionAnchor: true)
        #expect(group.isSelfMargined)
        // The anchor row draws the Code page's 5 pt margins; the list must not
        // add its legacy 20 pt gap under a card that docks right below it
        // (pp 2026-11-16: the question card sat ~20 pt lower than the
        // approval card, whose anchor lives inside a self-margined step group).
        #expect(group.listSpacing == 0)
    }

    @Test func groupingMarksTheInteractionAnchor() throws {
        let tool = try row("t1", type: "tool", role: "tool",
                           content: ["kind": "command", "command": "pwd"])
        let groups = TimelineGrouping.groups([tool], interactionTargets: ["t1"])
        #expect(groups.count == 1)
        #expect(groups[0].isInteractionAnchor)
        #expect(groups[0].listSpacing == 0)
    }

    @Test func groupingKeepsTheDividerStandaloneNextToTheReply() throws {
        let groups = TimelineGrouping.groups([try assistantMessage(), try compactMarker()],
                                             interactionTargets: [])
        #expect(groups.count == 2)
        #expect(groups[1].isStandaloneCompactDivider)
    }

    @Test func aGroupWithMoreThanOneRowIsNeverADivider() throws {
        let group = ChatTimelineGroup(kind: .single,
                                      rows: [try compactMarker(), try compactMarker(order: 3)])
        #expect(!group.isStandaloneCompactDivider)
    }
}
