import Foundation

/// The transcript's rendering mode (pp 2026-10-29). Both modes run on the
/// collection engine; only the row presentation differs.
///
/// The case names describe what the transcript does; the raw values are the
/// historical page names and stay frozen because `aa.timeline.renderMode`
/// stores them (renaming one would silently reset every device's choice):
///
/// - `.steps` (raw `"chat"`, UI 「分步」): one step-group row per run of
///   thinking/tool steps — while it runs the row shows the current step, when
///   it settles the row shows the counts summary. See `TimelineStepGroup`.
/// - `.merged` (raw `"code"`, UI 「合并」): thinking merges into one block and
///   tool calls group by category, collapsed by default.
nonisolated enum TimelineRenderMode: String, CaseIterable, Identifiable {
    case steps = "chat"
    case merged = "code"

    var id: String { rawValue }

    /// The user-facing names describe what the transcript does to the
    /// thinking/tool steps, not which page they came from (pp 2026-10-30):
    /// `.steps` shows every step as it happens, `.merged` merges them.
    var title: String {
        switch self {
        case .steps: return String(localized: "分步")
        case .merged: return String(localized: "合并")
        }
    }

    /// The glyph the settings menu shows in front of each mode: one step per
    /// row vs the merged groups.
    /// Official Anthropicon names (pp 2026-11-20): a bulleted list for one
    /// step per row, the merge glyph for the merged groups.
    var menuSymbol: String {
        switch self {
        case .steps: return "anthropicon.listBullet"
        case .merged: return "anthropicon.gitMerge"
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
        return defaults.bool(forKey: legacyCollectionKey) ? .merged : .steps
    }

    /// Writes the new key once. Runs from the app entry before any view reads
    /// the mode, so `@AppStorage` never sees an unmigrated value.
    static func migrateIfNeeded(defaults: UserDefaults = .standard) {
        guard defaults.string(forKey: key) == nil else { return }
        let mode: TimelineRenderMode
        if defaults.object(forKey: legacyCollectionKey) == nil {
            mode = .steps
        } else {
            mode = defaults.bool(forKey: legacyCollectionKey) ? .merged : .steps
        }
        defaults.set(mode.rawValue, forKey: key)
    }
}
