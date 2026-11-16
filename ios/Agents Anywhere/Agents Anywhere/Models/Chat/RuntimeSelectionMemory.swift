import Foundation

/// The last model + reasoning effort the user explicitly chose for one
/// working target.
///
/// The two halves are stored apart instead of as one opaque selection id:
/// switching models keeps the effort (each half resolves on its own), and a
/// catalog revision that drops the model does not erase the effort.
nonisolated struct RuntimeSelectionMemory: Codable, Equatable {
    var modelID = ""
    var effortID = ""
}

/// Per-account, per-target memory of the last explicit choice — the answer
/// to "the next session starts with the model I picked in the last one".
///
/// The server keeps each session's own selection; this store only feeds new
/// sessions. It is written on an explicit, successful selection (a session's
/// options sheet or the new-session page), never on a refresh, reconnect or
/// fallback — a setting that rewrites itself is the bug this replaces
/// (pp 2026-11-16).
struct RuntimeSelectionMemoryStore {
    private let defaults: UserDefaults
    private let key: String
    private let targetSeparator = "\u{1f}"

    init(scope: V2ClientScope, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        key = "aa.native.last-selection.v1."
            + Data((scope.serverURL.absoluteString + "\n" + scope.accountID).utf8).base64EncodedString()
    }

    func load(connectorID: String, runtimeID: String) -> RuntimeSelectionMemory? {
        guard !connectorID.isEmpty, !runtimeID.isEmpty else { return nil }
        return values()[connectorID + targetSeparator + runtimeID]
    }

    /// Writes only on an actual change, so a repeated apply of the same choice
    /// never touches the defaults.
    func save(_ memory: RuntimeSelectionMemory, connectorID: String, runtimeID: String) {
        guard !connectorID.isEmpty, !runtimeID.isEmpty, !memory.modelID.isEmpty else { return }
        var current = values()
        let targetKey = connectorID + targetSeparator + runtimeID
        guard current[targetKey] != memory else { return }
        current[targetKey] = memory
        if let data = try? JSONEncoder().encode(current) { defaults.set(data, forKey: key) }
    }

    private func values() -> [String: RuntimeSelectionMemory] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: RuntimeSelectionMemory].self, from: data)) ?? [:]
    }
}
