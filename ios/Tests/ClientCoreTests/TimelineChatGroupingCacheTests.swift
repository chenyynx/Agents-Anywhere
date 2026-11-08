import Foundation
import Testing
@testable import ClientCore

/// The incremental cache must be indistinguishable from the full grouping:
/// for every input and every mutation the units have to match field for
/// field. Random sequences with a seeded generator, so a failure reproduces.
@MainActor
struct TimelineChatGroupingCacheTests {
    @Test func randomMutationsMatchTheFullGrouping() throws {
        var rng = SeededGenerator(seed: 0x5EED_1234)
        var cache = TimelineChatGroupingCache()

        // The cache survives a round, so the model of "the previous returned
        // array" must survive too: a round's first call can legitimately reuse
        // a prefix from the previous round's last call, and comparing that
        // against an empty array would fail without a product bug.
        var previousReturned: [TimelineChatUnit] = []
        for _ in 0..<25 {
            var specs = randomSpecs(count: Int.random(in: 0...30, using: &rng), rng: &rng)
            var targets: Set<String> = []
            var cwd: String? = Bool.random(using: &rng) ? "/tmp/work" : nil

            var previousSpecs: [RowSpec] = []
            for iteration in 0..<20 {
                let specsForThisCall = specs
                let items = try specs.map(makeItem)
                let incremental = cache.units(items: items,
                                              profile: .generic,
                                              interactionTargets: targets,
                                              cwd: cwd)
                // The adapter reuses what it built from the previous result,
                // so the cache's advertised prefix must be that exact prefix.
                if cache.reusableUnitCount > 0 {
                    #expect(cache.reusableUnitCount <= incremental.count)
                    #expect(Array(incremental.prefix(cache.reusableUnitCount))
                            == Array(previousReturned.prefix(cache.reusableUnitCount)))
                }
                let full = TimelineChatGrouping.units(items: items,
                                                      profile: .generic,
                                                      interactionTargets: targets,
                                                      cwd: cwd)
                if incremental != full, let divergence = firstDivergence(incremental, full) {
                    // sourceItemID is part of the dump: appended rows carry a
                    // "tail<order>" item id that reorders rewrite, and without
                    // it an offline replay cannot rebuild the message key.
                    let specsText = specs.map {
                        "\($0.id)|\($0.order)|\(String(describing: $0.kind))|\($0.turn ?? "-")|\($0.status)|\($0.nativeMessageID ?? "-")|\($0.parentItemID ?? "-")|\($0.sourceItemID ?? "-")|\($0.revision)"
                    }.joined(separator: ";")
                    let previousText = previousSpecs.map {
                        "\($0.id)|\($0.order)|\(String(describing: $0.kind))|\($0.turn ?? "-")|\($0.status)|\($0.nativeMessageID ?? "-")|\($0.parentItemID ?? "-")|\($0.sourceItemID ?? "-")|\($0.revision)"
                    }.joined(separator: ";")
                    let incrementalText = incremental.map(describe).joined(separator: " || ")
                    let fullText = full.map(describe).joined(separator: " || ")
                    Issue.record("DIVERGENCE round \(iteration) rows=\(items.count) targets=\(targets.sorted()) cwd=\(cwd ?? "-") previous=\(previousText) specs=\(specsText) incremental=\(incrementalText) full=\(fullText) first=\(divergence)")
                }
                #expect(incremental == full)
                previousReturned = incremental
                previousSpecs = specsForThisCall
                mutate(&specs, targets: &targets, rng: &rng)
            }
        }
    }

    /// The cache re-groups only the suffix that starts at the first changed
    /// unit, but the full pass carries the declared turn from every earlier
    /// row. A suffix pass that starts from "no turn" misses the turn change at
    /// the first declaring row in the suffix and keeps a message/step group
    /// merged that the full pass splits. CI caught this as `msg(m4)` gaining
    /// the next turn's rows in the incremental result.
    @Test func suffixGroupingInheritsTheDeclaredTurn() throws {
        func message(_ id: String, order: Int, turn: String?) -> RowSpec {
            RowSpec(id: id, order: order, kind: .assistantMessage, text: "line \(order)",
                    turn: turn, status: "running", revision: 1, updatedSeq: order,
                    parentItemID: nil, nativeMessageID: "m1", sourceItemID: "src\(order)")
        }
        func reasoning(_ id: String, order: Int, turn: String?) -> RowSpec {
            RowSpec(id: id, order: order, kind: .reasoning, text: "line \(order)",
                    turn: turn, status: "running", revision: 1, updatedSeq: order,
                    parentItemID: nil, nativeMessageID: nil, sourceItemID: "src\(order)")
        }
        // `a` declares t1; `b` carries no turn and starts the unit the cache
        // will re-group; `c` declares t2 and must split the message there.
        let a = reasoning("a", order: 0, turn: "t1")
        let b = message("b", order: 1, turn: nil)
        let c = message("c", order: 2, turn: "t2")
        let d = message("d", order: 3, turn: nil)

        var cache = TimelineChatGroupingCache()
        _ = cache.units(items: try [a, b].map(makeItem), profile: .generic,
                        interactionTargets: [], cwd: nil)

        let grown = try [a, b, c, d].map(makeItem)
        let incremental = cache.units(items: grown, profile: .generic,
                                      interactionTargets: [], cwd: nil)
        let full = TimelineChatGrouping.units(items: grown, profile: .generic,
                                              interactionTargets: [], cwd: nil)
        #expect(incremental == full)
        // Only the step group before the first change is carried over; the
        // adapter may reuse its built values and must rebuild the rest.
        #expect(cache.reusableUnitCount == 1)
        // The same input again must not drift either.
        #expect(cache.units(items: grown, profile: .generic,
                            interactionTargets: [], cwd: nil) == full)
        #expect(cache.reusableUnitCount == full.count)
    }

    /// A deferred summary row and the complete row it stands for share
    /// `revision`/`updatedSeq`/`contentHash` by protocol (server
    /// `build_stub_content`), so every other fingerprinted field is equal even
    /// though `raw` differs. Tapping a step swaps the stub for the complete
    /// row in place; if the fingerprint cannot tell them apart the cache
    /// returns the stub's step payload and the detail row keeps the truncated
    /// command / missing diff forever.
    @Test func deferredSummaryAndItsCompleteRowAreNotTheSameInput() throws {
        func tool(deferred: Bool, complete: Bool) throws -> V2TimelineItem {
            var content: [String: JSONValue] = [
                "kind": .string("tool"),
                "name": .string("Bash"),
                "input": .object(["command": .string("npm run build")]),
            ]
            if complete { content["output"] = .string("build finished") }
            if deferred {
                content["deferred"] = .bool(true)
                content["deferredBytes"] = .number(4096)
            }
            return try V2TimelineItem(json: .object([
                "id": .string("t1"),
                "sessionId": .string("s"),
                "type": .string("tool"),
                "status": .string("done"),
                "content": .object(content),
                "source": .object([
                    "itemId": .string("src1"),
                    "nativeMessageId": .string("m1"),
                ]),
                "orderSeq": .number(1),
                "revision": .number(3),
                "updatedSeq": .number(3),
                "contentHash": .string("sha256:same"),
            ]))
        }
        var cache = TimelineChatGroupingCache()
        _ = cache.units(items: [try tool(deferred: true, complete: false)],
                        profile: .generic, interactionTargets: [], cwd: nil)
        let incremental = cache.units(items: [try tool(deferred: false, complete: true)],
                                      profile: .generic, interactionTargets: [], cwd: nil)
        let full = TimelineChatGrouping.units(items: [try tool(deferred: false, complete: true)],
                                              profile: .generic, interactionTargets: [], cwd: nil)
        #expect(incremental == full)
    }

    /// A rebuild (first call, changed grouping inputs, duplicates) advertises
    /// nothing as reusable; an identical input advertises every unit.
    @Test func reusablePrefixFollowsTheCachePath() throws {
        var rng = SeededGenerator(seed: 11)
        var cache = TimelineChatGroupingCache()
        let items = try randomSpecs(count: 30, rng: &rng).map(makeItem)

        let rebuilt = cache.units(items: items, profile: .generic,
                                  interactionTargets: [], cwd: nil)
        #expect(cache.reusableUnitCount == 0)
        #expect(cache.units(items: items, profile: .generic,
                            interactionTargets: [], cwd: nil) == rebuilt)
        #expect(cache.reusableUnitCount == rebuilt.count)

        // A changed profile is a rebuild, not a reused prefix.
        _ = cache.units(items: items, profile: .claudeCode, interactionTargets: [], cwd: nil)
        #expect(cache.reusableUnitCount == 0)
    }

    @Test func repeatedIdenticalInputsKeepTheUnits() throws {
        var rng = SeededGenerator(seed: 7)
        var cache = TimelineChatGroupingCache()
        let items = try randomSpecs(count: 40, rng: &rng).map(makeItem)

        let first = cache.units(items: items, profile: .generic,
                                interactionTargets: [], cwd: nil)
        for _ in 0..<5 {
            #expect(cache.units(items: items, profile: .generic,
                                interactionTargets: [], cwd: nil) == first)
        }
        #expect(first == TimelineChatGrouping.units(items: items, profile: .generic,
                                                    interactionTargets: [], cwd: nil))
    }

    private func firstDivergence(_ lhs: [TimelineChatUnit],
                                 _ rhs: [TimelineChatUnit]) -> String? {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? describe(lhs[index]) : "<missing>"
            let right = index < rhs.count ? describe(rhs[index]) : "<missing>"
            if left != right {
                return "unit \(index): incremental=\(left) full=\(right)"
            }
        }
        return nil
    }

    private func describe(_ unit: TimelineChatUnit) -> String {
        switch unit {
        case let .stepGroup(group, rowIDs):
            let steps = group.steps.map { step -> String in
                switch step {
                case let .thinking(id, text, status):
                    return "T:\(id):\(status.rawValue):\(text)"
                case let .tool(call):
                    return "C:\(call.id):\(call.status):\(call.name)"
                }
            }.joined(separator: ",")
            return "steps(\(group.id)) rows=\(rowIDs) [\(steps)] sum=\(group.summary)"
        case let .message(key, rowIDs):
            return "msg(\(key)) rows=\(rowIDs)"
        case let .standalone(rowID):
            return "single(\(rowID))"
        }
    }

    // MARK: - Specs

    private enum RowKind: CaseIterable {
        case userMessage
        case assistantMessage
        case reasoning
        case tool
        case systemReasoning
        case fileChange
        case marker
    }

    private struct RowSpec {
        var id: String
        var order: Int
        var kind: RowKind
        var text: String
        var turn: String?
        var status: String
        var revision: Int
        var updatedSeq: Int
        var parentItemID: String?
        var nativeMessageID: String?
        var sourceItemID: String?
    }

    private func randomSpecs(count: Int, rng: inout SeededGenerator) -> [RowSpec] {
        var specs: [RowSpec] = []
        var messageRun = 0
        for index in 0..<count {
            let kind = RowKind.allCases.randomElement(using: &rng) ?? .assistantMessage
            if index == 0 || kind == .userMessage {
                messageRun += 1
            }
            // Assistant body rows that share a message id merge into one unit.
            let nativeMessageID: String? =
                (kind == .assistantMessage || kind == .userMessage)
                    ? "m\(messageRun)" : nil
            specs.append(RowSpec(
                id: "i\(index)-\(Int.random(in: 0..<1000, using: &rng))",
                order: index,
                kind: kind,
                text: "line \(index)",
                turn: Int.random(in: 0..<3, using: &rng) == 0 ? nil : "t\(index / 4)",
                status: Bool.random(using: &rng) ? "running" : "done",
                revision: Int.random(in: 1...3, using: &rng),
                updatedSeq: index,
                parentItemID: Int.random(in: 0..<8, using: &rng) == 0 ? "p\(index)" : nil,
                nativeMessageID: nativeMessageID,
                sourceItemID: "src\(index)"))
        }
        return specs
    }

    private func makeItem(_ spec: RowSpec) throws -> V2TimelineItem {
        var content: [String: JSONValue] = ["text": .string(spec.text)]
        var type = "message"
        var role: String? = "assistant"
        switch spec.kind {
        case .userMessage:
            role = "user"
        case .assistantMessage:
            break
        case .reasoning:
            type = "reasoning"
            role = nil
        case .tool:
            type = "tool"
            role = nil
            content["name"] = .string("Read")
            content["kind"] = .string("tool")
        case .systemReasoning:
            type = "system"
            role = nil
            content["kind"] = .string("reasoning")
        case .fileChange:
            // The wire enum's raw value is snake_case; "fileChange" decodes
            // to `.unknown`, which silently ran these fixtures as standalone
            // rows and left the real `.fileChange` branch untested.
            type = "file_change"
            role = nil
        case .marker:
            type = "marker"
            role = nil
            content = [:]
        }
        if let parent = spec.parentItemID { content["parentItemId"] = .string(parent) }
        var source: [String: JSONValue] = [:]
        if let turn = spec.turn { source["turnId"] = .string(turn) }
        if let native = spec.nativeMessageID { source["nativeMessageId"] = .string(native) }
        if let itemID = spec.sourceItemID { source["itemId"] = .string(itemID) }
        var json: [String: JSONValue] = [
            "id": .string(spec.id),
            "sessionId": .string("s"),
            "type": .string(type),
            "status": .string(spec.status),
            "content": .object(content),
            "source": .object(source),
            "orderSeq": .number(Double(spec.order)),
            "revision": .number(Double(spec.revision)),
            "updatedSeq": .number(Double(spec.updatedSeq)),
            "contentHash": .string("\(spec.text)-\(spec.revision)"),
        ]
        if let role { json["role"] = .string(role) }
        return try V2TimelineItem(json: .object(json))
    }

    // MARK: - Mutations

    private func mutate(_ specs: inout [RowSpec],
                        targets: inout Set<String>,
                        rng: inout SeededGenerator) {
        switch Int.random(in: 0..<7, using: &rng) {
        case 0:
            let order = (specs.map(\.order).max() ?? -1) + 1
            specs.append(RowSpec(
                id: "n\(Int.random(in: 0..<1_000_000, using: &rng))",
                order: order,
                kind: RowKind.allCases.randomElement(using: &rng) ?? .assistantMessage,
                text: "tail",
                turn: specs.last?.turn,
                status: "running",
                revision: 1,
                updatedSeq: order,
                parentItemID: nil,
                nativeMessageID: specs.last?.nativeMessageID,
                sourceItemID: "tail\(order)"))
        case 1:
            guard let index = specs.indices.randomElement(using: &rng) else { return }
            specs[index].text += " +"
            specs[index].revision += 1
            specs[index].status = specs[index].status == "running" ? "done" : "running"
        case 2:
            guard let index = specs.indices.randomElement(using: &rng) else { return }
            specs.remove(at: index)
        case 3:
            guard let index = specs.indices.randomElement(using: &rng) else { return }
            var spec = specs[index]
            spec.id += "-inserted"
            spec.order = specs[index].order
            spec.text = "inserted"
            spec.revision = 1
            specs.insert(spec, at: index)
            for later in specs.indices where later > index {
                specs[later].order += 1
            }
        case 4:
            guard specs.count >= 2,
                  let first = specs.indices.randomElement(using: &rng),
                  let second = specs.indices.randomElement(using: &rng),
                  first != second else { return }
            // Copy through locals: two inout accesses into the same array
            // trip the exclusivity checker.
            let firstOrder = specs[first].order
            let secondOrder = specs[second].order
            specs[first].order = secondOrder
            specs[second].order = firstOrder
        case 5:
            // Identity/grouping inputs change in place. The text-only
            // mutations above cannot reach them, so a fingerprint that drops
            // one of these fields would stay invisible to this test.
            guard let index = specs.indices.randomElement(using: &rng) else { return }
            switch Int.random(in: 0..<5, using: &rng) {
            case 0:
                specs[index].turn = Bool.random(using: &rng)
                    ? "t\(Int.random(in: 0..<4, using: &rng))" : nil
            case 1:
                specs[index].nativeMessageID = Bool.random(using: &rng)
                    ? "m\(Int.random(in: 0..<4, using: &rng))" : nil
            case 2:
                specs[index].parentItemID = Bool.random(using: &rng)
                    ? "p\(Int.random(in: 0..<4, using: &rng))" : nil
            case 3:
                specs[index].sourceItemID = "src\(Int.random(in: 0..<1_000, using: &rng))"
            default:
                specs[index].kind = RowKind.allCases.randomElement(using: &rng)
                    ?? specs[index].kind
            }
        default:
            guard let spec = specs.randomElement(using: &rng) else { return }
            if targets.contains(spec.id) {
                targets.remove(spec.id)
            } else {
                targets.insert(spec.id)
            }
        }
    }
}

/// SplitMix64: small, deterministic and enough for a differential test.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
