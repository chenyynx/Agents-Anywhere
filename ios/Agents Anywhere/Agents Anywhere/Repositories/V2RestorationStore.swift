import CryptoKit
import Foundation

/// Small launch metadata only. Credentials remain in Keychain; the fingerprint
/// prevents a cached profile being used with another login's saved token.
@MainActor
final class V2RestorationStore {
    private struct Login: Codable {
        let server: URL
        let credentialFingerprint: String
        let profile: AuthMe
    }
    /// Versioned envelope for the tab shell state. A plain payload would make
    /// a future layout change decode half-way into a mixed state; the version
    /// lets the reader reject unknown layouts wholesale and start clean.
    private struct PanesEnvelope: Codable {
        let version: Int
        let panes: ShellPanesModel
    }
    /// The pre-merge shape: a Chat root beside a separate Devices stack. Kept
    /// only to migrate snapshots written before 2026-11-28.
    private struct LegacyPanesEnvelope: Codable {
        let version: Int
        let panes: LegacyPanes
    }
    private struct LegacyPanes: Codable {
        var selectedTab: String = "chat"
        var chatRoot: LegacyChatRoot = .newSession
        var devicesDevice: V2ConnectorID?
        var devicesPath: [LegacyRoute] = []
    }
    /// `ShellDevicesRoute` before the merge. `ChatTabRoute` cannot decode it:
    /// `.device` no longer exists as a mode and `.newSession` lives in the
    /// same enum as the two visible modes now.
    private enum LegacyRoute: Codable {
        case device(V2ConnectorID)
        case session(V2SessionID)
        case newSession(workspace: String?)
    }
    /// `ShellChatRoot` before the merge. `ChatTabRoot` cannot decode it
    /// because `.newSession` gained an associated workspace in the merge.
    private enum LegacyChatRoot: Codable {
        case newSession
        case session(V2SessionID)
    }
    private static let panesVersion = 2
    private let defaults: UserDefaults
    private let loginKey = "aa.native.restoration.login.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func profile(server: URL, token: String) -> AuthMe? {
        guard let data = defaults.data(forKey: loginKey), let login = try? JSONDecoder().decode(Login.self, from: data),
              login.server == server.normalizedV2ServerURL(), login.credentialFingerprint == Self.digest(token) else { return nil }
        return login.profile
    }
    func save(profile: AuthMe, server: URL, token: String) {
        let login = Login(server: server.normalizedV2ServerURL(), credentialFingerprint: Self.digest(token), profile: profile)
        if let data = try? JSONEncoder().encode(login) { defaults.set(data, forKey: loginKey) }
    }
    func selection(in scope: V2ClientScope) -> ChatShellSelection {
        guard let data = defaults.data(forKey: key(scope)) else { return .newSession }
        return (try? JSONDecoder().decode(ChatShellSelection.self, from: data)) ?? .newSession
    }
    func save(selection: ChatShellSelection, in scope: V2ClientScope) {
        if let data = try? JSONEncoder().encode(selection) { defaults.set(data, forKey: key(scope)) }
    }
    func panes(in scope: V2ClientScope) -> ShellPanesModel {
        if let data = defaults.data(forKey: panesKey(scope)) {
            if let envelope = try? JSONDecoder().decode(PanesEnvelope.self, from: data),
               envelope.version == Self.panesVersion {
                return envelope.panes
            }
            if let legacy = try? JSONDecoder().decode(LegacyPanesEnvelope.self, from: data),
               legacy.version == 1, let migrated = Self.migrate(legacy.panes) {
                return migrated
            }
            return ShellPanesModel()
        }
        // No panes written yet: seed from the legacy single-route cache so a
        // user who last stood in a chat or on a device keeps that place.
        return Self.panes(migratedFrom: selection(in: scope))
    }
    func save(panes: ShellPanesModel, in scope: V2ClientScope) {
        let envelope = PanesEnvelope(version: Self.panesVersion, panes: panes)
        if let data = try? JSONEncoder().encode(envelope) { defaults.set(data, forKey: panesKey(scope)) }
    }
    func clear(scope: V2ClientScope?) {
        defaults.removeObject(forKey: loginKey)
        if let scope {
            defaults.removeObject(forKey: key(scope))
            defaults.removeObject(forKey: panesKey(scope))
        }
    }
    private func key(_ scope: V2ClientScope) -> String { "aa.native.restoration.route." + Self.scopeKey(scope) }
    // The key keeps its old name so the v1 payload underneath is still found
    // and migrated; only the envelope version changed.
    private func panesKey(_ scope: V2ClientScope) -> String { "aa.native.restoration.panes.v1." + Self.scopeKey(scope) }
    private static func panes(migratedFrom selection: ChatShellSelection) -> ShellPanesModel {
        switch selection {
        case .newSession:
            // The root conversation is the compose page until a session opens.
            return ShellPanesModel()
        case .session(let id):
            var panes = ShellPanesModel()
            panes.openChatSession(id)
            return panes
        case .device(let id):
            var panes = ShellPanesModel()
            panes.chatDevice = id
            panes.chatMode = .list
            return panes
        }
    }

    /// Old snapshots had the Chat root beside a Devices stack. The merged
    /// tab keeps the Chat root as the conversation; a Devices snapshot turns
    /// into list mode with its sessions as pushes above the list (the
    /// `.device` route is lifted into `chatDevice`).
    private static func migrate(_ legacy: LegacyPanes) -> ShellPanesModel? {
        // An unknown tab used to fail the whole decode (the store then started
        // clean); keep that contract instead of silently landing on Chat.
        guard legacy.selectedTab == "devices" || ShellTab(rawValue: legacy.selectedTab) != nil else {
            return nil
        }
        var panes = ShellPanesModel()
        var root: ChatTabRoot = .newSession(workspace: nil)
        if case let .session(id) = legacy.chatRoot { root = .session(id) }
        panes.chatMode = .conversation(root)
        if case let .session(id) = root { panes.lastSessionID = id }
        if legacy.selectedTab == "devices" {
            var path: [ChatTabRoute] = []
            var visibleSession: V2SessionID?
            for route in legacy.devicesPath {
                switch route {
                case .device:
                    continue
                case let .session(id):
                    path.append(.session(id))
                    visibleSession = id
                case let .newSession(workspace):
                    path.append(.newSession(workspace: workspace))
                    visibleSession = nil
                }
            }
            panes.chatMode = .list
            panes.listPath = path
            panes.chatDevice = legacy.devicesDevice ?? legacy.devicesPath.compactMap { route -> V2ConnectorID? in
                if case let .device(id) = route { return id }
                return nil
            }.first
            if let visibleSession { panes.lastSessionID = visibleSession }
            panes.selectedTab = .chat
        } else {
            panes.listPath = []
            panes.chatDevice = legacy.devicesDevice
            panes.selectedTab = ShellTab(rawValue: legacy.selectedTab) ?? .chat
        }
        return panes
    }

    static func scopeKey(_ scope: V2ClientScope) -> String { digest(scope.serverURL.absoluteString + "\u{1f}" + scope.accountID) }
    nonisolated static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
