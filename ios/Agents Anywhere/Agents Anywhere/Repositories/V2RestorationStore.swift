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
    private static let panesVersion = 1
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
            guard let envelope = try? JSONDecoder().decode(PanesEnvelope.self, from: data),
                  envelope.version == Self.panesVersion else { return ShellPanesModel() }
            return envelope.panes
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
    private func panesKey(_ scope: V2ClientScope) -> String { "aa.native.restoration.panes.v1." + Self.scopeKey(scope) }
    private static func panes(migratedFrom selection: ChatShellSelection) -> ShellPanesModel {
        switch selection {
        case .newSession:
            return ShellPanesModel()
        case .session(let id):
            var panes = ShellPanesModel()
            panes.selectedTab = .chat
            panes.chatRoot = .session(id)
            return panes
        case .device(let id):
            var panes = ShellPanesModel()
            panes.selectedTab = .devices
            panes.devicesPath = [.device(id)]
            return panes
        }
    }
    static func scopeKey(_ scope: V2ClientScope) -> String { digest(scope.serverURL.absoluteString + "\u{1f}" + scope.accountID) }
    nonisolated static func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
}
