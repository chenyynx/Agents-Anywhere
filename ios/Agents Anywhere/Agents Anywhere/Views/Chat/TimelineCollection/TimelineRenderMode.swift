import Foundation

/// The transcript's rendering mode (pp 2026-10-29). Both modes run on the
/// collection engine; only the row presentation differs.
///
/// - `.chat`: one step-group row per run of thinking/tool steps — while it
///   runs the row shows the current step, when it settles the row shows the
///   counts summary. See `TimelineStepGroup`.
/// - `.code`: the official Code page replica (message rows, merged
///   `thinkingContent`, collapsed tool spans). Unchanged by this mode's work.
nonisolated enum TimelineRenderMode: String, CaseIterable, Identifiable {
    case chat
    case code

    var id: String { rawValue }

    /// The user-facing names describe what the transcript does to the
    /// thinking/tool steps, not which page they came from (pp 2026-10-30):
    /// `.chat` shows every step as it happens, `.code` merges them.
    var title: String {
        switch self {
        case .chat: return String(localized: "分步")
        case .code: return String(localized: "合并")
        }
    }

    var detail: String {
        switch self {
        case .chat:
            return String(localized: "思考和每次工具调用各占一条，执行中实时刷新，结束后收成一行摘要。")
        case .code:
            return String(localized: "思考合并成一段「思考过程」；工具调用按类别归组、默认收起。")
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
/// - a fresh install gets `.chat` (pp 2026-11-13).
enum TimelineRenderModeSwitch {
    static let key = "aa.timeline.renderMode"
    /// The retired A/B switch's key, read once by the migration below. The
    /// switch and the container it gated are gone; the string stays so a
    /// device that set the old Bool keeps its visual choice.
    static let legacyCollectionKey = "aa.timeline.collectionView"
    /// Written by the controller on first appearance and shown in Settings, so
    /// a device test can prove the collection container actually ran.
    static let lastActiveKey = "aa.timeline.collectionViewLastActive"

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
            mode = .chat
        } else {
            mode = defaults.bool(forKey: legacyCollectionKey) ? .code : .chat
        }
        defaults.set(mode.rawValue, forKey: key)
    }
}
