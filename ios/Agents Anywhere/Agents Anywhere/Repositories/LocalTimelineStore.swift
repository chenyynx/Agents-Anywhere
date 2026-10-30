import Foundation

/// Feature flag for the local row store (route B). Default off: the JSON
/// archive remains the single source of truth until the read switch lands in
/// P2. A device or a CI gate can enable it without a rebuild.
///
/// The flag is intentionally nonisolated: `V2LocalStore` is an actor and opens
/// the database from its own executor, never from the main actor.
nonisolated enum LocalTimelineStore {
    static let defaultsKey = "LocalTimelineStore.enabled"

    /// `-aa.localdb` is the launch argument used by simulator gates.
    static var enabled: Bool {
        if ProcessInfo.processInfo.arguments.contains("-aa.localdb") { return true }
        return UserDefaults.standard.bool(forKey: defaultsKey)
    }
}
