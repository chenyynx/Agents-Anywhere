import Foundation
import Testing
@testable import ClientCore

/// Stage B coverage for the composer ring's arithmetic and wire parsing
/// (context-usage-ring §3): level boundary edges, percent rounding, 万
/// formatting, the usage block's parse, catalog windows, the pick of the
/// newest usage-bearing item (every carrier kind) and the §8 v3 window
/// precedence — the window carried by the usage always beats the catalog
/// fallback.
@Suite struct ContextUsageTests {
    // MARK: ContextLevel

    @Test func levelBoundariesIncludeExactEdges() {
        let cases: [(fraction: Double, level: ContextLevel)] = [
            (0, .comfortable), (0.399, .comfortable),
            (0.40, .normal), (0.599, .normal),
            (0.60, .elevated), (0.749, .elevated),
            (0.75, .tight), (0.899, .tight),
            (0.90, .critical), (1, .critical),
        ]
        for value in cases {
            #expect(ContextLevel(fraction: value.fraction) == value.level)
        }
    }

    @Test func levelEdgesFromRealCounts() {
        // The same edges as the ring computes them: 40/100 lands on 正常,
        // 60/100 on 偏高, 75/100 on 紧张, 90/100 on 将满 — never the level below.
        let cases: [(used: Int, total: Int, level: ContextLevel)] = [
            (39, 100, .comfortable), (40, 100, .normal),
            (59, 100, .normal), (60, 100, .elevated),
            (74, 100, .elevated), (75, 100, .tight),
            (89, 100, .tight), (90, 100, .critical),
        ]
        for value in cases {
            let fraction = ContextUsage(used: value.used, total: value.total).fraction
            #expect(ContextLevel(fraction: fraction) == value.level)
        }
    }

    @Test func levelsOrderForTheSensoryEdge() {
        #expect(ContextLevel.allCases.count == 5)
        #expect(ContextLevel.comfortable < ContextLevel.normal)
        #expect(ContextLevel.normal < ContextLevel.elevated)
        #expect(ContextLevel.elevated < ContextLevel.tight)
        #expect(ContextLevel.tight < ContextLevel.critical)
        #expect(ContextLevel.critical >= .tight)
    }

    // MARK: ContextUsage

    @Test func remainingPercentRoundsToNearest() {
        #expect(ContextUsage(used: 0, total: 100).remainingPercent == 100)
        #expect(ContextUsage(used: 6, total: 100).remainingPercent == 94)
        #expect(ContextUsage(used: 16, total: 100).remainingPercent == 84)
        // 87.5 rounds away from zero.
        #expect(ContextUsage(used: 125, total: 1000).remainingPercent == 88)
        #expect(ContextUsage(used: 100, total: 100).remainingPercent == 0)
    }

    @Test func overspentUsageClampsToFull() {
        let usage = ContextUsage(used: 130_000, total: 100_000)
        #expect(usage.isValid)
        #expect(usage.fraction == 1)
        #expect(usage.remainingPercent == 0)
        #expect(ContextLevel(fraction: usage.fraction) == .critical)
    }

    @Test func zeroTotalIsNotValidAndReadsAsEmpty() {
        let usage = ContextUsage(used: 40, total: 0)
        #expect(!usage.isValid)
        #expect(usage.fraction == 0)
        #expect(usage.remainingPercent == 100)
    }

    // MARK: TokenFormat

    @Test func tokenFormatFollowsTheDesignRule() {
        #expect(TokenFormat.wan(0) == "0")
        #expect(TokenFormat.wan(999) == "999")
        #expect(TokenFormat.wan(1000) == "0.1万")
        #expect(TokenFormat.wan(9999) == "1万")
        #expect(TokenFormat.wan(10000) == "1万")
        #expect(TokenFormat.wan(16000) == "1.6万")
        #expect(TokenFormat.wan(26000) == "2.6万")
        #expect(TokenFormat.wan(105000) == "10.5万")
        #expect(TokenFormat.wan(260000) == "26万")
    }

    // MARK: V2MessageUsage parsing

    @Test func usageParsesTheWireCounters() {
        let content = V2MessageContent(rawContent: .object(["usage": .object([
            "inputTokens": .number(123), "outputTokens": .number(456),
            "cacheReadTokens": .number(789), "cacheCreationTokens": .number(12),
        ])]))
        #expect(content.usage == V2MessageUsage(inputTokens: 123, outputTokens: 456,
                                                cacheReadTokens: 789, cacheCreationTokens: 12))
        #expect(content.usage?.contextTokens == 1380)
    }

    @Test func usageMissingKeysReadZero() {
        let partial = V2MessageContent(rawContent: .object(["usage": .object(["inputTokens": .number(5)])]))
        #expect(partial.usage == V2MessageUsage(inputTokens: 5, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0))
    }

    @Test func usageForeignShapesAreRejected() {
        // The key name `usage` is not ours alone: an agent-call card carries
        // subagent totals (`tokens` / `toolCalls` / `durationMs`) under it,
        // and an empty object measures nothing. Neither may parse as a
        // zeroed context — that would report an empty window as real.
        let subagentTotals = V2MessageContent(rawContent: .object(["usage": .object([
            "tokens": .number(1234), "toolCalls": .number(5), "durationMs": .number(60_000),
        ])]))
        #expect(subagentTotals.usage == nil)
        #expect(V2MessageContent(rawContent: .object(["usage": .object([:])])).usage == nil)
    }

    @Test func usageAbsentIsNil() {
        #expect(V2MessageContent(rawContent: .object(["text": .string("Hi")])).usage == nil)
        #expect(V2MessageContent(rawContent: .object(["usage": .null])).usage == nil)
        #expect(V2MessageContent(rawContent: .object(["usage": .string("123")])).usage == nil)
        #expect(V2MessageContent(rawContent: .object(["usage": .array([])])).usage == nil)
    }

    @Test func usageNonIntegerCountersAreNil() {
        for value in [JSONValue.number(12.5), .string("123"), .bool(true), .null, .object([:])] {
            let content = V2MessageContent(rawContent: .object(["usage": .object(["outputTokens": value])]))
            #expect(content.usage == nil)
        }
    }

    @Test func usageParsesThroughTheItemDecoder() throws {
        let item = try timelineItem(id: "a", order: 1,
            usage: ["inputTokens": 10, "outputTokens": 20, "cacheReadTokens": 30, "cacheCreationTokens": 40])
        let content = try #require(messageContent(item))
        #expect(content.usage?.contextTokens == 100)
        // The carrier-agnostic accessor reads the same block.
        #expect(item.usage?.contextTokens == 100)
        let reasoning = try timelineItem(id: "r", order: 2, type: "reasoning", usage: ["inputTokens": 7])
        #expect(reasoning.usage?.contextTokens == 7)
    }

    @Test func usageParsesTheEngineStampedModelAndWindow() {
        // §8 v3: the connector stamps the engine's self-reported model and
        // context window into the usage block, so the ring can pair them with
        // the counters of the same report.
        let content = V2MessageContent(rawContent: .object(["usage": .object([
            "inputTokens": .number(10), "outputTokens": .number(20),
            "cacheReadTokens": .number(30), "cacheCreationTokens": .number(40),
            "model": .string("deepseek-v4.1-flash"), "contextWindow": .number(1_000_000),
        ])]))
        #expect(content.usage == V2MessageUsage(inputTokens: 10, outputTokens: 20,
                                                cacheReadTokens: 30, cacheCreationTokens: 40,
                                                model: "deepseek-v4.1-flash", contextWindow: 1_000_000))
        #expect(content.usage?.model == "deepseek-v4.1-flash")
        #expect(content.usage?.contextWindow == 1_000_000)
    }

    @Test func usageParsesTheEngineStampsThroughTheItemDecoder() throws {
        let item = try timelineItem(id: "a", order: 1, usage: [
            "inputTokens": 15_600, "model": "deepseek-v4.1-flash", "contextWindow": 1_000_000,
        ])
        #expect(item.usage?.model == "deepseek-v4.1-flash")
        #expect(item.usage?.contextWindow == 1_000_000)
        #expect(item.usage?.contextTokens == 15_600)
    }

    @Test func usageWithoutEngineMetadataReadsNilForThoseFields() {
        // Old data (and runtimes that never report a window) omits the keys.
        let content = V2MessageContent(rawContent: .object(["usage": .object(["inputTokens": .number(5)])]))
        #expect(content.usage != nil)
        #expect(content.usage?.model == nil)
        #expect(content.usage?.contextWindow == nil)
    }

    @Test func usageMalformedEngineMetadataReadsNilForThatFieldAlone() {
        // A malformed value must read nil for its own field but never break
        // the counters: `model` is a strict string (stringValue would
        // stringify numbers and bools), and `contextWindow` a strict whole
        // number.
        for value in [JSONValue.number(123), .bool(true), .object([:]), .array([]), .null] {
            let content = V2MessageContent(rawContent: .object(["usage": .object([
                "inputTokens": .number(5), "model": value,
            ])]))
            #expect(content.usage?.model == nil)
            #expect(content.usage?.contextTokens == 5)
        }
        // An empty id names no model.
        let emptyModel = V2MessageContent(rawContent: .object(["usage": .object([
            "inputTokens": .number(5), "model": .string(""),
        ])]))
        #expect(emptyModel.usage?.model == nil)
        for value in [JSONValue.string("1000000"), .number(999_999.5), .bool(true), .object([:]), .array([]), .null] {
            let content = V2MessageContent(rawContent: .object(["usage": .object([
                "inputTokens": .number(5), "contextWindow": value,
            ])]))
            #expect(content.usage?.contextWindow == nil)
            #expect(content.usage?.contextTokens == 5)
        }
    }

    @Test func usageEngineMetadataAloneDoesNotSatisfyTheShapeGate() {
        // The four-counter shape gate stands: metadata keys never turn a
        // foreign shape into a usage object.
        let metadataOnly = V2MessageContent(rawContent: .object(["usage": .object([
            "model": .string("deepseek-v4.1-flash"), "contextWindow": .number(1_000_000),
        ])]))
        #expect(metadataOnly.usage == nil)
        let foreign = V2MessageContent(rawContent: .object(["usage": .object([
            "tokens": .number(1234), "model": .string("x"), "contextWindow": .number(1000),
        ])]))
        #expect(foreign.usage == nil)
    }

    // MARK: ContextWindowIndex

    @Test func windowIndexMapsModelsAndReasoningChildren() throws {
        let index = ContextWindowIndex(try catalogs(models: [
            model("claude-opus", selection: "sel_opus", window: 200_000,
                reasoning: [reasoningItem("high", selection: "sel_opus_high")]),
            model("claude-sonnet-1m", selection: "sel_sonnet", window: 1_000_000),
        ]))
        #expect(index.contextWindow(forSelection: "sel_opus") == 200_000)
        // A reasoning-item selection stands for its parent model.
        #expect(index.contextWindow(forSelection: "sel_opus_high") == 200_000)
        #expect(index.contextWindow(forSelection: "sel_sonnet") == 1_000_000)
        #expect(index.contextWindow(forSelection: nil) == nil)
        #expect(index.contextWindow(forSelection: "sel_unknown") == nil)
    }

    @Test func windowIndexHidesMissingWindowMetadata() throws {
        let index = ContextWindowIndex(try catalogs(models: [
            model("gateway-custom", selection: "sel_custom"),
            model("string-window", selection: "sel_string", window: "200000"),
            model("fractional-window", selection: "sel_fraction", window: 200_000.5),
        ]))
        #expect(index.contextWindow(forSelection: "sel_custom") == nil)
        #expect(index.contextWindow(forSelection: "sel_string") == nil)
        #expect(index.contextWindow(forSelection: "sel_fraction") == nil)
    }

    @Test func windowIndexSkipsDisabledEntries() throws {
        // Mirrors ConversationSettings.modelID(forSelection:): a disabled
        // model — metadata or field — is not an offered selection.
        let index = ContextWindowIndex(try catalogs(models: [
            model("off", selection: "sel_off", window: 200_000, enabled: false,
                reasoning: [reasoningItem("high", selection: "sel_off_high")]),
            model("metadata-off", selection: "sel_meta_off", window: 200_000, metadataEnabled: false),
        ]))
        #expect(index.contextWindow(forSelection: "sel_off") == nil)
        #expect(index.contextWindow(forSelection: "sel_off_high") == nil)
        #expect(index.contextWindow(forSelection: "sel_meta_off") == nil)
    }

    // MARK: newest-usage selection

    @Test func usedPicksTheNewestUsageByOrder() throws {
        let items = [
            try timelineItem(id: "a1", order: 1, usage: counters(input: 10, cacheRead: 5)),
            try timelineItem(id: "a2", order: 4, usage: counters(input: 20, output: 30)),
            try timelineItem(id: "a3", order: 2, usage: counters(input: 999)),
        ]
        #expect(ContextUsage.used(in: items) == 50)
        // Ordering is by `orderSeq`, not by position in the window.
        #expect(ContextUsage.used(in: items.shuffled()) == 50)
    }

    @Test func usedTakesTheNewestCarrierWithUsage() throws {
        // Any carrier kind counts: a reasoning item evolved by a later API
        // call beats the earlier assistant message and tool items.
        let items = [
            try timelineItem(id: "message", order: 2, usage: counters(input: 300)),
            try timelineItem(id: "tool", order: 3, type: "tool", usage: counters(input: 200)),
            try timelineItem(id: "reasoning", order: 5, type: "reasoning", usage: counters(input: 400)),
        ]
        #expect(ContextUsage.used(in: items) == 400)
        #expect(ContextUsage.used(in: items.shuffled()) == 400)
    }

    @Test func usedPicksToolCarrierWhenNewest() throws {
        let items = [
            try timelineItem(id: "message", order: 3, usage: counters(input: 300)),
            try timelineItem(id: "tool", order: 9, type: "tool", usage: counters(input: 250)),
        ]
        #expect(ContextUsage.used(in: items) == 250)
    }

    @Test func usedSkipsCarriersWithoutUsage() throws {
        let items = [
            try timelineItem(id: "message", order: 9),
            try timelineItem(id: "reasoning", order: 10, type: "reasoning"),
            try timelineItem(id: "tool", order: 11, type: "tool"),
            try timelineItem(id: "message2", order: 7, usage: counters(input: 300)),
        ]
        #expect(ContextUsage.used(in: items) == 300)
    }

    @Test func usedIsStableWhenCarriersAgree() throws {
        // One API call stamped on carriers of the same turn: whichever item
        // wins the pick, the value agrees, so the ring never flickers.
        let message = try timelineItem(id: "message", order: 4, usage: counters(input: 500))
        let reasoning = try timelineItem(id: "reasoning", order: 6, type: "reasoning", usage: counters(input: 500))
        #expect(ContextUsage.used(in: [message, reasoning]) == 500)
        #expect(ContextUsage.used(in: [reasoning, message]) == 500)
        let tied = try timelineItem(id: "tied", order: 4, type: "reasoning", usage: counters(input: 500))
        #expect(ContextUsage.used(in: [message, tied]) == 500)
        #expect(ContextUsage.used(in: [tied, message]) == 500)
    }

    @Test func usedPrefersHistoryOverStreamingWithoutUsage() throws {
        // A live frame that has not attached usage yet must not shadow the
        // newest historical item that carries one.
        let items = [
            try timelineItem(id: "older", order: 1, usage: counters(input: 100)),
            try timelineItem(id: "history", order: 2, usage: counters(input: 300)),
            try timelineItem(id: "live", order: 5),
        ]
        #expect(ContextUsage.used(in: items) == 300)
    }

    @Test func usedIsNilWithoutAnyUsage() throws {
        let message = try timelineItem(id: "a", order: 1)
        let reasoning = try timelineItem(id: "r", order: 2, type: "reasoning")
        #expect(ContextUsage.used(in: []) == nil)
        #expect(ContextUsage.used(in: [message]) == nil)
        #expect(ContextUsage.used(in: [reasoning]) == nil)
    }

    // MARK: latestUsage and the window precedence (§8 v3)

    @Test func latestUsageReturnsTheNewestCarriersWholeObject() throws {
        // The pick is a whole-usage decision, not a per-field one: counters
        // and the engine's window always come from the same report.
        let items = [
            try timelineItem(id: "old", order: 1,
                usage: ["inputTokens": 100, "model": "old-model", "contextWindow": 200_000]),
            try timelineItem(id: "new", order: 7,
                usage: ["inputTokens": 200, "model": "deepseek-v4.1-flash", "contextWindow": 1_000_000]),
        ]
        #expect(ContextUsage.latestUsage(in: items) == V2MessageUsage(
            inputTokens: 200, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
            model: "deepseek-v4.1-flash", contextWindow: 1_000_000))
        #expect(ContextUsage.latestUsage(in: items.shuffled())?.model == "deepseek-v4.1-flash")
        // `used(in:)` stays the thin sum of the same pick.
        #expect(ContextUsage.used(in: items) == 200)
    }

    @Test func latestUsageIsNilWithoutAnyUsage() throws {
        #expect(ContextUsage.latestUsage(in: []) == nil)
        #expect(ContextUsage.latestUsage(in: [try timelineItem(id: "a", order: 1)]) == nil)
    }

    @Test func usedSkipsANewerAllZeroCarrier() throws {
        // A live row can carry a zeroed seed after a real report; it is not a
        // measurement, so it must not shadow the older real carrier and flip
        // the ring to 0.
        let items = [
            try timelineItem(id: "real", order: 2, usage: counters(input: 300)),
            try timelineItem(id: "zero", order: 5, usage: counters()),
        ]
        #expect(ContextUsage.latestUsage(in: items)?.contextTokens == 300)
        #expect(ContextUsage.used(in: items) == 300)
        #expect(ContextUsage.used(in: items.shuffled()) == 300)
    }

    @Test func usedIsNilWhenEveryCarrierIsZero() throws {
        // Nothing real to measure: the ring stays hidden rather than showing a
        // fabricated empty context.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        let items = [
            try timelineItem(id: "seed", order: 3, usage: counters()),
            try timelineItem(id: "live", order: 6, usage: counters()),
        ]
        #expect(ContextUsage.latestUsage(in: items) == nil)
        #expect(ContextUsage.used(in: items) == nil)
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "sel") == nil)
    }

    @Test func resolvePrefersTheRealUsagesWindowOverTheCatalog() throws {
        // Regression (§8 v3): a real usage that carries a `contextWindow`
        // still beats the catalog window — skipping zero carriers changes
        // only which carrier wins, never the window precedence.
        let index = ContextWindowIndex(try catalogs(models: [model("nominal", selection: "sel", window: 200_000)]))
        let items = [
            try timelineItem(id: "real", order: 2, usage: [
                "inputTokens": 15_600, "model": "deepseek-v4.1-flash", "contextWindow": 1_000_000,
            ]),
            try timelineItem(id: "zero", order: 5, usage: counters()),
        ]
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "sel")
            == ContextUsage(used: 15_600, total: 1_000_000))
    }

    @Test func latestUsagePicksTheNewestRealCarrierAcrossKinds() throws {
        // Regression: every carrier kind still competes on `orderSeq` when the
        // usages are real; a zero seed on the newest item does not stop a
        // mixed-kind real carrier from winning.
        let items = [
            try timelineItem(id: "message", order: 2, usage: counters(input: 300)),
            try timelineItem(id: "tool", order: 3, type: "tool", usage: counters(input: 200)),
            try timelineItem(id: "reasoning", order: 5, type: "reasoning", usage: counters(input: 400)),
            try timelineItem(id: "seed", order: 6, type: "reasoning", usage: counters()),
        ]
        #expect(ContextUsage.latestUsage(in: items)?.contextTokens == 400)
        #expect(ContextUsage.used(in: items) == 400)
    }


    @Test func resolvePrefersTheUsageCarriedWindowOverTheCatalog() throws {
        // §8 v3: window and measurement travel together, so the stamped
        // window wins even when the catalog names a different (nominal) one —
        // the gateway case the catalog cannot describe.
        let index = ContextWindowIndex(try catalogs(models: [model("nominal", selection: "sel", window: 200_000)]))
        let items = [try timelineItem(id: "a", order: 1, usage: [
            "inputTokens": 15_600, "model": "deepseek-v4.1-flash", "contextWindow": 1_000_000,
        ])]
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "sel")
            == ContextUsage(used: 15_600, total: 1_000_000))
    }

    @Test func resolveUsageWindowCoversMissingSelectionAndIndex() throws {
        // The usage-carried window needs no catalog at all, so the empty
        // selection — a session on its default model, possibly a gateway one —
        // still resolves a real total.
        let items = [try timelineItem(id: "a", order: 1, usage: [
            "inputTokens": 10, "contextWindow": 1_000_000,
        ])]
        #expect(ContextUsage.resolve(items: items, windows: nil, selection: nil)
            == ContextUsage(used: 10, total: 1_000_000))
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        #expect(ContextUsage.resolve(items: items, windows: index, selection: nil)
            == ContextUsage(used: 10, total: 1_000_000))
    }

    @Test func resolveFallsBackToTheCatalogOnlyWithoutAUsageWindow() throws {
        // Data stamped before the connector reported windows keeps working
        // through the catalog; with neither side known the ring stays hidden.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        let items = [try timelineItem(id: "a", order: 1, usage: counters(input: 42))]
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "sel")
            == ContextUsage(used: 42, total: 200_000))
        #expect(ContextUsage.resolve(items: items, windows: nil, selection: "sel") == nil)
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "other") == nil)
        #expect(ContextUsage.resolve(items: [], windows: index, selection: "sel") == nil)
    }

    @Test func resolveNeverPairsAnOlderCarriersWindowWithTheNewestMeasurement() throws {
        // Once the newest carrier carries no window, the fallback is the
        // catalog — never a window from an older engine report, which would
        // mispair a stale window with a fresh measurement.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        let items = [
            try timelineItem(id: "old", order: 1, usage: ["inputTokens": 100, "contextWindow": 1_000_000]),
            try timelineItem(id: "new", order: 2, usage: counters(input: 200)),
        ]
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "sel")
            == ContextUsage(used: 200, total: 200_000))
        #expect(ContextUsage.resolve(items: items, windows: nil, selection: "sel") == nil)
    }

    @Test func resolveCombinesUsageAndWindow() throws {
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 1000)]))
        let items = [try timelineItem(id: "a", order: 1, usage: counters(input: 200, output: 150, cacheRead: 50))]
        let resolved = ContextUsage.resolve(items: items, windows: index, selection: "sel")
        #expect(resolved == ContextUsage(used: 400, total: 1000))
        #expect(resolved?.fraction == 0.4)
        #expect(resolved.map { ContextLevel(fraction: $0.fraction) } == .normal)
        // Either side missing keeps the ring hidden.
        #expect(ContextUsage.resolve(items: items, windows: index, selection: "other") == nil)
        #expect(ContextUsage.resolve(items: items, windows: nil, selection: "sel") == nil)
        #expect(ContextUsage.resolve(items: [], windows: index, selection: "sel") == nil)
    }

    // MARK: ContextRingState.resolve (the three-way composer state)

    @Test func ringStateIsUnknownWindowWhenAMeasurementHasNoWindow() throws {
        // pp 2026-10-08: a real measurement with no known window (a gateway
        // model whose catalog has no window, before the first calibration)
        // must not vanish. It resolves to the unknown state carrying the real
        // `used` — not nil (which hid the ring) and not a fabricated 0-total.
        let index = ContextWindowIndex(try catalogs(models: [model("gateway", selection: "sel_gateway")]))
        let items = [try timelineItem(id: "a", order: 1, usage: counters(input: 15_600))]
        #expect(ContextRingState.resolve(items: items, windows: index, selection: "sel_gateway")
            == .unknownWindow(used: 15_600))
        // Same with no catalog at all, and with a selection the catalog cannot
        // describe — both are the pre-calibration gateway case.
        #expect(ContextRingState.resolve(items: items, windows: nil, selection: "sel_gateway")
            == .unknownWindow(used: 15_600))
        #expect(ContextRingState.resolve(items: items, windows: index, selection: "other")
            == .unknownWindow(used: 15_600))
        // The state is visible and carries no complete usage.
        #expect(ContextRingState.unknownWindow(used: 15_600).isVisible)
        #expect(ContextRingState.unknownWindow(used: 15_600).usage == nil)
    }

    @Test func ringStateIsReadyWhenTheMeasurementCarriesItsWindow() throws {
        // Regression (§8 v3): the window stamped with the usage always wins,
        // even over a catalog that names a different (nominal) one.
        let index = ContextWindowIndex(try catalogs(models: [model("nominal", selection: "sel", window: 200_000)]))
        let items = [try timelineItem(id: "a", order: 1, usage: [
            "inputTokens": 15_600, "model": "deepseek-v4.1-flash", "contextWindow": 1_000_000,
        ])]
        let state = ContextRingState.resolve(items: items, windows: index, selection: "sel")
        #expect(state == .ready(ContextUsage(used: 15_600, total: 1_000_000)))
        #expect(state.usage == ContextUsage(used: 15_600, total: 1_000_000))
        #expect(state.isVisible)
    }

    @Test func ringStateIsReadyFromTheCatalogWindow() throws {
        // Regression: data stamped before the connector reported windows still
        // resolves through the catalog fallback.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        let items = [try timelineItem(id: "a", order: 1, usage: counters(input: 42))]
        #expect(ContextRingState.resolve(items: items, windows: index, selection: "sel")
            == .ready(ContextUsage(used: 42, total: 200_000)))
    }

    @Test func ringStateIsHiddenWithoutAnyMeasurement() throws {
        // A brand-new session (no usage) stays hidden — unchanged: the ring
        // appears only once there is something real to show.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        #expect(ContextRingState.resolve(items: [], windows: index, selection: "sel") == .hidden)
        let bare = [try timelineItem(id: "a", order: 1)]
        #expect(ContextRingState.resolve(items: bare, windows: index, selection: "sel") == .hidden)
        #expect(!ContextRingState.hidden.isVisible)
        #expect(ContextRingState.hidden.usage == nil)
    }

    @Test func ringStateSkipsAnAllZeroCarrier() throws {
        // Regression of the earlier fix: an all-zero carrier is not a
        // measurement. The newest real carrier wins, and when *every* carrier
        // is zero the state is hidden — never an unknown state with a
        // fabricated zero.
        let index = ContextWindowIndex(try catalogs(models: [model("m", selection: "sel", window: 200_000)]))
        let items = [
            try timelineItem(id: "real", order: 2, usage: counters(input: 300)),
            try timelineItem(id: "zero", order: 5, usage: counters()),
        ]
        #expect(ContextRingState.resolve(items: items, windows: index, selection: "sel")
            == .ready(ContextUsage(used: 300, total: 200_000)))
        // No window anywhere: the newest real (nonzero) carrier is the
        // measurement, so the unknown state carries 300 — not the zero seed.
        #expect(ContextRingState.resolve(items: items, windows: nil, selection: "sel")
            == .unknownWindow(used: 300))
        let allZero = [
            try timelineItem(id: "seed", order: 3, usage: counters()),
            try timelineItem(id: "live", order: 6, usage: counters()),
        ]
        #expect(ContextRingState.resolve(items: allZero, windows: index, selection: "sel") == .hidden)
    }

    // MARK: Fixtures

    private func counters(input: Int = 0, output: Int = 0, cacheRead: Int = 0, cacheCreation: Int = 0) -> [String: Any] {
        ["inputTokens": input, "outputTokens": output, "cacheReadTokens": cacheRead, "cacheCreationTokens": cacheCreation]
    }

    private func timelineItem(id: String, order: Int, role: String? = "assistant", type: String = "message",
                      usage: [String: Any]? = nil) throws -> V2TimelineItem {
        var content: [String: Any] = ["text": "Hi"]
        if let usage { content["usage"] = usage }
        var object: [String: Any] = ["id": id, "sessionId": "session", "type": type, "status": "done",
                                     "content": content, "orderSeq": order, "revision": 1, "updatedSeq": order,
                                     "contentHash": id]
        if let role { object["role"] = role }
        return try decode(object)
    }

    private func messageContent(_ item: V2TimelineItem) -> V2MessageContent? {
        if case let .message(content) = item.content { return content }
        return nil
    }

    private func model(_ id: String, selection: String, window: Any? = nil, enabled: Bool? = nil,
                       metadataEnabled: Bool? = nil, reasoning: [[String: Any]] = []) -> [String: Any] {
        var metadata: [String: Any] = [:]
        if let window { metadata["contextWindow"] = window }
        if let metadataEnabled { metadata["enabled"] = metadataEnabled }
        var object: [String: Any] = ["id": id, "displayName": id, "default": false, "selectionId": selection,
                                     "reasoningItems": reasoning, "metadata": metadata]
        if let enabled { object["enabled"] = enabled }
        return object
    }

    private func reasoningItem(_ id: String, selection: String) -> [String: Any] {
        ["id": id, "displayName": id, "default": false, "selectionId": selection, "metadata": [:]]
    }

    private func catalogs(models: [[String: Any]]) throws -> V2SessionCatalogs {
        let model: V2ModelCatalog = try decode(["runtime": "claude", "revision": 1, "models": models])
        let permission: V2PermissionCatalog = try decode(["runtime": "claude", "revision": 1, "permissions": []])
        return V2SessionCatalogs(model: model, permission: permission)
    }
}
