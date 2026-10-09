import Foundation
import Observation

@MainActor @Observable
final class SessionChatModel {
    let session: V2SessionModel
    let timeline = SessionTimelinePresentation()
    let settings = ConversationSettings()
    let disclosures = TimelineDisclosureState()
    var takeoverError: String?
    private(set) var takeoverUncertain = false
    private(set) var isWorking: Bool {
        get { session.isPerformingAction }
        set { session.isPerformingAction = newValue }
    }
    /// Task ids whose SubAgent stop is accepted-and-unconverged (§A3). The
    /// matching control shows its in-flight disabled form until the card's
    /// terminal event removes the task, or the bounded release below fires.
    private(set) var stoppingSubagentTaskIDs: Set<String> = []
    /// Bound on the in-flight form: a terminal frame that never lands must
    /// not pin the control for good — the "超时清理" half of the contract.
    /// Long enough that a real stop's terminal event beats it by orders of
    /// magnitude, short enough not to read as a dead button.
    static let subagentStopDeadline: Duration = .seconds(20)
    @ObservationIgnored private let subagentStopReleaseDelay: Duration
    @ObservationIgnored private var subagentStopReleases: [String: Task<Void, Never>] = [:]
    private(set) var isLoadingSettings = false
    var error: String?
    var settingsError: String?
    private(set) var isOpeningPrepared = false
    var isOpeningReady: Bool { isOpeningPrepared && timeline.hasPresentedSnapshot }
    /// The first opening return landed (or its bounded fallback expired). The
    /// cold-load mask waits for it so the reader never sees the top of the
    /// window before the opening positioning lands (D4).
    private(set) var openingPositionSettled = false
    /// A memory-cached visit reveals its snapshot and never shows the
    /// full-screen opening mask; the mask is reserved for true cold loads (D3).
    let opensFromCachedSnapshot: Bool
    /// Full-screen opening mask visibility. A cached visit never shows it; a
    /// cold load keeps it until the page is ready and the first return settled.
    var showsOpeningMask: Bool {
        guard !opensFromCachedSnapshot else { return false }
        return !isOpeningReady || !openingPositionSettled
    }
    private(set) var openingError: String?
    private(set) var responseRevision = 0
    private(set) var commands: [V2RuntimeCommand] = []
    private(set) var isLoadingCommands = false
    private(set) var commandsError: String?
    private(set) var isRunningCommand = false
    /// Success is transient; failures stay until the user dismisses them.
    var commandSuccess: CommandFeedback?
    var commandFailure: CommandFeedback?
    /// The short confirmation a model switch leaves behind — the AA form of
    /// the CLI's own "model set" note. Transient, and it never mentions the
    /// interrupt that accompanies the switch.
    var switchFeedback: CommandFeedback?
    /// Selector commands (model, permission, …) open the existing options sheet.
    private(set) var optionsRequest = 0
    @ObservationIgnored var onEditCreation: ((V2PendingMessage) -> Void)?
    @ObservationIgnored var onDiscardCreation: (() -> Void)?
    @ObservationIgnored let repository: V2SessionRepository
    @ObservationIgnored private let attachments: V2AttachmentService
    @ObservationIgnored private let files: V2WorkspaceFilesService?

    init(session: V2SessionModel, repository: V2SessionRepository, attachments: V2AttachmentService, files: V2WorkspaceFilesService? = nil,
         subagentStopReleaseDelay: Duration = SessionChatModel.subagentStopDeadline) {
        self.session = session; self.repository = repository; self.attachments = attachments
        self.files = files
        self.subagentStopReleaseDelay = subagentStopReleaseDelay
        opensFromCachedSnapshot = repository.cached(sessionId: session.id) != nil
        // Cached history can still be expensive to project. prepareOpening()
        // performs that work after the page's navigation transition settles.
    }

    /// The authoritative answer: a turn is in flight according to live facts.
    /// Everything except the composer gates (timeline actions, subtitles,
    /// feedback) reads this value, so an optimistic turn end can never leak
    /// into anything but the send/stop decision.
    var isRunning: Bool {
        session.runtime.state?.status.isTurnInFlight == true
    }
    /// The composer's view of the turn window. It equals `isRunning` except
    /// inside an accepted interrupt's optimistic window, where the send key is
    /// already usable — before the frames that report the idle turn land.
    var isComposerStreaming: Bool {
        isRunning && !session.runtime.isPredictedIdle
    }
    /// The configured instance name, like Web, then its runtime type. Status
    /// copy names the Agent the user chose instead of a generic "Agent".
    var agentName: String {
        let meta = session.metadata
        for name in [meta?.runtimeName, meta?.runtimeTypeDisplayName] {
            if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty { return name }
        }
        return String(localized: "Agent")
    }
    var isDsh: Bool {
        guard let meta = session.metadata else { return false }
        return (meta.runtimeType ?? meta.runtime) == "dsh"
    }
    var sendingPlaceholder: String? {
        let submitting = session.pendingMessages.contains { $0.delivery == .sending || $0.delivery == .accepted }
        if submitting || session.awaitingReplyID != nil { return session.isLocalCreation ? String(localized: "正在创建会话…") : String(localized: "等待 \(agentName) 回应…") }
        guard session.runtime.isFresh, let status = session.runtime.state?.status else { return nil }
        switch status {
        case .waiting, .pending: return String(localized: "等待 \(agentName) 回应…")
        case .running: return String(localized: "\(agentName) 正在处理任务…")
        default: return nil
        }
    }
    var responseUnavailableReason: String? {
        if !session.isValid { return String(localized: "会话已关闭。") }
        if session.network.availability == .offline || session.connection == .offline { return String(localized: "网络已断开，已填写的内容会保留。") }
        if session.metadata?.connectorStatus == .offline { return String(localized: "设备已离线，已填写的内容会保留。") }
        if session.runtime.isFresh { return nil }
        if session.failure?.kind == .invalidResponse { return String(localized: "会话数据暂时无法解析，请刷新状态后回应。已填写的内容会保留。") }
        if session.failure?.kind == .authentication { return String(localized: "登录状态需要重新验证，已填写的内容会保留。") }
        return String(localized: "正在确认 Agent 的最新状态，已填写的内容会保留。")
    }
    var canAttach: Bool { session.runtime.allows("runtime.attachment") }
    var canChangeTakeover: Bool {
        session.isValid && session.connection == .connected && session.metadata?.connectorStatus == .online
            && session.network.availability != .offline && !isWorking && !takeoverUncertain
    }
    var canBrowseFiles: Bool {
        session.isValid && session.metadata?.connectorStatus == .online && session.network.availability != .offline
            && session.metadata?.cwd?.isEmpty == false
    }

    // MARK: Commands

    private var connectorOnline: Bool {
        session.metadata?.connectorStatus == .online && session.network.availability != .offline
    }
    /// The runtime advertises commands at all, even when they cannot run now.
    var offersCommands: Bool { session.isValid && session.runtime.capabilities?.capability(id: "session.commands") != nil }
    var canUseCommands: Bool { session.runtime.allows("session.commands") && connectorOnline }
    var commandsUnavailableReason: String? {
        guard let capability = session.runtime.capabilities?.capability(id: "session.commands"), !canUseCommands else { return nil }
        if !connectorOnline { return String(localized: "设备离线") }
        if !capability.supported { return String(localized: "当前 Runtime 版本还不支持指令，升级后可用") }
        if let reason = capability.unavailableReason, !reason.isEmpty { return reason }
        return String(localized: "此会话暂时无法使用指令")
    }

    func loadCommands(force: Bool = false) async {
        guard canUseCommands, !isLoadingCommands else { return }
        isLoadingCommands = true
        commandsError = nil
        defer { isLoadingCommands = false }
        do {
            let loaded = try await repository.commands(sessionId: session.id, force: force)
            guard session.isValid else { return }
            commands = loaded
        } catch {
            if session.isValid, !Task.isCancelled { commandsError = error.localizedDescription }
        }
    }

    func commandBlock(_ command: V2RuntimeCommand) -> RuntimeCommandBlock? {
        if isRunningCommand || isWorking { return .busy }
        return command.block(status: session.runtime.state?.status, capability: canUseCommands,
            writable: session.metadata?.takeover == true, online: connectorOnline)
    }

    func commandBlockMessage(_ command: V2RuntimeCommand, _ block: RuntimeCommandBlock) -> String {
        switch block {
        case .busy: return String(localized: "Agent 忙碌中，暂时不能执行")
        case .readOnly: return String(localized: "开启接管后才能执行指令")
        case .offline: return String(localized: "设备离线")
        case .unavailable: return String(localized: "此会话暂时无法使用指令")
        case .disabled:
            switch command.disabledReason {
            case "session_unloaded": return String(localized: "请先打开此会话，再运行指令。")
            case "native_commands_unavailable": return String(localized: "此 Codex 版本尚不支持所需的指令操作。")
            case "codex_unavailable": return String(localized: "Codex 当前不可用。")
            case let reason?: return reason
            case nil: return String(localized: "此会话暂时无法使用指令")
            }
        }
    }

    /// Catalog commands matching the draft's slash token, or nil when the draft
    /// is not a command-like slash (e.g. a path or prose).
    func commandSuggestions(for text: String) -> [V2RuntimeCommand]? {
        guard let intent = SlashIntent(text), intent.isCommandLike, intent.suffix.isEmpty, !intent.multiline else { return nil }
        return commands.filter { $0.matches(intent.command) }
    }

    /// Only drafts naming a catalog command run as commands; the catalog is read
    /// first when needed so an intended command is never sent to the model.
    private func catalogCommand(for text: String) async -> V2RuntimeCommand? {
        guard let intent = SlashIntent(text), !intent.command.isEmpty, intent.isCommandLike, canUseCommands else { return nil }
        if commands.isEmpty { await loadCommands() }
        return commands.exact(intent)
    }

    /// Menu choice: commands with arguments are completed into the draft.
    func choose(_ command: V2RuntimeCommand) async {
        if let block = commandBlock(command) { fail(commandBlockMessage(command, block)); return }
        let draft = session.composer
        let current = SlashIntent(draft.text).flatMap { [command].exact($0) } != nil ? draft.text : "/\(command.id)"
        // Prose typed before opening the ⌘ menu is kept; a partial "/comp" is replaced.
        let prose = SlashIntent(draft.text) == nil ? draft.text : ""
        if command.takesArguments {
            draft.text = current == "/\(command.id)" ? current + " " + prose : current
            draft.isFocused = true
            repository.draftDidChange()
            return
        }
        await runCommand(command, raw: current, clearing: prose.isEmpty ? draft.text : nil)
    }

    /// `source` is the draft to clear on success (defaults to `raw`).
    func runCommand(_ command: V2RuntimeCommand, raw: String, clearing source: String? = nil) async {
        guard !isRunningCommand, session.isValid else { return }
        if let block = commandBlock(command) { fail(commandBlockMessage(command, block)); return }
        guard session.composer.attachments.isEmpty else { fail(String(localized: "运行指令前请移除附件；草稿会保留。")); return }
        guard let intent = SlashIntent(raw), let request = command.request(for: intent) else {
            fail(SlashIntent(raw)?.multiline == true ? String(localized: "此指令不支持多行输入。") : String(localized: "此指令不接受这些参数。"))
            return
        }
        if case .selector? = command.ui { optionsRequest += 1; return }
        isRunningCommand = true
        commandFailure = nil
        defer { isRunningCommand = false }
        let outcome: RuntimeCommandOutcome
        do { outcome = RuntimeCommandOutcome(try await repository.executeCommand(sessionId: session.id, request: request)) }
        catch { outcome = RuntimeCommandOutcome(transportFailure: error) }
        guard session.isValid else { return }
        if outcome.ok {
            let message = outcome.message.map { $0.count > 200 ? String($0.prefix(200)) + "…" : $0 }
            commandSuccess = CommandFeedback(title: outcome.state == .completed ? String(localized: "指令已完成。") : String(localized: "指令已接受，后台任务可能仍在进行。"), message: message)
            if let source = source ?? raw as String?, !source.isEmpty, session.composer.text == source { session.composer.text = ""; repository.draftDidChange() }
        } else if outcome.state == .unknown {
            commandFailure = CommandFeedback(title: String(localized: "指令结果尚不确定"),
                message: [String(localized: "结果尚不确定，请先检查会话状态再决定是否重试。"), outcome.message].compactMap { $0 }.joined(separator: "\n"))
        } else {
            fail(outcome.message ?? String(localized: "无法执行指令。"))
        }
    }

    private func fail(_ message: String) {
        commandFailure = CommandFeedback(title: String(localized: "无法执行指令"), message: message)
    }

    func prepareOpening() async {
        if !timeline.hasPresentedSnapshot {
            isOpeningPrepared = false
            openingPositionSettled = false
        }
        openingError = nil
        // A memory-cached visit presents before any network read so the page is
        // usable immediately (D3). The window is trimmed exactly like open()
        // trims it, so the later refresh cannot remove rows the reader sees.
        if session.isValid, let cached = repository.cached(sessionId: session.id) {
            timeline.presentOpening(Array(cached.items.suffix(100)), pendingMessages: session.pendingMessages)
            isOpeningPrepared = true
        }
        do {
            // Both cold and cached visits begin with one latest page. Older
            // records are added only by the user's explicit history requests.
            _ = try await repository.open(sessionId: session.id)
        } catch {
            guard !Task.isCancelled else { return }
            openingError = error.localizedDescription
        }
        guard session.isValid, !Task.isCancelled else { return }
        if let data = repository.cached(sessionId: session.id) {
            timeline.presentOpening(data.items, pendingMessages: session.pendingMessages)
        }
        isOpeningPrepared = true
    }

    /// The timeline reports its first opening return (or the bounded mask
    /// fallback expires). Display-only: it never gates data or connection work.
    func openingPositionDidSettle() {
        guard !openingPositionSettled else { return }
        openingPositionSettled = true
    }

    func setTakeover(_ enabled: Bool) async -> Bool {
        guard canChangeTakeover, session.metadata?.takeover != enabled else { return false }
        isWorking = true; takeoverError = nil
        defer { isWorking = false }
        do { try await repository.setTakeover(sessionId: session.id, enabled: enabled); return session.isValid }
        catch {
            guard session.isValid else { return false }
            takeoverUncertain = !V2ClientFailure.isDefiniteWriteRejection(error)
            takeoverError = takeoverUncertain ? String(localized: "接管状态尚未确认，请先刷新状态，避免重复操作。") : error.localizedDescription
            return false
        }
    }

    func refreshTakeover() async {
        await session.refresh()
        if session.runtime.isFresh { takeoverUncertain = false; takeoverError = nil }
    }

    func loadSettings() async {
        guard !isLoadingSettings, session.isValid else { return }
        guard session.runtime.isFresh else { settingsError = String(localized: "连接恢复后可更改对话选项。"); return }
        isLoadingSettings = true
        settingsError = nil
        defer { isLoadingSettings = false }
        do {
            let catalogs = try await repository.catalogs(sessionId: session.id, capabilities: session.runtime.capabilities)
            guard session.isValid, !Task.isCancelled else { return }
            settings.replace(ChatSettingsCatalog(catalogs), selections: currentSelections, defaults: false)
        } catch { if session.isValid { self.settingsError = error.localizedDescription } }
    }

    private var currentSelections: [V2RuntimeSelectionScope: V2SelectionID] {
        (session.runtime.state?.selections ?? [:]).compactMapValues { $0 }
    }

    /// Applies the sheet's selections. A model switch is "stop and switch"
    /// (pp 2026-10-05): the selection lands first and a turn that is running —
    /// or whose state cannot prove it is not — is interrupted right after it,
    /// so the next message starts under the new model.
    func applySettings() async -> Bool {
        guard !isWorking else { return false }
        // A stale projection cannot prove the offered selection still exists,
        // and the write-discipline gates are fail-closed by design. The
        // refusal is explicit — the sheet's own error surface — instead of a
        // silent no-op, and the background heal re-reads within a bounded
        // backoff, so the user can simply retry (red team F3).
        guard session.runtime.isFresh else {
            self.settingsError = String(localized: "连接恢复后可更改对话选项。")
            return false
        }
        isWorking = true
        defer { isWorking = false }
        do {
            // The server's own view (not `settings`, which `selectModel`
            // already flipped when the user picked): the note below must tell
            // a model switch from an effort-only change within one model.
            let modelBefore = settings.modelID(forSelection: currentSelections[.model])
            var switchedModel = false
            // Deterministic order (pp 2026-10-05): every selection — model
            // first, then a permission change riding along — lands before the
            // interrupt it implies.
            for scope in [V2RuntimeSelectionScope.model, .permission] {
                guard let value = settings.selections[scope], currentSelections[scope] != value else { continue }
                guard session.runtime.allows(scope == .model ? "catalog.model" : "catalog.permission") else {
                    throw V2ClientFailure(kind: .unavailable, message: String(localized: "This selection is currently unavailable."))
                }
                try await repository.setSelection(sessionId: session.id, scope: scope, selectionId: value)
                if scope == .model { switchedModel = true }
            }
            if switchedModel {
                if needsInterruptAfterModelSwitch() {
                    // The model-switch flavor: stop the turn, spare the
                    // background agents it dispatched (per-task stop
                    // affordance). Every other stop keeps the all-stop
                    // semantics.
                    do { try await repository.interrupt(sessionId: session.id, preserveBackground: true) }
                    catch {
                        // "Switched but not stopped": the selection is in, the
                        // turn keeps running under the old model. The real
                        // failure goes out on the existing error channel and
                        // the user can stop manually.
                        self.error = error.localizedDescription
                    }
                }
                // The note names a *model*: switching only the thinking effort
                // inside the same model interrupts the turn but announces
                // nothing (red team F8).
                if modelBefore != settings.model?.id {
                    announceModelSwitch()
                }
            }
            return session.isValid
        } catch {
            self.settingsError = error.localizedDescription
            settings.replace(settings.catalog, selections: currentSelections, defaults: false)
            return false
        }
    }

    /// The interrupt branch of a model switch: a turn in flight, or any state
    /// that cannot prove there is none (no state yet), gets an idempotent
    /// interrupt — an interrupt that finds no active turn answers 409, which
    /// the repository only treats as success when the last-known interrupt
    /// capability supports it. A runtime that cannot interrupt at all is not
    /// asked to: the attempt could only produce a capability refusal the user
    /// cannot act on (red team F2, DG-10).
    private func needsInterruptAfterModelSwitch() -> Bool {
        guard session.runtime.isFresh else { return true }
        guard let capability = session.runtime.capabilities?.capability(id: "session.interrupt"),
              capability.supported, capability.allowed else { return false }
        guard let status = session.runtime.state?.status else { return true }
        return status.isTurnInFlight || status == .unknown
    }

    /// The official-alignment transient for a switch — the same short note the
    /// CLI prints for its own model change, and it never mentions the
    /// interrupt that accompanies it.
    private func announceModelSwitch() {
        let title = settings.model?.option.title ?? String(localized: "默认模型")
        switchFeedback = CommandFeedback(title: String(localized: "已切换到 \(title)"), message: nil)
    }

    // MARK: Context usage

    /// The composer ring's published state (context-usage-ring §1.2): the
    /// newest carrier's per-call usage over the selected model's window. It is
    /// `.hidden` until a real measurement lands — the ring then shows the arc
    /// when the window is known, or the unknown state while a gateway model's
    /// window is still unknown, rather than vanishing. codex / dsh sessions
    /// never fill it.
    private(set) var contextUsage: ContextRingState = .hidden
    /// Catalog windows for this page visit; nil until the (retrying) read lands.
    @ObservationIgnored private var contextWindows: ContextWindowIndex?
    /// Uptime of the last catalog attempt, pacing the failed-read retry.
    @ObservationIgnored private var lastContextWindowAttempt: TimeInterval = 0
    /// The newest recomputed value, waiting for its publish slot.
    @ObservationIgnored private var stagedContextUsage: ContextRingState = .hidden
    /// Uptime of the last publish — the anchor of the 4 Hz cadence.
    @ObservationIgnored private var lastContextUsagePublish: TimeInterval = 0
    /// Publish cap: one per 250 ms, with the final value landed afterwards.
    private static let contextUsageInterval: TimeInterval = 0.25
    /// A failed catalog read waits at least this long before retrying.
    private static let contextWindowRetryInterval: TimeInterval = 5

    /// The ring's pipeline. Mirrors `SessionTimelinePresentation.run`: it runs
    /// for the page visit, recomputes on every observation, and publishes
    /// through a coalescing loop — at most four times a second, the trailing
    /// wake guaranteeing the newest value is never lost. The catalog is read
    /// once up front and retried on later observations until it lands.
    func runContextUsage(sessionID: V2SessionID) async {
        await refreshContextWindows(sessionID: sessionID, force: true)
        guard !Task.isCancelled else { return }
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        defer { signal.continuation.finish() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor [weak self] in
                guard let self else { return }
                defer { signal.continuation.finish() }
                for await observation in self.repository.observe(sessionId: sessionID) {
                    guard !Task.isCancelled else { return }
                    await self.receiveContextUsage(observation, sessionID: sessionID)
                    signal.continuation.yield(())
                }
            }
            group.addTask { @MainActor [weak self] in
                for await _ in signal.stream {
                    guard !Task.isCancelled, let self else { return }
                    await self.publishContextUsage()
                }
            }
            await group.waitForAll()
        }
    }

    /// One observation's recompute. A missing catalog read is retried here —
    /// throttled — until it lands; until then every recompute resolves nil.
    private func receiveContextUsage(_ observation: V2SessionObservation, sessionID: V2SessionID) async {
        if contextWindows == nil {
            await refreshContextWindows(sessionID: sessionID)
        }
        guard let data = observation.data else { return }
        stagedContextUsage = ContextRingState.resolve(items: data.items, windows: contextWindows,
            selection: currentSelections[.model])
    }

    /// Reads the model catalog and builds the selection → window index. A
    /// failure keeps the index nil (the ring hides) and the throttle paces the
    /// next attempt; a success is final for the page visit.
    private func refreshContextWindows(sessionID: V2SessionID, force: Bool = false) async {
        let now = ProcessInfo.processInfo.systemUptime
        if !force, now - lastContextWindowAttempt < Self.contextWindowRetryInterval { return }
        lastContextWindowAttempt = now
        do {
            let catalogs = try await repository.catalogs(sessionId: sessionID, capabilities: session.runtime.capabilities)
            guard session.isValid, !Task.isCancelled else { return }
            contextWindows = ContextWindowIndex(catalogs)
        } catch {
            // The ring stays hidden; the throttle paces the next attempt.
        }
    }

    /// The coalescing half: every wake waits out the 4 Hz slot and then lands
    /// the newest staged value, so a burst of frames costs one publish and
    /// still delivers its final value on the trailing wake.
    private func publishContextUsage() async {
        let wait = lastContextUsagePublish + Self.contextUsageInterval - ProcessInfo.processInfo.systemUptime
        if wait > 0 {
            do { try await Task.sleep(for: .seconds(wait)) } catch { return }
        }
        guard !Task.isCancelled else { return }
        if contextUsage != stagedContextUsage { contextUsage = stagedContextUsage }
        lastContextUsagePublish = ProcessInfo.processInfo.systemUptime
    }

    // MARK: Send queue

    /// Whether the composer's queue key may commit the draft. An enqueue is a
    /// purely local act — it must not wait on the turn to end, but it does need
    /// the session to still permit a send (freshness + capability) so the
    /// message can actually be drained when its turn comes.
    var canQueueSend: Bool { session.permitsQueuedSend && session.isValid }
    /// Increments once per successful enqueue. The View observes it as the
    /// trigger for the light-impact haptic (`.sensoryFeedback`), so the message
    /// that arrives at the editor is the same one the queue accepted.
    private(set) var queueEnqueueTick = 0

    /// Commits the editor's current draft into the queue. The draft is already
    /// mirrored onto `session.composer` by the editor's commit; this reads it,
    /// builds the queued message, clears the composer, and returns so the View
    /// can play its haptic. The eager attachment upload runs in the background
    /// so the tap never waits on the network.
    func enqueueComposer() async {
        // Only text opens the queue key: an attachment-only draft keeps the
        // stop key, so it must not sneak into the queue through a keyboard
        // commit either.
        guard canQueueSend,
              !session.composer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        guard let item = session.enqueueDraft() else { return }
        queueEnqueueTick += 1
        Task {
            _ = await uploadQueuedAttachments(item)
            // The upload may have been the last closed gate; give the queue its
            // turn now instead of waiting for the next frame.
            session.evaluateSendQueue()
        }
    }

    /// The banner's retry: re-run any incomplete uploads, clear the explicit
    /// pause, and let the session evaluate a drain. A retry while still offline
    /// keeps the offline pause in force — it does not bypass reachability.
    func retrySendQueue() async {
        await completeQueuedUploads()
        // `completeQueuedUploads` pauses the queue when an upload still fails;
        // resuming here must not clear that pause. Clear and re-arm it in one
        // step, before any evaluation, so a half-complete queue keeps the
        // banner (and its reason) instead of flashing a drain it cannot finish.
        let rearm = session.sendQueue.items.contains { !$0.isUploadComplete } ? session.sendQueue.explicitPause : nil
        session.sendQueue.resume()
        if let rearm { session.sendQueue.pause(rearm) }
        session.localWorkDidChange()
        session.evaluateSendQueue()
    }

    /// Uploads every queued message's remaining attachments. A failure pauses
    /// the queue with the failure reason (the banner is the only outlet for it,
    /// so no toast is raised here); a clean pass lets the session evaluate a
    /// drain. Called after a connect/foreground too, to finish uploads that
    /// began while offline.
    func completeQueuedUploads() async {
        for item in session.sendQueue.items where !item.isUploadComplete {
            // A failed upload pauses the queue; stop here and leave the rest.
            if await uploadQueuedAttachments(item) == false { return }
        }
        session.evaluateSendQueue()
    }

    /// Uploads one queued message's missing attachments, mirroring the send
    /// path's upload closure. Returns whether every attachment landed; a
    /// failure pauses the queue and reports false. Uploading never sends: the
    /// drain is a separate, gated step.
    @discardableResult
    private func uploadQueuedAttachments(_ item: V2QueuedMessage) async -> Bool {
        do {
            for attachment in item.attachments where attachment.uploaded == nil {
                let uploaded = try await attachments.upload(sessionId: session.id, attachments: [attachment.local])
                guard session.isValid, !Task.isCancelled else { throw CancellationError() }
                guard let file = uploaded.first else { throw HTTPError.invalidResponse }
                session.bindQueueUpload(itemID: item.id, localID: attachment.id, file: file)
                repository.draftDidChange()
            }
            return true
        } catch {
            guard session.isValid, !Task.isCancelled else { return false }
            // A lost path reads as a connection problem, not a send failure:
            // otherwise a retry while offline would relabel the banner with a
            // send-failure reason the user never hit.
            let failure = V2ClientFailure(error)
            session.sendQueue.pause(failure.kind == .offline ? .offline : .failure(failure.message))
            session.localWorkDidChange()
            return false
        }
    }

    func send(_ text: String) async {
        if let command = await catalogCommand(for: text) {
            session.composer.text = text
            await runCommand(command, raw: text)
            return
        }
        guard !isWorking, session.canSend, !session.composer.isComposing else { return }
        let draft = session.composer
        draft.text = text
        let selected = draft.attachments
        guard selected.isEmpty || canAttach else { return }
        isWorking = true
        error = nil
        defer { isWorking = false }
        _ = await session.sendDraft { pending in
                for attachment in pending.attachments where attachment.uploaded == nil {
                    let uploaded = try await self.attachments.upload(sessionId: self.session.id, attachments: [attachment.local])
                    guard self.session.isValid, !Task.isCancelled else { throw CancellationError() }
                    guard let file = uploaded.first else { throw HTTPError.invalidResponse }
                    pending.bindUpload(file, localID: attachment.id)
                    self.session.attachmentPreviews.remember(pending.attachments, clientID: pending.id)
                    self.repository.draftDidChange()
                }
        }
    }

    /// Stop is idempotent on the server (an already-finished turn answers 409,
    /// which the repository treats as success), so the tap always becomes a
    /// real attempt and every outcome lands on the existing error channel
    /// instead of a silent no-op — including while the projection is stale,
    /// when the ability to stop matters most.
    ///
    /// §A3 flip: the manual stop now asks the runtime to spare background
    /// work (`preserveBackground: true`), matching the terminal's Esc — a
    /// running SubAgent survives the turn stop and is stopped individually
    /// from its own control. This lands in the same version as those controls
    /// (the batch's release rule): without them a spared task would have no
    /// way to be stopped.
    func interrupt() async {
        guard !isWorking else { return }
        await perform { try await self.repository.interrupt(sessionId: self.session.id, preserveBackground: true) }
    }

    /// Stops one running SubAgent task (§A3). One tap per task: a second tap
    /// while the control is in flight is not a second request. The in-flight
    /// form is released by the card's terminal event (the task leaves the
    /// live set, so its control disappears) or, when that frame never lands,
    /// by the bounded release — never by a local optimistic rewrite.
    func stopSubagent(taskID: String) async {
        guard session.isValid, !stoppingSubagentTaskIDs.contains(taskID) else { return }
        stoppingSubagentTaskIDs.insert(taskID)
        let release = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: subagentStopReleaseDelay)
            guard !Task.isCancelled else { return }
            stoppingSubagentTaskIDs.remove(taskID)
            subagentStopReleases[taskID] = nil
        }
        subagentStopReleases[taskID] = release
        let reachedServer = await perform { try await self.repository.stopSubagent(sessionId: self.session.id, taskId: taskID) }
        guard !reachedServer else { return }
        // The attempt never reached the server (or the model was busy): roll
        // the in-flight form back so the tap is never a dead end. A real
        // failure already went out on the existing error channel.
        release.cancel()
        subagentStopReleases[taskID] = nil
        stoppingSubagentTaskIDs.remove(taskID)
    }

    func respond(notice: SessionNoticeModel, action: V2RuntimeNoticeAction) async {
        guard !isWorking, notice.canRespond(fresh: session.runtime.isFresh),
              notice.notice.actions.contains(action), notice.hasValidInput(for: action) else { return }
        let input = notice.payload(for: action)
        notice.begin(actionID: action.id)
        isWorking = true
        defer { isWorking = false }
        do {
            try await repository.respond(sessionId: session.id, noticeId: notice.id, actionId: action.id, input: input)
            notice.accepted()
            if notice.submission == .accepted { responseRevision += 1 }
        } catch { notice.fail(error) }
    }

    @discardableResult func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        error = nil
        defer { isWorking = false }
        do { try await operation(); return session.isValid }
        catch { if session.isValid { self.error = error.localizedDescription }; return false }
    }

    func download(_ fileID: String) async throws -> Data {
        try await attachments.download(sessionId: session.id, fileId: fileID)
    }

    func thumbnail(for file: V2AttachmentContent) async throws -> Data? {
        if let cached = session.attachmentPreviews.preview(for: file) { return cached }
        guard session.isValid, file.isImage, (file.size ?? 0) <= 25 * 1024 * 1024 else { return nil }
        let preview: Data?
        if file.readsFromDevice, let path = file.devicePath, let files, let meta = session.metadata {
            guard meta.connectorStatus == .online, session.network.availability != .offline else {
                throw V2ClientFailure(kind: .offline, message: String(localized: "设备或网络已离线"))
            }
            let downloaded = try await files.download(connectorId: meta.connectorId, root: file.root ?? meta.cwd ?? ".",
                entry: V2WorkspaceEntry(name: file.name ?? (path as NSString).lastPathComponent, path: path, type: "file", size: file.size, modifiedAt: nil))
            preview = await Task.detached(priority: .utility) { ChatImageThumbnail.make(url: downloaded.url) }.value
        } else if let id = file.fileId, !id.hasPrefix("local:") {
            let data = try await download(id)
            preview = await Task.detached(priority: .utility) { ChatImageThumbnail.make(data: data) }.value
        } else { return nil }
        try Task.checkCancellation()
        guard session.isValid else { return nil }
        if let preview { session.attachmentPreviews.cache(preview, for: file) }
        return preview
    }
}

struct CommandFeedback: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String?
}
