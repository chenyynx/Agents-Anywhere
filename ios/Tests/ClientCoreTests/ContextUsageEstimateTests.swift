import Foundation
import Testing
@testable import ClientCore

/// The timeline fallback (the old composer ring's arithmetic): it keeps the
/// ring visible when the runtime cannot answer, without guessing a window.
@Suite struct ContextUsageEstimateTests {
    private func item(
        id: String,
        order: Int,
        usage: [String: Any]
    ) throws -> V2TimelineItem {
        var object = try itemObject(id: id, order: order)
        object["type"] = "message"
        object["status"] = "done"
        object["content"] = ["text": "hi", "usage": usage]
        return try decode(object)
    }

    @Test func newestMeasurementWins() throws {
        let older = try item(
            id: "older", order: 1,
            usage: ["inputTokens": 1_000, "contextWindow": 200_000])
        let newer = try item(
            id: "newer", order: 2,
            usage: [
                "inputTokens": 50_000,
                "cacheReadTokens": 1_000,
                "contextWindow": 200_000,
                "model": "claude-opus-5-5",
            ])

        let estimate = ContextUsageEstimate.resolve(
            items: [older, newer], catalogWindow: nil)

        #expect(estimate?.totalTokens == 51_000)
        #expect(estimate?.maxTokens == 200_000)
        #expect(estimate?.percentUsed == 26)
        #expect(estimate?.model == "claude-opus-5-5")
        #expect(estimate?.isEstimate == true)
        #expect(estimate?.hasBreakdown == false)
    }

    @Test func catalogWindowFillsMissingRowWindow() throws {
        let row = try item(id: "row", order: 1, usage: ["inputTokens": 1_000])

        let estimate = ContextUsageEstimate.resolve(
            items: [row], catalogWindow: 100_000)

        #expect(estimate?.maxTokens == 100_000)
        #expect(estimate?.percentUsed == 1)
    }

    @Test func missingWindowYieldsNoEstimate() throws {
        let row = try item(id: "row", order: 1, usage: ["inputTokens": 1_000])

        #expect(ContextUsageEstimate.resolve(items: [row], catalogWindow: nil) == nil)
    }

    @Test func zeroUsageIsNotAMeasurement() throws {
        let zero = try item(
            id: "zero", order: 3,
            usage: ["inputTokens": 0, "contextWindow": 200_000])
        let real = try item(
            id: "real", order: 1,
            usage: ["inputTokens": 2_000, "contextWindow": 200_000])

        let estimate = ContextUsageEstimate.resolve(
            items: [real, zero], catalogWindow: nil)

        #expect(estimate?.totalTokens == 2_000)
    }

    @Test func catalogWindowFollowsSelectionAndReasoningEntries() throws {
        let model = try decode([
            "runtime": "claude",
            "revision": 1,
            "models": [
                [
                    "id": "opus", "displayName": "Opus", "selectionId": "sel_opus",
                    "default": false, "reasoningItems": [],
                    "metadata": ["contextWindow": 200_000],
                ],
                [
                    "id": "sonnet", "displayName": "Sonnet",
                    "selectionId": "sel_sonnet", "default": false,
                    "reasoningItems": [
                        [
                            "id": "high", "displayName": "High",
                            "fullModelId": "sonnet-high",
                            "selectionId": "sel_sonnet_high", "default": false,
                            "metadata": [:],
                        ]
                    ],
                    "metadata": ["contextWindow": 1_000_000],
                ],
            ],
        ], as: V2ModelCatalog.self)
        let permission = try decode([
            "runtime": "claude",
            "revision": 1,
            "permissions": [],
        ], as: V2PermissionCatalog.self)
        let catalogs = V2SessionCatalogs(model: model, permission: permission)

        #expect(ContextUsageEstimate.catalogWindow(catalogs, selection: "sel_opus")
            == 200_000)
        // A reasoning sub-entry inherits its parent model's window.
        #expect(ContextUsageEstimate.catalogWindow(catalogs, selection: "sel_sonnet_high")
            == 1_000_000)
        #expect(ContextUsageEstimate.catalogWindow(catalogs, selection: "sel_unknown") == nil)
        #expect(ContextUsageEstimate.catalogWindow(catalogs, selection: nil) == nil)
    }

    @Test func inputOrderDoesNotMatter() throws {
        let first = try item(
            id: "first", order: 1,
            usage: ["inputTokens": 1_000, "contextWindow": 200_000])
        let second = try item(
            id: "second", order: 2,
            usage: ["inputTokens": 5_000, "contextWindow": 200_000])

        #expect(ContextUsageEstimate.resolve(items: [second, first], catalogWindow: nil)?
            .totalTokens == 5_000)
        #expect(ContextUsageEstimate.resolve(items: [first, second], catalogWindow: nil)?
            .totalTokens == 5_000)
    }
}
