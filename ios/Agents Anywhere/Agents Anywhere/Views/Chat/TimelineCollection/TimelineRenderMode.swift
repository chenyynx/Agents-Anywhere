import Foundation

/// The transcript's rendering mode (pp 2026-10-29). Both modes run on the
/// collection engine; only the row presentation differs.
///
/// - `.chat`: one step-group row per run of thinking/tool steps — while it
///   runs the row shows the current step, when it settles the row shows the
///   counts summary. See `TimelineStepGroup`.
/// - `.code`: the official Code page replica (message rows, merged
///   `thinkingContent`, collapsed tool spans). Unchanged by this mode's work.
enum TimelineRenderMode: String, CaseIterable, Identifiable {
    case chat
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return String(localized: "聊天")
        case .code: return String(localized: "代码")
        }
    }

    var detail: String {
        switch self {
        case .chat:
            return String(localized: "思考与工具调用按步骤逐行展示，实时更新")
        case .code:
            return String(localized: "官方 Code 页样式，合并展示思考与工具调用")
        }
    }
}

/// Storage and one-time migration for `TimelineRenderMode`.
///
/// The previous switch stored a Bool (`aa.timeline.collectionView`): false =
/// the retired Chat container, true = the Code page. The retired container is
/// gone, so:
/// - a device that had the Bool set keeps its visual choice (`true` → code,
///   `false` → the new chat mode);
/// - a fresh install gets `.code`, the shape pp uses day to day.
enum TimelineRenderModeSwitch {
    static let key = "aa.timeline.renderMode"
    static let legacyCollectionKey = TimelineCollectionSwitch.key
    static let lastActiveKey = TimelineCollectionSwitch.lastActiveKey

    static func current(defaults: UserDefaults = .standard) -> TimelineRenderMode {
        if let raw = defaults.string(forKey: key),
           let mode = TimelineRenderMode(rawValue: raw) {
            return mode
        }
        return defaults.bool(forKey: legacyCollectionKey) ? .code : .chat
    }

    /// Writes the new key once. Runs from the app entry before any view reads
    /// the mode, so `@AppStorage` never sees an unmigrated value.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: key) == nil else { return }
        let mode: TimelineRenderMode
        if defaults.object(forKey: legacyCollectionKey) == nil {
            mode = .code
        } else {
            mode = defaults.bool(forKey: legacyCollectionKey) ? .code : .chat
        }
        defaults.set(mode.rawValue, forKey: key)
    }
}
