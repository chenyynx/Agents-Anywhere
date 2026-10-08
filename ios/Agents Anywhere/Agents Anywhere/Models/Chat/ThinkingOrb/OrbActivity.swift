import Foundation

/// The orb's motion vocabulary — one case per pattern the engine can render.
///
/// Raw values are the persisted contract: `OrbSettingsKeys.fixedEffect` stores
/// them, so the strings never change.
enum OrbEffect: String, CaseIterable, Identifiable {
    case base, scan, swirl, ripple, gather, flow, orbit, calm
    var id: String { rawValue }
    /// The English key; the catalog adds the translations.
    var title: LocalizedStringResource {
        switch self {
        case .base: "Basic spin"
        case .scan: "Scan"
        case .swirl: "Swirl"
        case .ripple: "Ripple"
        case .gather: "Gather"
        case .flow: "Flow"
        case .orbit: "Orbit"
        case .calm: "Calm"
        }
    }
    /// 设置页里「固定动效」可选项（calm 仅内部使用）
    static var userSelectable: [OrbEffect] { [.scan, .swirl, .ripple, .gather, .flow, .orbit, .base] }
}

/// 任务状态：由宿主 App 把自己的状态映射进来（映射表见 OrbActivityResolver）。
enum OrbActivity: String, CaseIterable, Identifiable {
    case thinking, toolRunning, parallelWork, waitingForUser, writing, summarizing, finished
    var id: String { rawValue }
    /// The English key; the catalog adds the translations.
    var title: LocalizedStringResource {
        switch self {
        case .thinking: "Thinking"
        case .toolRunning: "Running tools"
        case .parallelWork: "Parallel tasks"
        case .waitingForUser: "Waiting for you"
        case .writing: "Writing"
        case .summarizing: "Summarizing"
        case .finished: "Done"
        }
    }
    var defaultEffect: OrbEffect {
        switch self {
        case .thinking: .swirl
        case .toolRunning: .scan
        case .parallelWork: .orbit
        case .waitingForUser: .ripple
        case .writing: .flow
        case .summarizing: .gather
        case .finished: .calm
        }
    }
}

/// The dot field's geometry: a Fibonacci sphere, or a lat-long grid.
enum OrbForm: String, CaseIterable, Identifiable {
    case dots, grid
    var id: String { rawValue }
    /// The English key; the catalog adds the translations.
    var title: LocalizedStringResource {
        switch self {
        case .dots: "Random dots"
        case .grid: "Lat-long grid"
        }
    }
}

/// 收到消息时由宿主创建一个新的 OrbPulse 传入（id 变化即触发一次）。
struct OrbPulse: Equatable {
    let id = UUID()
    var strength: Double = 1.0   // 新消息 1.0；流式 token 节流后的小脉冲建议 0.3
}
