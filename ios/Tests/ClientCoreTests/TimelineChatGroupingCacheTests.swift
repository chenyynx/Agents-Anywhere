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

        for _ in 0..<25 {
            var specs = randomSpecs(count: Int.random(in: 0...30, using: &rng), rng: &rng)
            var targets: Set<String> = []
            var cwd: String? = Bool.random(using: &rng) ? "/tmp/work" : nil

            for iteration in 0..<20 {
                let items = try specs.map(makeItem)
                let incremental = cache.units(items: items,
                                              profile: .generic,
                                              interactionTargets: targets,
                                              cwd: cwd)
                let full = TimelineChatGrouping.units(items: items,
                                                      profile: .generic,
                                                      interactionTargets: targets,
                                                      cwd: cwd)
                if incremental != full, let divergence = firstDivergence(incremental, full) {
                    Issue.record("round \(iteration) rows=\(items.count): \(divergence)")
                }
                #expect(incremental == full)
                mutate(&specs, targets: &targets, rng: &rng)
            }
        }
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
            return "steps(\(group.id)) rows=\(rowIDs)"
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
            type = "fileChange"
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
        switch Int.random(in: 0..<6, using: &rng) {
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
