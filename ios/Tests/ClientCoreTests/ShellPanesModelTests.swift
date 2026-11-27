import Foundation
import Testing
@testable import ClientCore

/// The tab shell is a pure value: these tests pin its defaults, the device
/// stack staying independent of the chat root, the one-visible-session rule,
/// and the versioned per-scope persistence (including the one-time migration
/// from the legacy `ChatShellSelection` route cache).
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

    @Test func aFreshShellStartsOnAnEmptyChatTab() {
        let panes = ShellPanesModel()
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatRoot == .newSession)
        #expect(panes.devicesPath.isEmpty)
        #expect(panes.visibleSessionId(obscured: false) == nil)
        #expect(panes.visibleSessionId(obscured: true) == nil)
        #expect(ShellTab.allCases == [.chat, .devices, .wiki, .artifacts])
    }

    @Test func openingAChatSelectsTheChatTabAndStartingOverReturnsToCompose() {
        var panes = ShellPanesModel()
        panes.selectedTab = .artifacts
        panes.openChatSession("session-a")
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatRoot == .session("session-a"))
        panes.startNewChat()
        #expect(panes.selectedTab == .chat)
        #expect(panes.chatRoot == .newSession)
        #expect(panes.visibleSessionId(obscured: false) == nil)
    }

    @Test func devicesPushAndPopWithoutTouchingTheChatRoot() {
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        panes.openDevice("connector-a")
        #expect(panes.selectedTab == .devices)
        #expect(panes.devicesDevice == "connector-a")
        #expect(panes.devicesPath.isEmpty)
        #expect(panes.chatRoot == .session("chat-session"))
        panes.pushDeviceSession("device-session")
        #expect(panes.devicesPath == [.session("device-session")])
        #expect(panes.chatRoot == .session("chat-session"))
        panes.popDevice()
        #expect(panes.devicesPath.isEmpty)
        #expect(panes.devicesDevice == "connector-a")
        #expect(panes.chatRoot == .session("chat-session"))
        // Picking another device restarts its drill-down instead of stacking
        // on the previous device's path.
        panes.pushDeviceSession("device-session")
        panes.openDevice("connector-b")
        #expect(panes.devicesDevice == "connector-b")
        #expect(panes.devicesPath.isEmpty)
        #expect(panes.chatRoot == .session("chat-session"))
        panes.popDevice()
        #expect(panes.devicesPath.isEmpty)
        #expect(panes.chatRoot == .session("chat-session"))
    }

    @Test func sameSessionMayLiveInBothPanes() {
        var panes = ShellPanesModel()
        panes.openChatSession("shared")
        panes.openDevice("connector-a")
        panes.pushDeviceSession("shared")
        // Both tabs may name the same session: only the selected tab's page
        // is mounted, so the store is shared but the live views are not.
        #expect(panes.chatRoot == .session("shared"))
        #expect(panes.devicesDevice == "connector-a")
        #expect(panes.devicesPath == [.session("shared")])
        // Pushing the top again is a no-op.
        panes.pushDeviceSession("shared")
        #expect(panes.devicesPath == [.session("shared")])
    }

    @Test func onlyTheActiveUnobscuredTabNamesAVisibleSession() {
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        #expect(panes.visibleSessionId(obscured: false) == "chat-session")
        #expect(panes.visibleSessionId(obscured: true) == nil)

        panes.startNewChat()
        #expect(panes.visibleSessionId(obscured: false) == nil)

        panes.openDevice("connector")
        #expect(panes.visibleSessionId(obscured: false) == nil)
        panes.pushDeviceSession("device-session")
        #expect(panes.visibleSessionId(obscured: false) == "device-session")
        #expect(panes.visibleSessionId(obscured: true) == nil)

        // The chat tab ignores the device stack entirely.
        panes.openChatSession("chat-session")
        #expect(panes.visibleSessionId(obscured: false) == "chat-session")
        panes.startNewChat()
        #expect(panes.visibleSessionId(obscured: false) == nil)

        // A tab with no session of its own never reports the chat root.
        panes.openChatSession("chat-session")
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
        panes.pushDeviceSession("device-session")
        store.save(panes: panes, in: scope)
        #expect(store.panes(in: scope) == panes)
        // A second store over the same defaults is what a relaunch sees.
        let relaunched = V2RestorationStore(defaults: defaults)
        #expect(relaunched.panes(in: scope) == panes)
        #expect(relaunched.panes(in: scope).visibleSessionId(obscured: false) == "device-session")
    }

    @Test func legacyDeviceRootSnapshotMovesTheDeviceOutOfThePath() {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)
        // The pre-2026-11-26 shape: the device was the first path element.
        var old = ShellPanesModel()
        old.selectedTab = .devices
        old.devicesPath = [.device("connector"), .session("session")]
        store.save(panes: old, in: scope)
        let restored = store.panes(in: scope)
        #expect(restored.devicesDevice == "connector")
        #expect(restored.devicesPath == [.session("session")])
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
        #expect(chat.devicesPath.isEmpty)

        store.save(selection: .device("legacy-connector"), in: scope)
        let devices = store.panes(in: scope)
        #expect(devices.selectedTab == .devices)
        #expect(devices.devicesDevice == "legacy-connector")
        #expect(devices.devicesPath.isEmpty)
        #expect(devices.chatRoot == .newSession)

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
        #expect(store.panes(in: otherAccount).devicesDevice == "legacy-connector")
        #expect(store.panes(in: otherAccount).devicesPath.isEmpty)
        #expect(store.panes(in: one) == panes)

        store.clear(scope: one)
        #expect(defaults.data(forKey: panesKey(one)) == nil)
        #expect(store.panes(in: one) == ShellPanesModel())
        // Clearing one scope leaves the others alone.
        #expect(store.panes(in: otherAccount).devicesDevice == "legacy-connector")
    }

    @Test func devicesComposePageLivesInTheDeviceStack() {
        var panes = ShellPanesModel()
        panes.openChatSession("chat-session")
        panes.openDevice("connector-a")
        panes.pushDeviceSession("old-session")
        // Creating from the device page composes inside the Devices tab: the
        // chat root must not move, and the compose page sits above whatever
        // session was open.
        panes.pushDeviceNewSession(workspace: "/tmp/work")
        #expect(panes.devicesPath == [.session("old-session"), .newSession(workspace: "/tmp/work")])
        #expect(panes.chatRoot == .session("chat-session"))
        #expect(panes.selectedTab == .devices)
        // A compose page names no visible session (background/live identity
        // must not attach to the previous session under it).
        #expect(panes.visibleSessionId(obscured: false) == nil)
        // Re-opening compose replaces the page instead of stacking two drafts
        // on the one shared new-session model.
        panes.pushDeviceNewSession(workspace: nil)
        #expect(panes.devicesPath == [.session("old-session"), .newSession(workspace: nil)])
        // A created session lands on top of the compose page's device stack.
        panes.pushDeviceSession("new-session")
        #expect(panes.devicesPath.last == .session("new-session"))
        #expect(panes.visibleSessionId(obscured: false) == "new-session")
    }

    @Test func composeRouteRoundTripsThroughTheRestorationStore() {
        let (defaults, name) = sandbox()
        defer { defaults.removePersistentDomain(forName: name) }
        let scope = serverScope()
        let store = V2RestorationStore(defaults: defaults)
        var panes = ShellPanesModel()
        panes.openDevice("connector")
        panes.pushDeviceNewSession(workspace: "/tmp/work")
        store.save(panes: panes, in: scope)
        #expect(store.panes(in: scope) == panes)
        #expect(store.panes(in: scope).devicesPath == [.newSession(workspace: "/tmp/work")])
    }
}
