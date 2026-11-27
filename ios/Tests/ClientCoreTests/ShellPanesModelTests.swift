import Foundation
import Testing
@testable import ClientCore

/// The tab shell is a pure value: these tests pin its defaults, the
/// list/session stack, the one-visible-session rule, the versioned per-scope
/// persistence, the v1 migration from the old Chat/Devices shape, and the
/// launch-page preference.
@Suite @MainActor struct ShellPanesModelTests {
    private func sandbox() -> (defaults: UserDefaults, name: String) {
        let name = "aa-shell-panes-tests-" + UUID().uuidString
        return (UserDefaults(suiteName: name)!, name)
    }
    private func serverScope(_ host: String = "https://example.test",
                             account: String = "account") -> V2ClientScope {
        V2ClientScope(serverURL: URL(string: host)!, accountID: account)
    }
    private func panesKey(_ scope: V2ClientScope) -> String {
        "aa.native.restoration.panes.v1." + V2RestorationStore.scopeKey(scope)
    }

    // The pre-merge enums, encoded with the same synthesized Codable shape
    // the shipped snapshots used.
    private enum OldChatRoot: Codable {
        case newSession
        case session(V2SessionID)
    }
    private enum OldRoute: Codable {
        case device(V2ConnectorID)
        case session(V2SessionID)
        case newSession(workspace: String?)
    }
    private struct OldPanes: Codable {
        var selectedTab: String
        var chatRoot: OldChatRoot = .newSession
        var devicesDevice: V2ConnectorID? = nil
        var devicesPath: [OldRoute] = []
    }
    private struct OldEnvelope: Codable {
        let version: Int
        let panes: OldPanes
    }
    private func saveLegacy(_ panes: OldPanes, defaults: UserDefaults,
                            scope: V2ClientScope) throws {
        let data = try JSONEncoder().encode(OldEnvelope(version: 1, panes: panes))
        defaults.set(data, forKey: panesKey(scope))
    }

    @Test func aFreshShellStartsOnAnEmptyList() {
        let panes = ShellPanesModel()
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatPath.isEmpty)
        #expect(panes.chatDevice == nil)
        #expect(panes.lastSessionID == nil)
        #expect(panes.isListMode)
        #expect(panes.visibleSessionId(obscured: false) == nil)
        #expect(panes.visibleSessionId(obscured: true) == nil)
        #expect(ShellTab.allCases == [.chat, .wiki, .artifacts])
    }

    @Test func openingASessionPushesItAboveTheListAndRemembersIt() {
        var panes = ShellPanesModel()
        panes.selectedTab = .artifacts
        panes.openChatSession("session-a")
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatPath == [.session("session-a")])
        #expect(panes.lastSessionID == "session-a")
        #expect(panes.visibleSessionId(obscured: false) == "session-a")
        panes.startNewChat(workspace: "/tmp/work")
        #expect(panes.chatPath == [.newSession(workspace: "/tmp/work")])
        #expect(panes.visibleSessionId(obscured: false) == nil)
        // The list root is still under the compose page.
        panes.popChat()
        #expect(panes.chatPath.isEmpty)
        #expect(panes.visibleSessionId(obscured: false) == nil)
    }

    @Test func deviceSelectionResetsTheStackAndKeepsTheLastSession() {
        var panes = ShellPanesModel()
        panes.openChatSession("session-a")
        panes.openDevice("connector-a")
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatDevice == "connector-a")
        #expect(panes.chatPath.isEmpty)
        #expect(panes.isListMode)
        // The start-page `chat` preference still has a target.
        #expect(panes.lastSessionID == "session-a")
        // Picking another device restarts the root instead of stacking.
        panes.pushChatRoute(.session("session-b"))
        #expect(panes.chatPath == [.session("session-b")])
        panes.openDevice("connector-b")
        #expect(panes.chatDevice == "connector-b")
        #expect(panes.chatPath.isEmpty)
    }

    @Test func onlyTheActiveUnobscuredTabNamesAVisibleSession() {
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        #expect(panes.visibleSessionId(obscured: false) == "chat-session")
        #expect(panes.visibleSessionId(obscured: true) == nil)
        panes.openDevice("connector")
        #expect(panes.visibleSessionId(obscured: false) == nil)
        panes.pushChatRoute(.session("device-session"))
        #expect(panes.visibleSessionId(obscured: false) == "device-session")
        #expect(panes.visibleSessionId(obscured: true) == nil)
        panes.selectedTab = .wiki
        #expect(panes.visibleSessionId(obscured: false) == nil)
        panes.selectedTab = .artifacts
        #expect(panes.visibleSessionId(obscured: false) == nil)
    }

    @Test func panesRoundTripThroughTheRestorationStore() {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        panes.openDevice("connector")
        panes.pushChatRoute(.session("device-session"))
        store.save(panes: panes, in: scope)
        #expect(store.panes(in: scope) == panes)
        // A second store over the same defaults is what a relaunch sees.
        let relaunched = V2RestorationStore(defaults: defaults)
        #expect(relaunched.panes(in: scope) == panes)
        #expect(relaunched.panes(in: scope).visibleSessionId(obscured: false) == "device-session")
    }

    @Test func legacyChatSessionMigratesToThePushedSession() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "chat", chatRoot: .session("old-session")),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .chat)
        #expect(restored.chatPath == [.session("old-session")])
        #expect(restored.lastSessionID == "old-session")
        #expect(restored.chatDevice == nil)
    }

    @Test func legacyDevicesSessionMigratesAndLiftsTheDevice() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        // The pre-2026-11-26 shape: the device was the first path element.
        try saveLegacy(OldPanes(selectedTab: "devices",
                                devicesDevice: nil,
                                devicesPath: [.device("connector"), .session("session")]),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .chat)
        #expect(restored.chatDevice == "connector")
        #expect(restored.chatPath == [.session("session")])
        #expect(restored.lastSessionID == "session")
    }

    @Test func legacyDevicesComposeMigratesToTheComposeRoute() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "devices",
                                devicesDevice: "connector",
                                devicesPath: [.newSession(workspace: "/tmp/work")]),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .chat)
        #expect(restored.chatDevice == "connector")
        #expect(restored.chatPath == [.newSession(workspace: "/tmp/work")])
        #expect(restored.lastSessionID == nil)
    }

    @Test func legacyChatComposeBecomesTheList() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "chat", chatRoot: .newSession),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .chat)
        #expect(restored.chatPath.isEmpty)
        #expect(restored.isListMode)
    }

    @Test func legacyWikiTabSurvivesTheMerge() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "wiki", chatRoot: .session("s")),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .wiki)
        #expect(restored.chatPath == [.session("s")])
    }

    @Test func brokenOrUnknownPanesFallBackToTheDefaultWithoutTrapping() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)
        let key = panesKey(scope)

        defaults.set(Data("{broken".utf8), forKey: key)
        #expect(store.panes(in: scope) == ShellPanesModel())

        var saved = ShellPanesModel()
        saved.openDevice("connector")
        store.save(panes: saved, in: scope)
        let encoded = try #require(defaults.data(forKey: key))

        var unknownTab = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var payload = try #require(unknownTab["panes"] as? [String: Any])
        payload["selectedTab"] = "library"
        unknownTab["panes"] = payload
        defaults.set(try JSONSerialization.data(withJSONObject: unknownTab), forKey: key)
        #expect(store.panes(in: scope) == ShellPanesModel())

        var futureVersion = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        futureVersion["version"] = 99
        defaults.set(try JSONSerialization.data(withJSONObject: futureVersion), forKey: key)
        #expect(store.panes(in: scope) == ShellPanesModel())
    }

    @Test func legacySelectionSeedsPanesUntilPanesAreSaved() {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)

        store.save(selection: .session("legacy-session"), in: scope)
        let chat = store.panes(in: scope)
        #expect(chat.selectedTab == .chat)
        #expect(chat.chatPath == [.session("legacy-session")])
        #expect(chat.lastSessionID == "legacy-session")

        store.save(selection: .device("legacy-connector"), in: scope)
        let devices = store.panes(in: scope)
        #expect(devices.selectedTab == .chat)
        #expect(devices.chatDevice == "legacy-connector")
        #expect(devices.chatPath.isEmpty)

        store.save(selection: .newSession, in: scope)
        #expect(store.panes(in: scope) == ShellPanesModel())

        // Once the shell has saved its own state, the legacy route stops
        // mattering even if it is written again later.
        var panes = ShellPanesModel()
        panes.openChatSession("new-shell-session")
        store.save(panes: panes, in: scope)
        store.save(selection: .device("stale-connector"), in: scope)
        #expect(store.panes(in: scope) == panes)
    }

    @Test func panesStayScopedPerServerAndAccountAndClearErasesThem() {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = V2RestorationStore(defaults: defaults)
        let one = serverScope("https://one.test", account: "account")
        let otherServer = serverScope("https://two.test", account: "account")
        let otherAccount = serverScope("https://one.test", account: "other-account")

        var panes = ShellPanesModel()
        panes.openChatSession("session")
        panes.openDevice("connector")
        store.save(panes: panes, in: one)
        #expect(store.panes(in: one) == panes)
        #expect(store.panes(in: otherServer) == ShellPanesModel())
        #expect(store.panes(in: otherAccount) == ShellPanesModel())

        // Migration is scoped too: another account's legacy route cannot leak in.
        store.save(selection: .device("legacy-connector"), in: otherAccount)
        #expect(store.panes(in: otherAccount).chatDevice == "legacy-connector")
        #expect(store.panes(in: one) == panes)

        store.clear(scope: one)
        #expect(defaults.data(forKey: panesKey(one)) == nil)
        #expect(store.panes(in: one) == ShellPanesModel())
        // Clearing one scope leaves the others alone.
        #expect(store.panes(in: otherAccount).chatDevice == "legacy-connector")
    }

    @Test func startPagePreferenceAppliesOnlyAtLaunch() {
        var panes = ShellPanesModel()
        panes.openChatSession("last-session")
        panes.openDevice("connector")
        #expect(panes.chatPath.isEmpty)

        panes.applyStartPage(.auto)
        #expect(panes.chatPath.isEmpty)

        panes.applyStartPage(.chat)
        #expect(panes.chatPath == [.session("last-session")])
        #expect(panes.visibleSessionId(obscured: false) == "last-session")

        panes.applyStartPage(.list)
        #expect(panes.chatPath.isEmpty)
        #expect(panes.selectedTab == .chat)

        // No remembered session: `chat` falls back to the list.
        var empty = ShellPanesModel()
        empty.selectedTab = .wiki
        empty.applyStartPage(.chat)
        #expect(empty.selectedTab == .chat)
        #expect(empty.chatPath.isEmpty)
    }

    @Test func savedEnvelopeUsesVersionTwo() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)
        store.save(panes: ShellPanesModel(), in: scope)
        let data = try #require(defaults.data(forKey: panesKey(scope)))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 2)
    }
}
