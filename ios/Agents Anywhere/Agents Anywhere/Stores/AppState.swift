import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

@MainActor @Observable
final class AppState {
    enum Route {
        case loading
        case signedOut
        case signedIn
    }

    private(set) var route: Route = .loading
    private(set) var serverURL: URL?
    private(set) var me: AuthMe? {
        didSet {
            guard me != oldValue else { return }
            accountAvatarSource = AccountAvatarImageSource.parse(me?.avatar)
            if let me, let serverURL, let token = accessToken() { restoration.save(profile: me, server: serverURL, token: token) }
        }
    }
    var chatSelection = ChatShellSelection.newSession {
        didSet { if let scope = cachedServices?.scope, scope.accountID == me?.userId { restoration.save(selection: chatSelection, in: scope) } }
    }
    private(set) var restoreConnectionError: String?
    private(set) var accountAvatarSource: AccountAvatarImageSource?
    private(set) var connectors: [V2Connector] = []
    private(set) var sessions: [V2SessionMeta] = []
    private(set) var projects: [V2Project] = []
    private(set) var isDashboardLoading = false
    private(set) var hasLoadedConnectors = false
    private(set) var hasLoadedSessions = false
    var authError: String?
    private(set) var authNeedsLocalNetworkSettings = false
    var dashboardError: String?
    var sessionsError: String?
    var connectorsError: String?
    var isWorking = false
    private(set) var isRetryingServerConnection = false
    private(set) var sessionActionError: String?
    private(set) var isAccountWorking = false
    private(set) var accountError: String?

    @ObservationIgnored private let keychain = KeychainStore()
    @ObservationIgnored private let restoration = V2RestorationStore()
    @ObservationIgnored private var accountSyncTask: Task<Void, Never>?
    @ObservationIgnored private var accountSyncID = UUID()
    @ObservationIgnored private var authenticationEpoch = UUID()
    @ObservationIgnored private let serverDefaultsKey = "agentsAnywhere.serverURL"
    @ObservationIgnored private let tokenAccount = "accessToken"
    @ObservationIgnored private let dashboardClientId = "ios-dashboard-\(UUID().uuidString)"
    @ObservationIgnored private var lastDashboardRefreshAt: Date?
    @ObservationIgnored private var dashboardUpdatesTask: Task<Void, Never>?
    /// Local-database dashboard source: snapshots are merged on the store's
    /// actor and list data arrives through this object. Falls back to the
    /// in-memory repository when disabled.
    @ObservationIgnored private(set) var dashboardLibrary: DashboardLibrary?
    @ObservationIgnored private var dashboardIngestTask: Task<Void, Never>?
    @ObservationIgnored private var pendingDashboardInput: DashboardIngestInput?

    /// The library only while it is live (store opened, observation running).
    /// Views and the snapshot path fall back to the legacy repository when the
    /// local database is unavailable (e.g. the transcript-cache switch is off
    /// or the database failed to open).
    var activeDashboardLibrary: DashboardLibrary? {
        guard DashboardLibraryPreferences.isEnabled,
              let library = dashboardLibrary, library.isLive else { return nil }
        return library
    }
    /// Ownership token for `dashboardUpdatesTask`. A task may only clear its
    /// own registration: an offline→online flip can cancel a task while its
    /// bounded wait is still finishing, and a new task can be registered
    /// before the old continuation runs (P1-3).
    @ObservationIgnored private var dashboardUpdatesToken: UUID?
    /// Keychain is the durable source; view bodies and task identities read
    /// this copy instead of performing a Security framework round trip each time.
    @ObservationIgnored private var cachedToken: String?
    @ObservationIgnored private var cachedServices: V2ClientServices?
    @ObservationIgnored private var cachedServicesTokenProvider: MutableAuthTokenProvider?
    @ObservationIgnored private var isInBackground = false
    /// The product (not the Settings probe) started the keep-alive ladder for
    /// the current background window; only that instance is auto-stopped.
    @ObservationIgnored private var autoKeepAlive = false
    /// While the app is backgrounded the ladder and the long poll stay up for
    /// the whole window (P3 常驻), so a turn that starts after the user leaves
    /// still reaches them. The loop reads the server's records directly.
    @ObservationIgnored private var notificationPollTask: Task<Void, Never>?
    /// Foreground catch-up: a turn that ends just before the user returns can
    /// miss the 10 s poll and the stopped socket. Re-read a few times on
    /// foreground; ids dedupe against anything already posted.
    @ObservationIgnored private var notificationCatchUpTask: Task<Void, Never>?
    @ObservationIgnored private var openSessionObserver: NSObjectProtocol?
    /// A notification tap that can arrive before the launch restore finishes.
    /// Buffered so the saved selection cannot overwrite the tapped session
    /// (OpenMinis `NotificationNavigationStore`); entries expire after 30 s.
    @ObservationIgnored private var notificationTarget: (session: V2SessionID, at: Date)?
    @ObservationIgnored private var visibleSessionID: V2SessionID?
    /// The session the reader is on, independent of scene phase. The background
    /// keep-alive uses it so a session open in the Devices tab stays on the
    /// wire; `visibleSessionID` clears when the app leaves the foreground.
    @ObservationIgnored private var watchedSessionID: V2SessionID?

    init() {
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "?"
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "?"
        ClientDiagnosticsLog.shared.record(
            kind: "app.launch",
            detail: ["build": build, "version": version],
            dedupe: false
        )
        // An overwrite install keeps the diagnostics store, so the day file
        // continues across builds (pp 2026-11-19 installs builds constantly).
        // Announce the switch once per process so later lines can be attributed
        // to the build that wrote them.
        let previousBuild = UserDefaults.standard.string(
            forKey: ClientDiagnosticsLog.lastBuildKey
        )
        if previousBuild != build {
            ClientDiagnosticsLog.shared.record(
                kind: "build.changed",
                detail: [
                    "from": previousBuild ?? "-",
                    "to": build,
                    "version": version,
                ],
                dedupe: false
            )
            UserDefaults.standard.set(
                build, forKey: ClientDiagnosticsLog.lastBuildKey
            )
        }
        openSessionObserver = NotificationCenter.default.addObserver(
            forName: NotificationService.openSessionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let sessionID = note.userInfo?["sessionId"] as? String,
                  !sessionID.isEmpty else { return }
            // The observer queue is the main queue: no extra Task hop, so the
            // selection is written on this turn rather than the next one.
            MainActor.assumeIsolated {
                self?.openSessionFromNotification(sessionID)
            }
        }
        NotificationService.shared.activate()
        Task { await restoreSession() }
    }

    var api: APIClient? {
        guard let serverURL else { return nil }
        return APIClient(serverURL: serverURL)
    }

    var isServerConnected: Bool { cachedServices?.dashboardRepository.canWrite == true }

    func accessToken() -> String? {
        if let cachedToken { return cachedToken }
        let token = try? keychain.readString(account: tokenAccount)
        if let token, !token.isEmpty { cachedToken = token }
        return token
    }

    func restoreSession() async {
        let epoch = authenticationEpoch
        guard let serverValue = UserDefaults.standard.string(forKey: serverDefaultsKey),
              let url = URL(string: serverValue), let token = accessToken(), !token.isEmpty else {
            route = .signedOut; return
        }
        serverURL = url
        if let profile = restoration.profile(server: url, token: token) {
            me = profile
            chatSelection = preferredSelection(
                restoration.selection(in: .init(serverURL: url, accountID: profile.userId)))
            if let services = makeV2Services() { await services.restoreCache(selection: chatSelection) }
        }
        guard epoch == authenticationEpoch else { return }
        // Only local reads precede the first page. No HTTP response is needed to
        // display the saved navigation and durable session content.
        route = .signedIn
        startDashboardUpdates()
        beginAccountSynchronization()
    }

    /// Routes a notification tap to its session. A tap that arrives before the
    /// launch restore is buffered so `preferredSelection` can keep it: on a
    /// cold launch the saved selection is applied after the tap is delivered,
    /// and without the buffer it overwrites the conversation the user asked
    /// for. The tap itself lands on this main-queue turn (no extra Task hop).
    private func openSessionFromNotification(_ sessionID: V2SessionID) {
        let beforeRestore = route != .signedIn
        if beforeRestore {
            notificationTarget = (sessionID, Date())
        }
        chatSelection = .session(sessionID)
        ClientDiagnosticsLog.shared.record(
            kind: "notification.tap",
            sessionID: sessionID,
            detail: ["preRestore": beforeRestore ? "1" : "0"],
            dedupe: false)
    }

    /// A fresh notification tap outranks the saved selection. The buffer is
    /// one-shot and expires after 30 s so a stale tap cannot hijack a later
    /// account change (OpenMinis `NotificationNavigationStore`).
    private func preferredSelection(_ restored: ChatShellSelection) -> ChatShellSelection {
        guard let target = notificationTarget else { return restored }
        notificationTarget = nil
        let age = Date().timeIntervalSince(target.at)
        guard age <= 30 else { return restored }
        ClientDiagnosticsLog.shared.record(
            kind: "notification.tap.restore",
            sessionID: target.session,
            detail: ["ageSec": String(Int(age))],
            dedupe: false)
        return .session(target.session)
    }

    func retryServerConnection() async {
        beginAccountSynchronization(force: true)
        await accountSyncTask?.value
    }

    private func beginAccountSynchronization(force: Bool = false) {
        guard !isInBackground, route == .signedIn, let serverURL, let token = accessToken(), !token.isEmpty else { return }
        if accountSyncTask != nil && !force { return }
        accountSyncTask?.cancel()
        let id = UUID(); accountSyncID = id
        let epoch = authenticationEpoch
        isRetryingServerConnection = true
        accountSyncTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if accountSyncID == id { accountSyncTask = nil; isRetryingServerConnection = false }
            }
            var attempt = 0
            while !Task.isCancelled, authenticationEpoch == epoch, !isInBackground {
                do {
                    let profile = try await APIClient(serverURL: serverURL).me(token: token)
                    guard !Task.isCancelled, authenticationEpoch == epoch, accountSyncID == id else { return }
                    let accountChanged = me?.userId != profile.userId
                    if accountChanged {
                        // Old-account records must not point at sessions the
                        // new account does not own.
                        NotificationService.shared.reset()
                        chatSelection = preferredSelection(
                            restoration.selection(in: .init(serverURL: serverURL, accountID: profile.userId)))
                    }
                    me = profile
                    if accountChanged, let services = makeV2Services() { await services.restoreCache(selection: chatSelection) }
                    guard !Task.isCancelled, authenticationEpoch == epoch else { return }
                    restoreConnectionError = nil
                    startDashboardUpdates()
                    await refreshDashboard()
                    return
                } catch {
                    guard !Task.isCancelled, authenticationEpoch == epoch, accountSyncID == id else { return }
                    if isAuthenticationFailure(error) {
                        signOut(); authError = error.localizedDescription; return
                    }
                    restoreConnectionError = error.localizedDescription
                    // A transport failure retains the profile, route and cache.
                    // Backoff performs reads only; pending sends are never replayed.
                    do { try await Task.sleep(for: .seconds(min(5 * (1 << min(attempt, 3)), 30))) } catch { return }
                    attempt += 1
                }
            }
        }
    }

    func returnToLogin() {
        signOut()
    }

    func checkServer(_ value: String) async -> URL? {
        authError = nil; authNeedsLocalNetworkSettings = false
        isWorking = true
        defer { isWorking = false }
        do {
            let url = try URL.agentsServer(from: value)
            try await LocalNetworkAccess.prepare(for: url)
            try Task.checkCancellation()
            let client = APIClient(serverURL: url)
            _ = try await client.health()
            _ = try await client.authConfig()
            try Task.checkCancellation()
            return url
        } catch {
            if Task.isCancelled { return nil }
            authNeedsLocalNetworkSettings = error is LocalNetworkAccessError
            authError = error.localizedDescription
            return nil
        }
    }

    func login(serverURL: URL, email: String, password: String) async {
        authError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let client = APIClient(serverURL: serverURL)
            let auth = try await client.login(email: email, password: password)
            let profile = try await client.me(token: auth.accessToken)
            try Task.checkCancellation()
            try saveSession(serverURL: serverURL, token: auth.accessToken)
            self.serverURL = serverURL
            me = profile
            route = .signedIn
            await refreshDashboard()
            startDashboardUpdates()
        } catch {
            authError = error.localizedDescription
        }
    }

    func verifyPasswordLogin(serverURL: URL, email: String, password: String) async -> AuthResponse? {
        authError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let client = APIClient(serverURL: serverURL)
            return try await client.login(email: email, password: password)
        } catch {
            authError = error.localizedDescription
            return nil
        }
    }

    func completePasswordLogin(serverURL: URL, auth: AuthResponse, showSignedInRoute: Bool = true) async {
        authError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let client = APIClient(serverURL: serverURL)
            let profile = try await client.me(token: auth.accessToken)
            try Task.checkCancellation()
            try saveSession(serverURL: serverURL, token: auth.accessToken)
            self.serverURL = serverURL
            me = profile
            if showSignedInRoute {
                route = .signedIn
                await refreshDashboard()
                startDashboardUpdates()
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    func completeOAuthLogin(serverURL: URL, token: OAuthTokenResponse, showSignedInRoute: Bool = true) async {
        authError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let client = APIClient(serverURL: serverURL)
            let profile = try await client.me(token: token.accessToken)
            try Task.checkCancellation()
            try saveSession(serverURL: serverURL, token: token.accessToken)
            self.serverURL = serverURL
            me = profile
            if showSignedInRoute {
                route = .signedIn
                await refreshDashboard()
                startDashboardUpdates()
            }
        } catch {
            if !Task.isCancelled { authError = error.localizedDescription }
        }
    }

    func requestMobileLogin(payload: MobileLoginPayload) async -> Bool {
        authError = nil; authNeedsLocalNetworkSettings = false
        isWorking = true
        defer { isWorking = false }
        do {
            let serverURL = try URL.agentsServer(from: payload.webUrl)
            try await LocalNetworkAccess.prepare(for: serverURL)
            try Task.checkCancellation()
            let client = APIClient(serverURL: serverURL)
            _ = try await client.requestMobileLogin(
                payload: payload,
                deviceName: currentDeviceName(),
            )
            try Task.checkCancellation()
            self.serverURL = serverURL
            return true
        } catch {
            if Task.isCancelled { return false }
            authNeedsLocalNetworkSettings = error is LocalNetworkAccessError
            authError = error.localizedDescription
            return false
        }
    }

    func mobileLoginStatus(payload: MobileLoginPayload) async -> MobileLoginStatusResponse? {
        authError = nil
        do {
            let serverURL = try URL.agentsServer(from: payload.webUrl)
            let client = APIClient(serverURL: serverURL)
            return try await client.mobileLoginStatus(payload: payload)
        } catch {
            authError = error.localizedDescription
            return nil
        }
    }

    func exchangeMobileLogin(payload: MobileLoginPayload, showSignedInRoute: Bool = true) async {
        authError = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let serverURL = try URL.agentsServer(from: payload.webUrl)
            let client = APIClient(serverURL: serverURL)
            let exchange = try await client.exchangeMobileLogin(payload: payload)
            let profile = try await client.me(token: exchange.auth.accessToken)
            try Task.checkCancellation()
            try saveSession(serverURL: serverURL, token: exchange.auth.accessToken)
            self.serverURL = serverURL
            me = profile
            if showSignedInRoute {
                route = .signedIn
                await refreshDashboard()
                startDashboardUpdates()
            }
        } catch {
            authError = error.localizedDescription
        }
    }

    func refreshDashboardIfStale(minimumInterval: TimeInterval = 1.5) async {
        if isDashboardLoading { return }
        if let lastDashboardRefreshAt,
           Date().timeIntervalSince(lastDashboardRefreshAt) < minimumInterval
        {
            return
        }
        await refreshDashboard()
    }

    func refreshDashboard() async {
        guard let services = makeV2Services() else { return }
        await services.dashboardRepository.refresh()
        if cachedServices === services { lastDashboardRefreshAt = Date() }
    }

    private func syncDashboard(_ services: V2ClientServices) {
        guard cachedServices === services else { return }
        // With the local library on, list data belongs to it: the in-memory
        // repository keeps only the scalar flags this path publishes.
        let libraryMode = activeDashboardLibrary != nil
#if AA_TIMELINE_PROBE
        let probeStart = CFAbsoluteTimeGetCurrent()
#endif
        let repository = services.dashboardRepository
        // Each tracked write invalidates every view reading that property; only publish real changes.
        if !libraryMode {
            if connectors != repository.connectors { connectors = repository.connectors }
            if projects != repository.projects { projects = repository.projects }
        }
#if AA_TIMELINE_PROBE
        let probeFromSessions = CFAbsoluteTimeGetCurrent()
#endif
        var sessionsChanged = false
        if !libraryMode {
            sessionsChanged = sessions != repository.sessions
            if sessionsChanged { sessions = repository.sessions }
        }
#if AA_TIMELINE_PROBE
        let probeCompared = CFAbsoluteTimeGetCurrent()
#endif
        if isDashboardLoading != repository.isLoading { isDashboardLoading = repository.isLoading }
        if hasLoadedConnectors != repository.hasLoaded { hasLoadedConnectors = repository.hasLoaded }
        if hasLoadedSessions != repository.hasLoaded { hasLoadedSessions = repository.hasLoaded }
        if dashboardError != repository.error { dashboardError = repository.error }
        if connectorsError != repository.error { connectorsError = repository.error }
        if sessionsError != repository.error { sessionsError = repository.error }
        services.sessionReads.setActive(!isInBackground)
        services.sessionReads.updateConnectivity(repository.isFresh ? services.connectivity.status : .init(availability: .offline))
        if !libraryMode {
            services.sessionRepository.applyMetadata(sessions)
            services.updateAgentConnections()
            if repository.hasLoaded {
                services.newSession.updateProjects(projects)
                services.newSession.updateConnectors(connectors)
            }
        }
#if AA_TIMELINE_PROBE
        // The same landing that produces the Devices scroll hitch (b1718:
        // 31–48 ms, one per snapshot). Split compare vs everything else.
        let probeTotal = (CFAbsoluteTimeGetCurrent() - probeStart) * 1000
        if probeTotal >= 3 {
            ClientDiagnosticsLog.shared.record(
                kind: "dashboard.sync.slow",
                detail: [
                    "ms": String(format: "%.1f", probeTotal),
                    "compare": String(format: "%.1f", (probeCompared - probeFromSessions) * 1000),
                    "tail": String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - probeCompared) * 1000),
                    "sessionsChanged": sessionsChanged ? "1" : "0",
                    "sessions": String(sessions.count),
                ],
                dedupe: false)
        }
#endif
    }

    /// Opens the dashboard WebSocket and continuously replaces the global Connector and Session projections.
    func startDashboardUpdates() {
        guard dashboardUpdatesTask == nil, !isInBackground, route == .signedIn else { return }
        guard let services = makeV2Services() else { return }
        guard services.connectivity.status.availability != .offline else { return }

        let token = UUID()
        dashboardUpdatesToken = token
        dashboardUpdatesTask = Task { [weak self] in
            guard let self else { return }
            // Path availability is a scheduling hint: hold the socket until the
            // monitor reports (bounded), and skip the attempt entirely while
            // the path is known to be down. A later connectivity change
            // restarts this task.
            guard await services.connectivity.waitUntilOnline() else {
                // Only the task that still owns the registration may clear it;
                // an offline→online flip can already have replaced it.
                if self.cachedServices === services, self.dashboardUpdatesToken == token {
                    self.dashboardUpdatesTask = nil
                    self.dashboardUpdatesToken = nil
                }
                return
            }
            await receiveDashboardUpdates(services: services)
        }
    }

    private func cancelDashboardUpdates() {
        dashboardUpdatesTask?.cancel()
        dashboardUpdatesTask = nil
        dashboardUpdatesToken = nil
    }

    func renameSession(sessionId: V2SessionID, title: String) async -> Bool {
        sessionActionError = nil
        guard let services = makeV2Services() else {
            sessionActionError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        do {
            let updated = try await services.dashboard.renameSession(sessionId: sessionId, title: title)
            guard cachedServices === services else { return false }
            updateSession(updated)
            return true
        } catch {
            sessionActionError = error.localizedDescription
            return false
        }
    }

    func setVisibleSession(_ sessionId: V2SessionID?) {
        guard route == .signedIn else { return }
        visibleSessionID = sessionId
        NotificationService.shared.setVisibleSession(sessionId)
        makeV2Services()?.sessionReads.setVisibleSession(sessionId?.hasPrefix("local:") == true ? nil : sessionId)
    }

    /// The shell's scene-independent "reader is here" session. It survives the
    /// app leaving the foreground, unlike `visibleSessionID`.
    func setWatchedSession(_ sessionId: V2SessionID?) {
        watchedSessionID = sessionId?.hasPrefix("local:") == true ? nil : sessionId
    }

    /// Server/account scope the tab shell restores its pane state against.
    var clientScope: V2ClientScope? {
        guard let serverURL, let me else { return nil }
        return V2ClientScope(serverURL: serverURL, accountID: me.userId)
    }

    func shellPanes(in scope: V2ClientScope) -> ShellPanesModel {
        restoration.panes(in: scope)
    }

    func saveShellPanes(_ panes: ShellPanesModel, in scope: V2ClientScope) {
        restoration.save(panes: panes, in: scope)
    }

    func setSessionPinned(sessionId: V2SessionID, pinned: Bool) async -> Bool {
        sessionActionError = nil
        guard let services = makeV2Services() else {
            sessionActionError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        do {
            let updated = try await services.dashboard.setSessionPinned(sessionId: sessionId, pinned: pinned)
            guard cachedServices === services else { return false }
            updateSession(updated)
            await services.localStore.updatePinned([sessionId: pinned])
            return true
        } catch {
            sessionActionError = error.localizedDescription
            return false
        }
    }

    func setSessionArchived(sessionId: V2SessionID, archived: Bool) async -> Bool {
        await setSessionsArchived(sessionIds: [sessionId], archived: archived)
    }

    func setSessionsArchived(sessionIds: [V2SessionID], archived: Bool) async -> Bool {
        sessionActionError = nil
        guard let services = makeV2Services() else {
            sessionActionError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        do {
            let updatedSessions = if archived {
                try await services.dashboard.archive(sessionIds: sessionIds)
            } else {
                try await services.dashboard.unarchive(sessionIds: sessionIds)
            }
            guard cachedServices === services else { return false }
            for updated in updatedSessions {
                updateSession(updated)
            }
            return true
        } catch {
            sessionActionError = error.localizedDescription
            return false
        }
    }

    func dismissSessionActionError() {
        sessionActionError = nil
    }

    /// Performs authenticated network I/O and refreshes the current account profile.
    func refreshAccount() async -> Bool {
        guard !isAccountWorking else { return false }
        accountError = nil
        guard let services = makeV2Services() else {
            accountError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        isAccountWorking = true
        defer { isAccountWorking = false }
        do {
            let profile = try await services.account.profile()
            guard cachedServices === services else { return false }
            me = profile
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    /// Performs authenticated network I/O and replaces the stored account avatar.
    func updateAccountAvatar(dataURL: String) async -> Bool {
        guard !isAccountWorking else { return false }
        accountError = nil
        guard let services = makeV2Services() else {
            accountError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        isAccountWorking = true
        defer { isAccountWorking = false }
        do {
            let profile = try await services.account.updateAvatar(dataURL: dataURL)
            guard cachedServices === services else { return false }
            me = profile
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    /// Performs authenticated network I/O and removes the stored account avatar.
    func clearAccountAvatar() async -> Bool {
        guard !isAccountWorking else { return false }
        accountError = nil
        guard let services = makeV2Services() else {
            accountError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        isAccountWorking = true
        defer { isAccountWorking = false }
        do {
            let profile = try await services.account.clearAvatar()
            guard cachedServices === services else { return false }
            me = profile
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    /// Performs authenticated network I/O and changes the current account password.
    func changeAccountPassword(newPassword: String, confirmation: String) async -> Bool {
        guard !isAccountWorking else { return false }
        accountError = nil
        guard let services = makeV2Services() else {
            accountError = String(localized: "The signed-in server is unavailable.")
            return false
        }
        isAccountWorking = true
        defer { isAccountWorking = false }
        do {
            try await services.account.changePassword(
                newPassword: newPassword,
                confirmation: confirmation
            )
            return true
        } catch {
            accountError = error.localizedDescription
            return false
        }
    }

    func accountAuthConfig() async throws -> AuthConfig {
        guard let services = makeV2Services() else {
            throw APIClientError.invalidServerURL
        }
        return try await services.account.authConfig()
    }

    func updateAccountProfile(displayName: String) async throws {
        guard let services = makeV2Services() else {
            throw APIClientError.invalidServerURL
        }
        let profile = try await services.account.updateProfile(displayName: displayName)
        guard cachedServices === services else { throw CancellationError() }
        me = profile
    }

    func sendAccountEmailCode(email: String) async throws -> V2EmailCodeResponse {
        guard let services = makeV2Services() else {
            throw APIClientError.invalidServerURL
        }
        return try await services.account.sendEmailCode(email: email)
    }

    func bindAccountEmail(email: String, code: String?) async throws {
        guard let services = makeV2Services() else {
            throw APIClientError.invalidServerURL
        }
        let profile = try await services.account.bindEmail(email: email, code: code)
        guard cachedServices === services else { throw CancellationError() }
        me = profile
    }

    func dismissAccountError() {
        accountError = nil
    }

    /// Creates durable connector credentials for a new device pairing attempt.
    func createDevicePairing(name: String) async throws -> V2ConnectorCreateResponse {
        guard let services = makeV2Services() else {
            throw V2BusinessError.signedInServerUnavailable
        }
        let response = try await services.devicePairing.createDevice(name: name)
        guard cachedServices === services else { throw CancellationError() }
        updateConnector(response.connector)
        return response
    }

    /// Claims a one-time code and updates the in-memory dashboard projection.
    func claimDevicePairing(
        code: String,
        name: String,
        connectorId: V2ConnectorID,
        connectorToken: String
    ) async throws -> V2Connector {
        guard let services = makeV2Services(), let serverURL else {
            throw V2BusinessError.signedInServerUnavailable
        }
        let connector = try await services.devicePairing.claimPairing(
            code: code,
            name: name,
            serverURL: serverURL,
            connectorId: connectorId,
            connectorToken: connectorToken
        )
        guard cachedServices === services else { throw CancellationError() }
        updateConnector(connector)
        return connector
    }

    /// Reads effective connector presence while a pairing flow waits for the device.
    func devicePairingConnector(connectorId: V2ConnectorID) async throws -> V2Connector {
        guard let services = makeV2Services() else {
            throw V2BusinessError.signedInServerUnavailable
        }
        let connector = try await services.devicePairing.connector(connectorId: connectorId)
        guard cachedServices === services else { throw CancellationError() }
        updateConnector(connector)
        return connector
    }

    /// Requests fresh Agent discovery from an online paired device.
    func discoverDevicePairingRuntimes(connectorId: V2ConnectorID) async throws -> [V2DeviceRuntime] {
        guard let services = makeV2Services() else {
            throw V2BusinessError.signedInServerUnavailable
        }
        return try await services.devicePairing.discoverRuntimes(connectorId: connectorId)
    }

    func devicePairingRuntimeConfigSchema(runtime: V2DeviceRuntime) throws -> V2RuntimeConfigSchema {
        guard let services = makeV2Services() else {
            throw V2BusinessError.signedInServerUnavailable
        }
        return try services.deviceManagement.configSchema(runtime: runtime)
    }

    /// Performs authenticated network I/O to save configuration and start a paired runtime.
    func configureAndStartDevicePairingRuntime(
        connectorId: V2ConnectorID,
        runtimeId: V2RuntimeID,
        config: [String: JSONValue]
    ) async throws -> V2DeviceRuntime {
        guard let services = makeV2Services() else {
            throw V2BusinessError.signedInServerUnavailable
        }
        return try await services.deviceManagement.configureAndStartRuntime(
            connectorId: connectorId,
            runtimeId: runtimeId,
            config: config
        )
    }

    var deviceManagementService: V2DeviceManagementService? {
        makeV2Services()?.deviceManagement
    }

    var workspaceFilesService: V2WorkspaceFilesService? {
        makeV2Services()?.workspaceFiles
    }

    func updateSession(_ updated: V2SessionMeta) {
        cachedServices?.dashboardRepository.upsert([updated])
    }

    func updateConnector(_ updated: V2Connector) {
        cachedServices?.dashboardRepository.upsertConnector(updated)
    }

    func removeConnector(connectorId: V2ConnectorID) {
        cachedServices?.sessionRepository.remove(sessionIds: sessions.filter { $0.connectorId == connectorId }.map(\.id))
        cachedServices?.dashboardRepository.removeConnector(connectorId)
    }

    func updateSessions(_ updated: [V2SessionMeta]) {
        cachedServices?.dashboardRepository.upsert(updated)
    }

    func signOut(showSignedOutRoute: Bool = true) {
        do {
            try signOutAndDeleteCredentials(showSignedOutRoute: showSignedOutRoute)
        } catch {
            authError = error.localizedDescription
        }
    }

    /// Deletes the persisted access token before clearing all authenticated in-memory state.
    func signOutAndDeleteCredentials(showSignedOutRoute: Bool = true) throws {
        cancelDashboardUpdates()
        try keychain.delete(account: tokenAccount)
        cachedToken = nil
        authenticationEpoch = UUID(); accountSyncID = UUID()
        accountSyncTask?.cancel(); accountSyncTask = nil; isRetryingServerConnection = false
        restoration.clear(scope: cachedServices?.scope)
        dashboardLibrary?.stop()
        dashboardLibrary = nil
        dashboardIngestTask?.cancel(); dashboardIngestTask = nil
        pendingDashboardInput = nil
        cachedServices?.shutdown(removingCache: true)
        cachedServices = nil
        cachedServicesTokenProvider?.update(nil)
        cachedServicesTokenProvider = nil
        chatSelection = .newSession; restoreConnectionError = nil
        notificationTarget = nil
        visibleSessionID = nil
        watchedSessionID = nil
        NotificationService.shared.reset()
        me = nil
        serverURL = nil
        connectors = []
        sessions = []
        projects = []
        isDashboardLoading = false
        hasLoadedConnectors = false
        hasLoadedSessions = false
        lastDashboardRefreshAt = nil
        dashboardError = nil
        sessionsError = nil
        connectorsError = nil
        sessionActionError = nil
        isAccountWorking = false
        accountError = nil
        authError = nil
        if showSignedOutRoute {
            route = .signedOut
        }
    }

    func showSignedOutRoute() {
        route = .signedOut
    }

    func showSignedInRoute() async {
        route = .signedIn
        await refreshDashboard()
        startDashboardUpdates()
    }

    func activateSignedInRoute() {
        route = .signedIn
        Task {
            await refreshDashboard()
            startDashboardUpdates()
        }
    }

    /// Receives server-pushed dashboard snapshots and reconnects after transient failures.
    private func receiveDashboardUpdates(services: V2ClientServices) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                let updates = try await services.dashboard.updates(clientId: dashboardClientId)
                var loggedConnect = false
                for try await snapshot in updates {
                    if Task.isCancelled || cachedServices !== services { return }
                    if !loggedConnect {
                        loggedConnect = true
                        ClientDiagnosticsLog.shared.record(
                            kind: "dashboard.ws.connect",
                            detail: ["attempt": String(attempt)],
                            dedupe: false)
                    }
                    attempt = 0
                    applyDashboardSnapshot(snapshot)
                }
                if loggedConnect {
                    ClientDiagnosticsLog.shared.record(
                        kind: "dashboard.ws.disconnect",
                        detail: ["reason": "closed"],
                        dedupe: false)
                }
            } catch {
                if Task.isCancelled { return }
                let failure = V2ClientFailure(error)
                guard cachedServices === services else { return }
                ClientDiagnosticsLog.shared.record(
                    kind: "dashboard.ws.disconnect",
                    detail: ["reason": failure.message],
                    dedupe: false)
                dashboardError = failure.message
                if !failure.permitsAutomaticReconnect { return }
            }

            do {
                try await Task.sleep(for: .seconds(min(1 << min(attempt, 4), 15)))
                attempt += 1
            } catch {
                return
            }
        }
    }

    private func applyDashboardSnapshot(_ snapshot: V2DashboardSnapshot) {
#if AA_TIMELINE_PROBE
        let probeStart = CFAbsoluteTimeGetCurrent()
#endif
        if let library = activeDashboardLibrary {
            cachedServices?.dashboardRepository.noteLibrarySnapshot()
            // The read coordinator only accepts authoritative metadata: update
            // its watermarks here, on the main actor, before the rows go to
            // the store. Publish-time reconcile is read-only (`project`).
            let services = cachedServices
            let sessions = snapshot.sessions.map { services?.sessionReads.ingest($0) ?? $0 }
            enqueueDashboardIngest(
                DashboardIngestInput(connectors: snapshot.connectors,
                                     projects: snapshot.projects,
                                     sessions: sessions),
                library: library)
        } else {
            cachedServices?.dashboardRepository.apply(snapshot)
        }
#if AA_TIMELINE_PROBE
        let probeApply = CFAbsoluteTimeGetCurrent()
#endif
        NotificationService.shared.handle(snapshot: snapshot)
#if AA_TIMELINE_PROBE
        let probeTotal = (CFAbsoluteTimeGetCurrent() - probeStart) * 1000
        if probeTotal >= 3 {
            ClientDiagnosticsLog.shared.record(
                kind: "dashboard.snapshot.slow",
                detail: [
                    "ms": String(format: "%.1f", probeTotal),
                    "apply": String(format: "%.1f", (probeApply - probeStart) * 1000),
                    "notify": String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - probeApply) * 1000),
                    "sessions": String(snapshot.sessions.count),
                    "library": DashboardLibraryPreferences.isEnabled ? "1" : "0",
                ],
                dedupe: false)
        }
#endif
    }

    /// Single-flight dashboard ingest: one store transaction at a time; only
    /// the newest pending snapshot is kept.
    private func enqueueDashboardIngest(_ input: DashboardIngestInput,
                                        library: DashboardLibrary) {
        pendingDashboardInput = input
        guard dashboardIngestTask == nil else { return }
        dashboardIngestTask = Task { [weak self, weak library] in
            guard let self, let library else { return }
            while !Task.isCancelled, let next = self.pendingDashboardInput {
                self.pendingDashboardInput = nil
                _ = await library.ingest(next)
            }
            // A cancelled (superseded) task must not clear the new task's
            // handle: only the current owner clears it.
            if !Task.isCancelled { self.dashboardIngestTask = nil }
        }
    }

    /// Library publish → the properties the rest of the app still reads.
    /// The element views move to the library itself in P3; until then this is
    /// the single bridge.
    private func applyLibraryRows(_ rows: DashboardRows, services: V2ClientServices) {
        if connectors != rows.connectors { connectors = rows.connectors }
        if projects != rows.projects { projects = rows.projects }
        if sessions != rows.sessions { sessions = rows.sessions }
        // Views that still read the in-memory repository (project sidebar,
        // project editor, agent online state) must not go stale.
        services.dashboardRepository.noteLibraryRows(
            connectors: rows.connectors, projects: rows.projects,
            sessions: rows.sessions)
        services.sessionRepository.applyMetadata(sessions)
        services.updateAgentConnections()
        if services.dashboardRepository.hasLoaded {
            services.newSession.updateProjects(projects)
            services.newSession.updateConnectors(connectors)
        }
    }

    private func startNotificationLongPolling(services: V2ClientServices) {
        guard NotificationSettings.isEnabled else { return }
        notificationPollTask?.cancel()
        notificationPollTask = Task { @MainActor [weak self] in
            // The server holds the request until a record outside this set
            // appears. Sending it is what makes the wait long: a live turn
            // emits dashboard events every second, and without `known` the
            // server answered each one with the same unread record.
            var known: [String] = []
            while !Task.isCancelled {
                guard !Task.isCancelled, let self,
                      self.autoKeepAlive, self.isInBackground else { return }
                do {
                    // The server holds this up to 25 s and answers the moment
                    // a new record exists: delivery within a second, two
                    // requests a minute. The shared session's 30 s request
                    // timeout leaves margin; foregrounding cancels the held
                    // request.
                    let response = try await services.notificationAPI.notifications(
                        wait: 25,
                        known: known
                    )
                    guard !Task.isCancelled, self.autoKeepAlive,
                          self.isInBackground else { return }
                    ClientDiagnosticsLog.shared.record(
                        kind: "notification.longpoll",
                        detail: ["records": String(response.notifications.count)],
                        dedupe: false)
                    // Bound the query string; an id dropped here only means
                    // the server may resend that old record, which the
                    // posted-id dedupe discards.
                    known = Array(response.notifications.map(\.id).suffix(64))
                    NotificationService.shared.handle(records: response.notifications)
                } catch {
                    if Task.isCancelled { return }
                    ClientDiagnosticsLog.shared.record(
                        kind: "notification.longpoll",
                        detail: ["error": "1"],
                        dedupe: true)
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }
    }

    private func stopNotificationPolling() {
        notificationPollTask?.cancel()
        notificationPollTask = nil
    }

    private func startForegroundNotificationCatchUp(services: V2ClientServices) {
        guard NotificationSettings.isEnabled else { return }
        notificationCatchUpTask?.cancel()
        notificationCatchUpTask = Task { @MainActor [weak self] in
            for delay in [0, 5, 15] {
                if delay > 0 {
                    try? await Task.sleep(for: .seconds(delay))
                }
                guard !Task.isCancelled, self != nil else { return }
                do {
                    let response = try await services.notificationAPI.notifications()
                    ClientDiagnosticsLog.shared.record(
                        kind: "notification.catchup",
                        detail: ["records": String(response.notifications.count)],
                        dedupe: false)
                    NotificationService.shared.handle(records: response.notifications)
                } catch {
                    ClientDiagnosticsLog.shared.record(
                        kind: "notification.catchup",
                        detail: ["error": "1"],
                        dedupe: true)
                }
            }
        }
    }

    private func isAuthenticationFailure(_ error: Error) -> Bool {
        guard case let APIClientError.server(status, _) = error else { return false }
        return status == 401 || status == 403
    }

    var sessionRepository: V2SessionRepository? { makeV2Services()?.sessionRepository }
    var nativeChatServices: V2ClientServices? { makeV2Services() }

    func sessionModel(id: V2SessionID) -> V2SessionModel? { sessionRepository?.session(id: id) }

    func setAppInBackground(_ background: Bool) {
        isInBackground = background
        NotificationService.shared.appInForeground = !background
        if !background {
            NotificationService.shared.refreshAuthorization()
            // A banner delivered while the app was away for the conversation
            // still on screen is stale now; the same consume path withdraws it.
            NotificationService.shared.appDidBecomeForeground()
        }
        cachedServices?.sessionReads.setActive(!background)
        cachedServices?.agentSetup.setActive(!background)
        if background {
            accountSyncID = UUID(); accountSyncTask?.cancel(); accountSyncTask = nil; isRetryingServerConnection = false
            if let services = cachedServices { Task { await services.flushCache() } }
            // P3 常驻: hold the ladder and the long poll for the whole
            // background window, not only while a turn is live — a turn that
            // starts after the user leaves (scheduled task, another device)
            // still notifies. The dashboard websocket stays foreground-only;
            // the long-poll response carries what the reader needs.
            let keepAlive = NotificationSettings.isEnabled
                && NotificationService.shared.authorizationGranted
            cancelDashboardUpdates()
            if keepAlive {
                KeepAliveCoordinator.shared.start()
                autoKeepAlive = true
                if let services = cachedServices {
                    startNotificationLongPolling(services: services)
                }
            }
            // Keep the conversation the user is watching on the wire alongside
            // the dashboard channel; every other session socket closes.
            let watchedSession: V2SessionID? = watchedSessionID ?? {
                if case let .session(id) = chatSelection { return id }
                return nil
            }()
            let keptSession: Set<V2SessionID>
            if keepAlive, NotificationSettings.sessionSocketEnabled, let watchedSession {
                keptSession = [watchedSession]
            } else {
                keptSession = []
            }
            cachedServices?.sessionRepository.suspend(keeping: keptSession)
        } else {
            stopNotificationPolling()
            if let services = cachedServices {
                startForegroundNotificationCatchUp(services: services)
            }
            if autoKeepAlive {
                KeepAliveCoordinator.shared.stop()
                autoKeepAlive = false
            }
            cachedServices?.sessionRepository.resume()
            startDashboardUpdates()
            beginAccountSynchronization()
        }
    }

    private func makeV2Services() -> V2ClientServices? {
        guard
            let serverURL,
            let accountID = me?.userId,
            let token = accessToken(),
            !token.isEmpty
        else {
            return nil
        }
        let scope = V2ClientScope(serverURL: serverURL, accountID: accountID)
        if let cachedServices, cachedServices.scope == scope, let provider = cachedServicesTokenProvider {
            provider.update(token)
            return cachedServices
        }
        cancelDashboardUpdates()
        isDashboardLoading = false
        cachedServicesTokenProvider?.update(nil)
        cachedServices?.shutdown()
        let tokenProvider = MutableAuthTokenProvider(token: token)
        let api = V2APIClient(
            serverURL: serverURL,
            tokenProvider: tokenProvider
        )
        let services = V2ClientServices(api: api, accountID: accountID)
        cachedServices = services
        cachedServicesTokenProvider = tokenProvider
        services.dashboardRepository.reconcile = { [weak services] in services?.sessionReads.ingest($0) ?? $0 }
        services.dashboardRepository.onChange = { [weak self, weak services] in
            guard let services else { return }
            self?.syncDashboard(services)
        }
        dashboardLibrary?.stop()
        dashboardIngestTask?.cancel(); dashboardIngestTask = nil
        pendingDashboardInput = nil
        services.dashboardRepository.onMutation = nil
        services.dashboardRepository.onSnapshot = nil
        if DashboardLibraryPreferences.isEnabled {
            let library = DashboardLibrary(store: services.localStore)
            // Publish-time projection only: the read coordinator's watermarks
            // are updated from the authoritative snapshot on the main actor.
            library.reconcile = { [weak services] in services?.sessionReads.project($0) ?? $0 }
            library.onPublish = { [weak self, weak services] rows in
                guard let self, let services, self.cachedServices === services else { return }
                self.applyLibraryRows(rows, services: services)
            }
            dashboardLibrary = library
            services.dashboardRepository.onMutation = { [weak library] mutation in
                guard let library else { return }
                Task { await library.apply(mutation) }
            }
            services.dashboardRepository.onSnapshot = { [weak self, weak library] connectors, projects, sessions in
                guard let self, let library else { return }
                self.enqueueDashboardIngest(
                    DashboardIngestInput(connectors: connectors,
                                         projects: projects,
                                         sessions: sessions),
                    library: library)
            }
            // Import the legacy JSON archive before observing, so the first
            // read already contains it (the import is an upsert, so a WS frame
            // landing first cannot erase those rows).
            Task { [weak library, weak services] in
                if let library, let services,
                   let archive = await services.localStore.dashboard() {
                    _ = await library.seedFromArchive(archive)
                }
                library?.start()
            }
        } else {
            dashboardLibrary = nil
        }
        services.onSelectPage = { [weak self] selection in self?.chatSelection = selection }
        services.onCreationBound = { [weak self] localID, serverID in
            if self?.chatSelection == .session(localID) { self?.chatSelection = .session(serverID) }
        }
        syncDashboard(services)
        services.agentSetup.onOnline = { [weak services] connector in services?.dashboardRepository.upsertConnector(connector) }
        services.agentSetup.setActive(!isInBackground)
        services.sessionReads.setActive(!isInBackground)
        services.sessionReads.onChange = { [weak self, weak services] id in
            guard let self, let services, self.cachedServices === services,
                  let index = self.sessions.firstIndex(where: { $0.id == id }) else { return }
            let updated = services.sessionReads.project(self.sessions[index])
            if self.sessions[index] != updated {
                services.dashboardRepository.upsert([updated])
            }
        }
        services.sessionReads.setVisibleSession(visibleSessionID?.hasPrefix("local:") == true ? nil : visibleSessionID)
        if isInBackground {
            services.sessionRepository.suspend()
            // The scene can go to the background before the services exist
            // (launch restore); P3 keeps the poll up for the whole window.
            if autoKeepAlive { startNotificationLongPolling(services: services) }
        }
        services.onConnectivityChange = { [weak self, weak services] status in
            guard let self, let services, self.cachedServices === services else { return }
            if status.availability == .offline {
                self.cancelDashboardUpdates()
            } else {
                self.startDashboardUpdates()
                if self.restoreConnectionError != nil {
                    // Only re-probe the account once the path is usable; the
                    // wait is bounded and returns immediately when online.
                    Task { [weak self, weak services] in
                        guard let self, let services else { return }
                        guard await services.connectivity.waitUntilOnline() else { return }
                        guard self.cachedServices === services, self.restoreConnectionError != nil else { return }
                        self.beginAccountSynchronization(force: true)
                    }
                }
            }
        }
        return services
    }

    private func saveSession(serverURL: URL, token: String) throws {
        // A failed Keychain write must not replace the saved server or invalidate
        // the existing session. Commit in-memory/defaults changes only on success.
        try keychain.saveString(token, account: tokenAccount)
        cachedToken = token
        // A re-login with an unchanged profile must still bind the saved profile
        // to the new credential fingerprint, since `me` will not change.
        if let me { restoration.save(profile: me, server: serverURL, token: token) }
        authenticationEpoch = UUID(); accountSyncID = UUID()
        accountSyncTask?.cancel(); accountSyncTask = nil; isRetryingServerConnection = false
        restoreConnectionError = nil
        UserDefaults.standard.set(serverURL.absoluteString, forKey: serverDefaultsKey)
    }

    private func currentDeviceName() -> String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Agents Anywhere iOS"
        #endif
    }
}
