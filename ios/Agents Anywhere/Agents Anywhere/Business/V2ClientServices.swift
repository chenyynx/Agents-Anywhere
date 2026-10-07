import Foundation

@MainActor
final class V2ClientServices {
    private let api: V2APIClient
    let connectivity = V2ConnectivityMonitor()
    var onCreationBound: ((String, String) -> Void)?
    var onSelectPage: ((ChatShellSelection) -> Void)?
    var onConnectivityChange: ((V2NetworkStatus) -> Void)?
    let localStore: V2LocalStore
    let scope: V2ClientScope
    let sessionRepository: V2SessionRepository
    let sessionPreparation: V2SessionPreparationService
    let account: V2AccountService
    let dashboard: V2DashboardService
    let dashboardRepository: V2DashboardRepository
    let sessionReads: V2SessionReadCoordinator
    let sessionDetail: V2SessionDetailService
    let sessionCreation: V2SessionCreationService
    let attachments: V2AttachmentService
    /// Disk cache for full-resolution attachment images. App-scoped like the
    /// services that own it, so every session view shares one cache (a re-open
    /// is served from disk); cleared on services teardown, since the only
    /// teardowns — sign-out and account/scope switches — are account
    /// boundaries a member's images must not outlive.
    let attachmentImageCache: AttachmentImageCache
    /// Shared loader for the instant image viewer: one disk cache and one
    /// in-flight table for the whole signed-in session.
    let attachmentImageLoader: AttachmentImageLoader
    let interactions: V2RuntimeInteractionService
    let devicePairing: V2DevicePairingService
    let agentSetup: AgentSetupCoordinator
    private var agentModels: [String: DeviceAgentModel] = [:]
    let deviceManagement: V2DeviceManagementService
    let workspaceFiles: V2WorkspaceFilesService
    let newSession: NewSessionModel

    init(api: V2APIClient, accountID: String) {
        self.api = api
        scope = V2ClientScope(serverURL: api.serverURL, accountID: accountID)
        // One policy instance feeds both the in-memory LRU and the disk
        // archive, so the two windows cannot drift apart (D5).
        let policy = V2SessionCachePolicy()
        let cacheDirectory = URL.applicationSupportDirectory.appendingPathComponent("AgentsAnywhere/Offline/v1")
            .appendingPathComponent(V2RestorationStore.scopeKey(scope))
        localStore = V2LocalStore(directory: cacheDirectory, maximumSessions: policy.maximumSessions)
        sessionPreparation = V2SessionPreparationService(connectorAPI: api.connectors)
        account = V2AccountService(accountAPI: api.account)
        dashboard = V2DashboardService(
            connectorAPI: api.connectors,
            projectAPI: api.projects,
            sessionAPI: api.sessions,
            realtimeAPI: api.realtime
        )
        dashboardRepository = V2DashboardRepository(service: dashboard, localStore: localStore, scope: scope)
        sessionReads = V2SessionReadCoordinator { id in
            let response = try await api.sessions.markRead(sessionIds: [id])
            guard let receipt = response.sessions.first(where: { $0.id == id }) else { throw HTTPError.invalidResponse }
            return receipt
        }
        sessionDetail = V2SessionDetailService(
            sessionAPI: api.sessions,
            runtimeAPI: api.runtime,
            realtimeAPI: api.realtime
        )
        sessionCreation = V2SessionCreationService(sessionAPI: api.sessions)
        attachments = V2AttachmentService(attachmentAPI: api.attachments, transport: api.transport)
        attachmentImageCache = AttachmentImageCache()
        attachmentImageLoader = AttachmentImageLoader(cache: attachmentImageCache, service: attachments)
        interactions = V2RuntimeInteractionService(runtimeAPI: api.runtime)
        sessionRepository = V2SessionRepository(scope: scope, detail: sessionDetail, interactions: interactions, policy: policy, localStore: localStore)
        devicePairing = V2DevicePairingService(connectorAPI: api.connectors)
        agentSetup = AgentSetupCoordinator(service: devicePairing)
        deviceManagement = V2DeviceManagementService(connectorAPI: api.connectors)
        workspaceFiles = V2WorkspaceFilesService(
            connectorAPI: api.connectors,
            serverURL: api.serverURL
        )
        newSession = NewSessionModel(scope: scope, devices: deviceManagement,
            preparation: sessionPreparation, creation: sessionCreation, projectAPI: api.projects)
        newSession.onProjectResolved = { [weak self] in self?.dashboardRepository.upsertProject($0) }
        newSession.onStaged = { [weak self] submission in
            guard let self else { return }
            sessionRepository.stageCreation(submission)
            dashboardRepository.upsert([submission.session])
            onSelectPage?(.session(submission.session.id))
            await flushCache()
        }
        newSession.onFailed = { [weak self] submission in
            var meta = submission.session; meta.status = .error
            self?.dashboardRepository.upsert([meta])
            self?.sessionRepository.localWorkDidChange(sessionID: meta.id)
        }
        newSession.onBound = { [weak self] submission, response in
            guard let self else { return }
            sessionRepository.bindCreation(submission, response: response)
            dashboardRepository.removeLocalSession(submission.session.id)
            dashboardRepository.upsert([response.session])
            onCreationBound?(submission.session.id, response.session.id)
        }
        sessionReads.updateConnectivity(.init(availability: .offline))
        connectivity.onChange = { [weak self] status in
            self?.sessionRepository.updateConnectivity(status)
            self?.newSession.updateNetwork(status)
            self?.dashboardRepository.updateNetwork(status)
            self?.agentSetup.updateNetwork(status)
            self?.updateAgentConnections()
            self?.sessionReads.updateConnectivity(self?.dashboardRepository.isFresh == true ? status : .init(availability: .offline))
            self?.onConnectivityChange?(status)
        }
        connectivity.start()
    }

    func agents(on connectorID: String) -> DeviceAgentModel {
        if let model = agentModels[connectorID] { return model }
        let model = DeviceAgentModel(connectorID: connectorID, service: deviceManagement)
        agentModels[connectorID] = model
        updateAgentConnections()
        return model
    }

    func updateAgentConnections() {
        let online = Set(dashboardRepository.connectors.filter { $0.status == .online }.map(\.id))
        for (id, model) in agentModels { model.updateConnection(dashboardRepository.isFresh && online.contains(id) && connectivity.status.availability != .offline) }
        if dashboardRepository.isFresh { agentSetup.updateConnectors(dashboardRepository.connectors) }
    }

    func editCreation(_ session: V2SessionModel, pending: V2PendingMessage) {
        guard let meta = session.metadata else { return }
        newSession.restoreCreationDraft(meta: meta, pending: pending)
        onSelectPage?(.newSession)
    }
    func discardCreation(_ id: String) {
        guard id.hasPrefix("local:") else { return }
        sessionRepository.remove(sessionIds: [id]); dashboardRepository.removeLocalSession(id)
        onSelectPage?(.newSession)
    }

    func restoreCache(selection: ChatShellSelection) async {
        await dashboardRepository.restoreCache()
        if case .session(let id) = selection { await sessionRepository.restoreCachedSession(id: id) }
    }

    func flushCache() async {
        newSession.saveDraft()
        await dashboardRepository.flushCache()
        await sessionRepository.flushCache()
    }

    func shutdown(removingCache: Bool = false) {
        onSelectPage = nil; onCreationBound = nil
        newSession.onStaged = nil; newSession.onBound = nil; newSession.onFailed = nil; newSession.onProjectResolved = nil
        // Both teardown paths are account boundaries — sign-out
        // (`removingCache: true`) and an account/scope switch (`false`) — so
        // the member's cached image originals never survive them. The online
        // cache is re-derivable; correctness (no cross-account imagery) wins.
        attachmentImageCache.clear()
        Task { await localStore.close(removing: removingCache) }
        agentSetup.invalidate()
        agentModels.values.forEach { $0.invalidate() }; agentModels = [:]
        dashboardRepository.invalidate()
        sessionReads.invalidate()
        newSession.invalidate()
        connectivity.stop()
        onConnectivityChange = nil
        sessionRepository.reset()
        api.cancelOutstandingRequests()
    }
}
