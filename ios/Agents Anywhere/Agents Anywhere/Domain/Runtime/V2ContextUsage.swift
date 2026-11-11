import Foundation

/// One category row of a runtime's context-window breakdown (`categories[]`).
nonisolated struct V2ContextUsageCategory: Decodable, Hashable, Identifiable {
    let name: String
    let tokens: Int
    let kind: String?

    var id: String { "\(name)#\(kind ?? "used")" }

    /// Categories the meter draws as free space / compaction buffer are not
    /// "used" context; they take the muted tone instead of a categorical one.
    var isFreeOrBuffer: Bool { kind == "free" || kind == "buffer" }
}

nonisolated struct V2ContextUsageMcpTool: Decodable, Hashable, Identifiable {
    let name: String
    let serverName: String
    let tokens: Int

    var id: String { "\(serverName)#\(name)" }
}

nonisolated struct V2ContextUsageMemoryFile: Decodable, Hashable, Identifiable {
    let path: String
    let tokens: Int
    let type: String?

    var id: String { path }
}

nonisolated struct V2ContextUsageAgent: Decodable, Hashable, Identifiable {
    let agentType: String
    let tokens: Int
    let source: String?

    var id: String { "\(agentType)#\(source ?? "")" }
}

nonisolated struct V2ContextUsageSkill: Decodable, Hashable, Identifiable {
    let name: String
    let tokens: Int
    let source: String?
    let pluginName: String?

    var id: String { "\(name)#\(pluginName ?? source ?? "")" }
}

/// The runtime's own context-window answer (server `ProtocolContextUsage`).
///
/// Detail lists are empty for runtimes that can only report a used/max pair
/// (codex): `hasBreakdown` stays false and the sheet renders the summary alone.
nonisolated struct V2ContextUsage: Decodable, Hashable {
    let runtime: String
    let totalTokens: Int
    let model: String?
    let maxTokens: Int?
    let percentage: Double?
    let detail: String
    let source: String
    let measuredAt: String?
    let categories: [V2ContextUsageCategory]
    let mcpTools: [V2ContextUsageMcpTool]
    let memoryFiles: [V2ContextUsageMemoryFile]
    let agents: [V2ContextUsageAgent]
    let skills: [V2ContextUsageSkill]

    init(
        runtime: String,
        totalTokens: Int,
        model: String? = nil,
        maxTokens: Int? = nil,
        percentage: Double? = nil,
        detail: String = "summary",
        source: String = "runtime",
        measuredAt: String? = nil,
        categories: [V2ContextUsageCategory] = [],
        mcpTools: [V2ContextUsageMcpTool] = [],
        memoryFiles: [V2ContextUsageMemoryFile] = [],
        agents: [V2ContextUsageAgent] = [],
        skills: [V2ContextUsageSkill] = []
    ) {
        self.runtime = runtime
        self.totalTokens = totalTokens
        self.model = model
        self.maxTokens = maxTokens
        self.percentage = percentage
        self.detail = detail
        self.source = source
        self.measuredAt = measuredAt
        self.categories = categories
        self.mcpTools = mcpTools
        self.memoryFiles = memoryFiles
        self.agents = agents
        self.skills = skills
    }

    private enum CodingKeys: String, CodingKey {
        case runtime, totalTokens, model, maxTokens, percentage, detail, source, measuredAt
        case categories, mcpTools, memoryFiles, agents, skills
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        runtime = try container.decode(String.self, forKey: .runtime)
        totalTokens = try container.decode(Int.self, forKey: .totalTokens)
        model = try container.decodeIfPresent(String.self, forKey: .model)
        maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens)
        percentage = try container.decodeIfPresent(Double.self, forKey: .percentage)
        detail = (try? container.decode(String.self, forKey: .detail)) ?? "summary"
        source = (try? container.decode(String.self, forKey: .source)) ?? "runtime"
        measuredAt = try container.decodeIfPresent(String.self, forKey: .measuredAt)
        categories = (try? container.decode([V2ContextUsageCategory].self, forKey: .categories)) ?? []
        mcpTools = (try? container.decode([V2ContextUsageMcpTool].self, forKey: .mcpTools)) ?? []
        memoryFiles = (try? container.decode([V2ContextUsageMemoryFile].self, forKey: .memoryFiles)) ?? []
        agents = (try? container.decode([V2ContextUsageAgent].self, forKey: .agents)) ?? []
        skills = (try? container.decode([V2ContextUsageSkill].self, forKey: .skills)) ?? []
    }

    var hasBreakdown: Bool { !categories.isEmpty }

    /// The connector served its durable last-known summary because the live
    /// read was unavailable (restart / retired transport / offline).
    var isCached: Bool { source.hasSuffix(".cache") }

    /// The client's own timeline arithmetic — the ring's last-resort fallback.
    var isEstimate: Bool { detail == "estimate" }

    var fraction: Double? {
        guard let maxTokens, maxTokens > 0 else { return nil }
        return min(max(Double(totalTokens) / Double(maxTokens), 0), 1)
    }

    /// Whole percent for the label; the runtime's own number wins when it
    /// sent one, otherwise derived from used/max (never invented when both
    /// sides are unknown).
    var percentUsed: Int? {
        if let percentage, percentage.isFinite {
            // The runtime is untrusted input: clamp before the Int conversion
            // so NaN / ±inf / out-of-range values can never trap.
            return Int(min(max(percentage, 0), 100).rounded())
        }
        guard let fraction else { return nil }
        return Int((fraction * 100).rounded())
    }

    var remainingPercent: Int? { percentUsed.map { max(0, 100 - $0) } }

    /// Categories worth drawing: zero-token rows are hidden by the official
    /// renderer and would otherwise add invisible slivers to the meter.
    var visibleCategories: [V2ContextUsageCategory] {
        categories.filter { $0.tokens > 0 }
    }
}

nonisolated struct V2ContextUsageResponse: Decodable {
    let usage: V2ContextUsage
    let serverTime: String
}

nonisolated enum V2ContextUsageDetail: String, Sendable {
    case summary
    case full
}

/// Token counts as the official sheet prints them: plain below 1,000, then
/// 万 with one decimal (whole 万 without one).
nonisolated enum ContextTokenFormat {
    static func wan(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }
        let tenThousands = Double(value) / 10_000
        if abs(tenThousands - tenThousands.rounded()) < 0.05 {
            return "\(Int(tenThousands.rounded()))万"
        }
        return String(format: "%.1f万", tenThousands)
    }
}
