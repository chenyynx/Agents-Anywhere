import Foundation
import Testing
@testable import ClientCore

/// Model and reasoning effort are two preferences: switching models keeps the
/// level the user picked (clamping when the next model lacks it), and the
/// last explicit choice feeds the next new session. pp 2026-11-16: switching
/// models reset the effort to the first row of the new model's list, and a
/// model set inside a session never showed up in a new one.
@Suite @MainActor struct RuntimeSelectionTests {
    private func modelJSON(_ id: String, efforts: [String]) -> [String: Any] {
        [
            "default": false, "description": NSNull(), "displayName": id, "id": id,
            "metadata": [:],
            "reasoningItems": efforts.map { effort in
                ["default": false, "description": NSNull(), "displayName": effort,
                 "fullModelId": NSNull(), "id": effort, "metadata": [:],
                 "selectionId": "sel_\(id)_\(effort)"]
            },
            "selectionId": "sel_\(id)",
        ]
    }

    private func catalogs(_ models: [[String: Any]]) throws -> ChatSettingsCatalog {
        let model: V2ModelCatalogResponse = try decode([
            "catalog": ["runtime": "claude", "revision": 1, "models": models],
            "serverTime": "2026-09-05T12:00:00Z",
        ])
        let permission: V2PermissionCatalogResponse = try fixture("permissionCatalog")
        return ChatSettingsCatalog(V2SessionCatalogs(model: model.catalog, permission: permission.catalog))
    }

    @Test func switchingModelsKeepsTheChosenEffortLevel() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([
            modelJSON("model-a", efforts: ["low", "high"]),
            modelJSON("model-b", efforts: ["low", "medium", "high"]),
        ]))
        #expect(settings.selectModel("model-a", reasoning: "high"))
        #expect(settings.selectModel("model-b"))
        #expect(settings.modelID == "model-b" && settings.reasoningID == "high")
        #expect(settings.selections[.model] == "sel_model-b_high")
    }

    /// The next model may not offer the level; the nearest one is used instead
    /// of dropping to the model's first row.
    @Test func anUnsupportedLevelClampsToTheNearestOne() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([
            modelJSON("model-a", efforts: ["low", "medium", "high", "xhigh", "max"]),
            modelJSON("model-c", efforts: ["low", "high"]),
        ]))
        #expect(settings.selectModel("model-a", reasoning: "xhigh"))
        #expect(settings.selectModel("model-c"))
        #expect(settings.reasoningID == "high")
    }

    /// Clamping is per model, not a rewrite of the preference: going back to
    /// a model that supports the original level restores it.
    @Test func switchingBackRestoresThePreferredLevelAfterAClamp() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([
            modelJSON("model-a", efforts: ["low", "medium", "high", "xhigh", "max"]),
            modelJSON("model-b", efforts: ["low", "high"]),
        ]))
        #expect(settings.selectModel("model-a", reasoning: "xhigh"))
        #expect(settings.selectModel("model-b"))
        #expect(settings.reasoningID == "high")
        #expect(settings.rememberedReasoningID == "xhigh")
        #expect(settings.selectModel("model-a"))
        #expect(settings.reasoningID == "xhigh")
    }

    /// A tie goes to the lower level: an unavailable level never silently
    /// spends more than the user asked for.
    @Test func aTieClampsToTheLowerLevel() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([
            modelJSON("model-a", efforts: ["low", "high", "max"]),
            modelJSON("model-d", efforts: ["low", "max"]),
        ]))
        #expect(settings.selectModel("model-a", reasoning: "high"))
        #expect(settings.selectModel("model-d"))
        #expect(settings.reasoningID == "low")
    }

    @Test func aModelWithoutEffortDropsTheLevel() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([
            modelJSON("model-a", efforts: ["low", "high"]),
            modelJSON("model-e", efforts: []),
        ]))
        #expect(settings.selectModel("model-a", reasoning: "high"))
        #expect(settings.selectModel("model-e"))
        #expect(settings.modelID == "model-e" && settings.reasoningID.isEmpty)
        #expect(settings.selections[.model] == "sel_model-e")
    }

    /// A remembered choice from another session clamps instead of failing the
    /// model half; an unknown model leaves the current selection untouched.
    @Test func aRememberedEffortClampsInsteadOfFailingTheModel() throws {
        let settings = ConversationSettings()
        settings.replace(try catalogs([modelJSON("model-c", efforts: ["low", "high"])]))
        #expect(settings.selectModel("model-c", preferredEffort: "xhigh"))
        #expect(settings.reasoningID == "high")
        #expect(!settings.selectModel("gone-model", preferredEffort: "low"))
        #expect(settings.modelID == "model-c")
    }

    @Test func selectionMemoryIsPerTargetAndPerAccount() throws {
        let suite = "aa-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = V2ClientScope(serverURL: URL(string: "https://example.test")!, accountID: "one")
        let store = RuntimeSelectionMemoryStore(scope: scope, defaults: defaults)
        #expect(store.load(connectorID: "device", runtimeID: "rti") == nil)

        store.save(.init(modelID: "model-b", effortID: "high"), connectorID: "device", runtimeID: "rti")
        #expect(store.load(connectorID: "device", runtimeID: "rti")
            == RuntimeSelectionMemory(modelID: "model-b", effortID: "high"))
        #expect(store.load(connectorID: "device", runtimeID: "other") == nil)

        // An empty model is not a choice; it never overwrites a real one.
        store.save(.init(modelID: "", effortID: "low"), connectorID: "device", runtimeID: "rti")
        #expect(store.load(connectorID: "device", runtimeID: "rti")?.modelID == "model-b")

        let otherAccount = RuntimeSelectionMemoryStore(
            scope: V2ClientScope(serverURL: URL(string: "https://example.test")!, accountID: "two"),
            defaults: defaults)
        #expect(otherAccount.load(connectorID: "device", runtimeID: "rti") == nil)
    }

    // MARK: - New sessions inherit the last explicit choice

    private func devices() throws -> [V2Connector] {
        var object = try fixtureObject("connector")
        var device = object["connector"] as! [String: Any]
        device["status"] = "online"
        object["connector"] = device
        let response: V2ConnectorResponse = try decode(object)
        return [response.connector]
    }

    private func capabilityJSON(_ id: String) -> [String: Any] {
        ["allowed": true, "available": true, "capabilityId": id, "parameters": [:],
         "runtime": "claude", "runtimeId": "rti_work", "scope": "runtime",
         "sessionId": NSNull(), "supported": true,
         "unavailableReason": NSNull(), "version": "1"]
    }

    private func makeNewSession(scope: V2ClientScope, defaults: UserDefaults,
                                models: [[String: Any]]) -> NewSessionModel {
        let http = TestHTTPTransport()
        http.respond = { call in
            if call.path.hasSuffix("/catalogs/model") {
                return try JSONSerialization.data(withJSONObject: [
                    "catalog": ["runtime": "claude", "revision": 1, "models": models],
                    "serverTime": "2026-09-05T12:00:00Z",
                ])
            }
            if call.path.hasSuffix("/capabilities") {
                // The shared fixture only carries `send_message`; the page
                // must offer the catalogs it is asked to resolve.
                return try JSONSerialization.data(withJSONObject: [
                    "capabilitySet": [
                        "capabilities": [self.capabilityJSON("catalog.model"),
                                         self.capabilityJSON("catalog.permission")],
                        "revision": 1,
                    ],
                    "connectorId": "device",
                    "serverTime": "2026-09-05T12:00:00Z",
                ])
            }
            if call.path.hasSuffix("/rti_work") { return try fixtureData("runtime") }
            return try http.defaultResponse(call)
        }
        let connectors = V2ConnectorAPI(transport: http)
        return NewSessionModel(scope: scope, devices: .init(connectorAPI: connectors),
            preparation: .init(connectorAPI: connectors),
            creation: .init(sessionAPI: V2SessionAPI(transport: http)),
            projectAPI: V2ProjectAPI(transport: http), defaults: defaults)
    }

    @Test func aNewSessionAdoptsTheSelectionRememberedFromASession() async throws {
        let suite = "aa-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = V2ClientScope(serverURL: URL(string: "https://example.test")!, accountID: "one")
        RuntimeSelectionMemoryStore(scope: scope, defaults: defaults)
            .save(.init(modelID: "model-b", effortID: "medium"),
                  connectorID: "device", runtimeID: "rti_work")
        let model = makeNewSession(scope: scope, defaults: defaults, models: [
            modelJSON("model-a", efforts: ["low", "high"]),
            modelJSON("model-b", efforts: ["low", "medium", "high"]),
        ])

        await model.refresh(connectors: try devices())

        #expect(model.settings.modelID == "model-b")
        #expect(model.settings.reasoningID == "medium")
    }

    /// The page's own picker feeds the same memory, so the two entry points
    /// cannot disagree about the next session's default.
    @Test func theNewSessionPageAlsoRemembersItsOwnChoice() async throws {
        let suite = "aa-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = V2ClientScope(serverURL: URL(string: "https://example.test")!, accountID: "one")
        let model = makeNewSession(scope: scope, defaults: defaults, models: [
            modelJSON("model-a", efforts: ["low", "high"]),
            modelJSON("model-b", efforts: ["low", "medium", "high"]),
        ])
        await model.refresh(connectors: try devices())
        #expect(model.settings.selectModel("model-b", reasoning: "medium"))

        model.saveSelections()

        let stored = RuntimeSelectionMemoryStore(scope: scope, defaults: defaults)
            .load(connectorID: "device", runtimeID: "rti_work")
        #expect(stored == RuntimeSelectionMemory(modelID: "model-b", effortID: "medium"))
    }

    @Test func anUnavailableRememberedModelLeavesTheDefaultChoice() async throws {
        let suite = "aa-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let scope = V2ClientScope(serverURL: URL(string: "https://example.test")!, accountID: "one")
        RuntimeSelectionMemoryStore(scope: scope, defaults: defaults)
            .save(.init(modelID: "gone-model", effortID: "high"),
                  connectorID: "device", runtimeID: "rti_work")
        let model = makeNewSession(scope: scope, defaults: defaults, models: [
            modelJSON("model-a", efforts: ["low", "high"]),
        ])

        await model.refresh(connectors: try devices())

        // The catalog default (first enabled model, first effort) stands; the
        // remembered value is kept in storage for when the model returns.
        #expect(model.settings.modelID == "model-a")
        #expect(model.settings.reasoningID == "low")
    }
}
