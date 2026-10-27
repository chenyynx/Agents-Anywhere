import Foundation
import Testing
@testable import ClientCore

/// C0: a latest window can consist only of rows the connector attributed to an
/// Agent card. The default grouping drops every one of them (L2.1), so the main
/// timeline falls back to a grouping that keeps them visible; the older-history
/// spinner must not wait for an anchor an empty window can never lay out.
@Suite @MainActor struct TimelineAgentFallbackTests {
    private func item(_ id: String, type: String = "tool", order: Int = 1,
                      content: [String: Any]) throws -> V2TimelineItem {
        var value = try itemObject(id: id, order: order)
        value["type"] = type; value["status"] = "done"; value["content"] = content
        return try decode(value)
    }

    private func child(_ id: String, parent: String = "card", order: Int = 1) throws -> ChatTimelineRowModel {
        ChatTimelineRowModel(try item(id, order: order,
            content: ["kind": "command", "command": "ls", "parentItemId": parent]))
    }

    private func mainTool(_ id: String, order: Int = 1) throws -> ChatTimelineRowModel {
        ChatTimelineRowModel(try item(id, order: order, content: ["kind": "command", "command": "pwd"]))
    }

    @Test func aChildOnlyWindowFallsBackToItsAgentGroups() throws {
        let first = try child("a1", order: 1), second = try child("a2", order: 2)
        // The default grouping keeps the L2.1 contract: nothing to render.
        #expect(TimelineGrouping.groups([first, second], interactionTargets: []).isEmpty)
        #expect(TimelineGrouping.needsAgentFallback([first, second]))
        let fallback = TimelineGrouping.fallbackGroups([first, second], interactionTargets: [])
        #expect(fallback.map(\.kind) == [.agents("card")])
        #expect(fallback.first?.rows.map(\.id) == ["a1", "a2"])
        // An empty window is not a child-only window.
        #expect(!TimelineGrouping.needsAgentFallback([]))
    }

    @Test func consecutiveRowsMergePerParent() throws {
        let one = try child("a1", parent: "card-a", order: 1)
        let two = try child("a2", parent: "card-a", order: 2)
        let other = try child("b1", parent: "card-b", order: 3)
        let groups = TimelineGrouping.fallbackGroups([one, two, other], interactionTargets: [])
        // The existing grouping convention keeps a one-row group `.single`;
        // only a run of two or more folds into `.agents(parent)`.
        #expect(groups.map(\.kind) == [.agents("card-a"), .single])
        #expect(groups[0].rows.map(\.id) == ["a1", "a2"])
        #expect(groups[1].rows.map(\.id) == ["b1"])
    }

    @Test func aWindowWithAMainRowKeepsTheDefaultGrouping() throws {
        let main = try mainTool("m1", order: 1)
        let second = try mainTool("m2", order: 2)
        let child = try child("a1", order: 3)
        #expect(!TimelineGrouping.needsAgentFallback([main, child]))
        // The fallback path is not even consulted; the default grouping is
        // still the L2.1 one (child rows dropped).
        #expect(TimelineGrouping.groups([main, second, child], interactionTargets: []).map(\.kind) == [.tools])
        #expect(TimelineGrouping.groups([main, second, child], interactionTargets: [])[0].rows.map(\.id)
            == ["m1", "m2"])
    }

    @Test func anInteractionAnchoredChildStillTriggersTheFallback() throws {
        let anchor = try child("t1", order: 1), other = try child("t2", order: 2)
        // The anchored child keeps its own default group, so the default list
        // is not empty — but the card it belongs to is still outside the
        // window, so the fallback must still take over.
        let defaults = TimelineGrouping.groups([anchor, other], interactionTargets: ["t1"])
        #expect(defaults.map(\.kind) == [.single])
        #expect(defaults[0].rows.map(\.id) == ["t1"])
        #expect(TimelineGrouping.needsAgentFallback([anchor, other]))
        let fallback = TimelineGrouping.fallbackGroups([anchor, other], interactionTargets: ["t1"])
        // The lone remaining child is its own one-row group (`.single`); it is
        // still rendered, which is all the fallback promises.
        #expect(fallback.map(\.kind) == [.single, .single])
        #expect(fallback[0].rows.map(\.id) == ["t1"])
        #expect(fallback[1].rows.map(\.id) == ["t2"])
    }

    @Test func onlyANonEmptyWindowUsesAHistoryAnchor() throws {
        let row = try mainTool("m1")
        #expect(!TimelineGrouping.usesHistoryAnchor([]))
        #expect(TimelineGrouping.usesHistoryAnchor([row]))
    }
}
