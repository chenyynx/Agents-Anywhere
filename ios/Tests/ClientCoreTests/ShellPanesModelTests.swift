import Foundation
import Testing
@testable import ClientCore

/// The tab shell is a pure value: these tests pin its defaults, the
/// conversation-root/list-push stack, the one-visible-session rule, the
/// versioned per-scope persistence, the v1 migration from the old Chat/Devices
/// shape, and the launch-page preference.
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

    @Test func aFreshShellStartsOnTheComposeRoot() {
        let panes = ShellPanesModel()
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatRoot == .newSession(workspace: nil))
        #expect(panes.chatPath.isEmpty)
        #expect(panes.chatDevice == nil)
        #expect(panes.lastSessionID == nil)
        #expect(panes.visibleSessionId(obscured: false) == nil)
        #expect(panes.visibleSessionId(obscured: true) == nil)
        #expect(ShellTab.allCases == [.chat, .wiki, .artifacts])
    }

    @Test func sidebarSessionReplacesTheRootAndClearsTheStack() {
        var panes = ShellPanesModel()
        panes.showList()
        panes.pushChatSession("old")
        panes.openChatSession("session-a")
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatRoot == .session("session-a"))
        #expect(panes.chatPath.isEmpty)
        #expect(panes.lastSessionID == "session-a")
        #expect(panes.visibleSessionId(obscured: false) == "session-a")
        // A sidebar compose also replaces the root.
        panes.startNewChat(workspace: "/tmp/work")
        #expect(panes.chatRoot == .newSession(workspace: "/tmp/work"))
        #expect(panes.chatPath.isEmpty)
        #expect(panes.visibleSessionId(obscured: false) == nil)
    }

    @Test func viewAllPushesTheListAndListRowsPushAboveIt() {
        var panes = ShellPanesModel()
        panes.openChatSession("root-session")
        panes.showList(device: "connector-a")
        #expect(panes.chatRoot == .session("root-session"))
        #expect(panes.chatPath == [.list])
        #expect(panes.chatDevice == "connector-a")
        #expect(panes.visibleSessionId(obscured: false) == nil)
        // A list row pushes a session above the list.
        panes.pushChatSession("list-session")
        #expect(panes.chatPath == [.list, .session("list-session")])
        #expect(panes.visibleSessionId(obscured: false) == "list-session")
        #expect(panes.lastSessionID == "list-session")
        // "查看全部" reuses the list and drops the pushed session.
        panes.showList()
        #expect(panes.chatPath == [.list])
        #expect(panes.visibleSessionId(obscured: false) == nil)
        // A compose row pushes and becomes a session page on creation.
        panes.pushNewChat(workspace: "/tmp/work")
        #expect(panes.chatPath == [.list, .newSession(workspace: "/tmp/work")])
        panes.finishNewChat("new-session")
        #expect(panes.chatPath == [.list, .session("new-session")])
        #expect(panes.visibleSessionId(obscured: false) == "new-session")
    }

    @Test func choosingADeviceRebuildsTheListWithThatDevice() {
        var panes = ShellPanesModel()
        panes.openChatSession("root-session")
        panes.openDevice("connector-a")
        #expect(panes.chatDevice == "connector-a")
        #expect(panes.chatPath == [.list])
        panes.pushChatSession("pushed")
        panes.openDevice("connector-b")
        #expect(panes.chatDevice == "connector-b")
        #expect(panes.chatPath == [.list])
        #expect(panes.chatRoot == .session("root-session"))
    }

    @Test func onlyTheVisiblePageNamesASession() {
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        #expect(panes.visibleSessionId(obscured: false) == "chat-session")
        #expect(panes.visibleSessionId(obscured: true) == nil)
        panes.showList()
        #expect(panes.visibleSessionId(obscured: false) == nil)
        panes.pushChatSession("device-session")
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
        panes.openChatSession("root-session")
        panes.showList(device: "connector")
        panes.pushChatSession("pushed-session")
        store.save(panes: panes, in: scope)
        #expect(store.panes(in: scope) == panes)
        let relaunched = V2RestorationStore(defaults: defaults)
        #expect(relaunched.panes(in: scope) == panes)
        #expect(relaunched.panes(in: scope).visibleSessionId(obscured: false) == "pushed-session")
    }

    @Test func legacyChatSessionBecomesTheRootConversation() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "chat", chatRoot: .session("old-session")),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .chat)
        #expect(restored.chatRoot == .session("old-session"))
        #expect(restored.chatPath.isEmpty)
        #expect(restored.lastSessionID == "old-session")
    }

    @Test func legacyDevicesStackBecomesListPlusPushedRoutes() throws {
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
        #expect(restored.chatRoot == .newSession(workspace: nil))
        #expect(restored.chatPath == [.list, .session("session")])
        #expect(restored.lastSessionID == "session")
    }

    @Test func legacyDevicesComposeBecomesAListPlusComposeRoute() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "devices",
                                devicesDevice: "connector",
                                devicesPath: [.newSession(workspace: "/tmp/work")]),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.chatDevice == "connector")
        #expect(restored.chatPath == [.list, .newSession(workspace: "/tmp/work")])
        #expect(restored.lastSessionID == nil)
    }

    @Test func legacyChatComposeStaysTheComposeRoot() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "chat", chatRoot: .newSession),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.chatRoot == .newSession(workspace: nil))
        #expect(restored.chatPath.isEmpty)
    }

    @Test func legacyWikiTabSurvivesTheMerge() throws {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        try saveLegacy(OldPanes(selectedTab: "wiki", chatRoot: .session("s")),
                       defaults: defaults, scope: scope)
        let restored = V2RestorationStore(defaults: defaults).panes(in: scope)
        #expect(restored.selectedTab == .wiki)
        #expect(restored.chatRoot == .session("s"))
        #expect(restored.chatPath.isEmpty)
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
        #expect(chat.chatRoot == .session("legacy-session"))
        #expect(chat.chatPath.isEmpty)
        #expect(chat.lastSessionID == "legacy-session")

        store.save(selection: .device("legacy-connector"), in: scope)
        let devices = store.panes(in: scope)
        #expect(devices.selectedTab == .chat)
        #expect(devices.chatDevice == "legacy-connector")
        #expect(devices.chatPath == [.list])
        #expect(devices.chatRoot == .newSession(workspace: nil))

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
        panes.showList(device: "connector")
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
        #expect(store.panes(in: otherAccount).chatDevice == "legacy-connector")
    }

    @Test func startPagePreferenceAppliesOnlyAtLaunch() {
        var panes = ShellPanesModel()
        panes.openChatSession("last-session")
        panes.showList()

        panes.applyStartPage(.auto)
        #expect(panes.chatPath == [.list])

        panes.applyStartPage(.chat)
        #expect(panes.chatPath.isEmpty)
        #expect(panes.chatRoot == .session("last-session"))
        #expect(panes.visibleSessionId(obscured: false) == "last-session")

        panes.applyStartPage(.list)
        #expect(panes.chatPath == [.list])
        #expect(panes.selectedTab == .chat)

        // No remembered session: `chat` keeps the compose root.
        var empty = ShellPanesModel()
        empty.selectedTab = .wiki
        empty.applyStartPage(.chat)
        #expect(empty.selectedTab == .chat)
        #expect(empty.chatPath.isEmpty)
        #expect(empty.chatRoot == .newSession(workspace: nil))
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
