import Foundation

/// Automatic healing for a timeline window that is behind the server while the
/// reader is already at the newest edge.
///
/// In that state a live row's `orderSeq` can sit beyond the held window's end.
/// The projection refuses it (inserting it would punch a hole in the window)
/// and reports `deferredNewer`; without a follow-up read the transcript stops
/// moving. The repository turns that signal into one debounced latest-page
/// fill per session. This switch is the manual rollback: it only disables the
/// automatic fill, never the authoritative reads on open/send.
enum TimelineStaleWindowHeal {
    private static let defaultsKey = "TimelineStaleWindowHeal.enabled"

    /// Defaults to on. A device can flip it without a rebuild
    /// (`defaults write <bundle-id> TimelineStaleWindowHeal.enabled -bool NO`).
    static var enabled: Bool {
        get {
            guard let value = UserDefaults.standard.object(
                forKey: defaultsKey) as? Bool else { return true }
            return value
        }
        set {
            UserDefaults.standard.set(newValue, forKey: defaultsKey)
        }
    }
}
