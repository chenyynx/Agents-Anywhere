import Foundation

/// Reads the two user-tunable chat colours from defaults.
///
/// Kept separate from `ChatPalette` because the palette is a pure data table
/// compiled into `ClientCore` (macOS in CI, no UIKit); this store answers
/// "what does the user want right now" and the view layer turns the answer
/// into a `Color`.
enum ChatColorStore {
    static var bodyTemplate: ChatColorSettings.Pair {
        ChatColorSettings.decode(
            UserDefaults.standard.string(forKey: ChatColorSettings.bodyTemplateKey)
                ?? ChatColorSettings.encode(ChatColorSettings.defaultBodyTemplate),
            fallback: ChatColorSettings.defaultBodyTemplate
        )
    }

    static var link: ChatColorSettings.Pair {
        ChatColorSettings.decode(
            UserDefaults.standard.string(forKey: ChatColorSettings.linkKey)
                ?? ChatColorSettings.encode(ChatColorSettings.defaultLink),
            fallback: ChatColorSettings.defaultLink
        )
    }

    static func reset(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ChatColorSettings.bodyTemplateKey)
        defaults.removeObject(forKey: ChatColorSettings.linkKey)
    }
}
