import SwiftUI
import QuickLook
import UIKit

struct SessionChatView: View, Equatable {
    @StateObject private var storage: StableViewModel<SessionChatModel>
    private var model: SessionChatModel { storage.value }
    private let sessionIdentity: V2SessionModel
    let deviceName: String?
    let fallbackTitle: String?
    let fallbackRuntimeName: String?
    let onMenu: () -> Void
    @State private var sheet: SessionSheet?
    @State private var expandedNoticeID: String?
    /// Shared app-level loader for the instant image viewer: one disk cache and
    /// one in-flight table per signed-in session (owned by V2ClientServices),
    /// reused by every session view.
    private let imageLoader: AttachmentImageLoader
    private let fileService: V2WorkspaceFilesService
    private let detailService: V2SessionDetailService
    /// The app-scoped workspace file catalog store, keyed by `(connectorId,
    /// cwd)`. Observed so a background load landing re-renders the timeline;
    /// the same instance is shared across session views, so one root is listed
    /// once (3.3a).
    private let fileList: WorkspaceFileListModel
    /// The catalog for the session's own workspace root, once its (background)
    /// load has landed. `nil` before that — every path stays plain text until
    /// it arrives, and the renderer re-parses then.
    private var catalog: WorkspaceFileCatalog? {
        guard let meta = session.metadata, let root = meta.cwd, !root.isEmpty else { return nil }
        return fileList.catalog(connectorId: meta.connectorId, root: root)
    }
    private enum SessionSheet: Identifiable {
        case notices, details, files
        /// The SubAgent panel: the anchor card id plus its entry point. The
        /// capsule (entry A) lists every active card; a timeline card (entry B)
        /// shows that one card's detail alone (pp 2026-10-08).
        case subagents(String, fromCapsule: Bool)
        case preview(SessionFileReference, root: String? = nil)
        /// The instant image viewer: opens on the thumbnail the bubble already
        /// decoded (nil when it has none) while the loader serves the original.
        /// `localData` carries the original bytes for an image still held
        /// locally (an optimistic send with no `openUrl` yet); when present the
        /// viewer decodes it directly and skips the loader entirely.
        case attachmentImage(V2AttachmentContent, image: UIImage?, tappedAt: Date, localData: Data? = nil)
        /// The disambiguation picker (B1): a raw in-message path matched several
        /// workspace files, so the user chooses one instead of the client
        /// guessing. Carries the ranked candidates and the original location.
        case fileChoice(FileOpenChoice)
        var id: String {
            switch self {
            case .notices: "notices"
            case .details: "details"
            case .files: "files"
            case .subagents(let cardID, let fromCapsule): "subagents:\(fromCapsule ? "capsule" : "card"):\(cardID)"
            case .preview(let reference, let root): "file:\(root ?? ""):\(reference.id)"
            case .attachmentImage(let file, _, _, _): "attachment:\(file.fileId ?? file.cacheKey)"
            case .fileChoice(let choice): "fileChoice:\(choice.id)"
            }
        }
    }
    /// A pending "which file did you mean?" decision: the original requested
    /// path, the connector's ranked candidates, and the source location to carry
    /// into the preview once a file is chosen.
    private struct FileOpenChoice: Identifiable {
        let requested: String
        let candidates: [V2WorkspaceFileCandidate]
        let location: SessionFileReference?
        var id: String { requested }
    }
    @State private var previewURL: URL?
    @State private var previewDirectory: URL?
    @State private var isDownloading = false
    /// The welcome line shows only for a settled, genuinely empty page — a
    /// queued message counts as content even before its timeline rows exist.
    /// Kept out of the overlay's ViewBuilder: the four-way conjunction inside
    /// a builder pushes the type checker past its budget (it timed out once).
    private var showsEmptyState: Bool {
        model.isOpeningReady && model.timeline.rows.isEmpty
            && model.timeline.pendingMessages.isEmpty && model.session.sendQueue.isEmpty
    }

    /// The bottom dock stack, in its own method: the composer's initializer and
    /// this chain's other closures together exceed the type checker's budget
    /// (the chain has timed it out more than once).
    private func composerDockArea(maximumEditorHeight: CGFloat) -> some View {
        VStack(spacing: 0) {
            // B (pp 2026-10-06): the SubAgent capsule is the dock's
            // first row — it takes its own space above the composer
            // instead of floating over the timeline's last row.
            SubAgentCapsuleSlot(model: model, onOpen: { sheet = .subagents($0, fromCapsule: true) })
                .traceChatLayout("subagent-capsule")
            SessionInteractionDock(chat: model,
                onShowAll: { expandedNoticeID = $0; sheet = .notices })
                .traceChatLayout("interaction-dock")
            ChatComposerDock(draft: session.composer, settings: model.settings,
                maximumEditorHeight: maximumEditorHeight, controls: controls,
                canSend: session.canSend, canAttach: model.canAttach,
                canSelectModel: session.runtime.allows("catalog.model"),
                canSelectPermission: session.runtime.allows("catalog.permission"),
                isStreaming: model.isComposerStreaming, canStop: session.runtime.permitsInterruptAttempt(),
                isBusy: model.isWorking || !model.isOpeningReady, placeholder: requiresTakeover ? String(localized: "请先接管") : String(localized: "询问 Agents"),
                isLoadingSettings: model.isLoadingSettings,
                settingsError: model.settingsError, sessionChat: model,
                contextUsage: model.contextUsage,
                onSend: model.send, onStop: model.interrupt, onLoadSettings: model.loadSettings,
                onApplySettings: model.applySettings, applyError: { model.settingsError },
                onDraftChange: { model.repository.draftDidChange() },
                canQueueSend: model.canQueueSend, queueEnqueueTick: model.queueEnqueueTick,
                onQueueSend: { await model.enqueueComposer() })
                .traceChatLayout("composer-dock")
        }
        .frame(maxWidth: ChatControlMetrics.maximumContentWidth).frame(maxWidth: .infinity)
        // Native safe-area layout owns both the visible scroll
        // region and the dock's space; do not add a second margin.
    }

    /// The sheet bodies live in their own method: the same switch inline in the
    /// modifier chain is what timed the type checker out (adding the queue's
    /// task call above it tipped the enclosing chain over its budget).
    @ViewBuilder private func sheetContent(for destination: SessionSheet) -> some View {
        switch destination {
        case .notices: SessionNoticesSheet(model: model, initialNoticeID: expandedNoticeID)
        case .details: SessionDetailsSheet(chat: model, service: detailService)
        case .subagents(let cardID, let fromCapsule):
            SubAgentPanelSheet(chat: model, deviceName: deviceName, fallbackRuntimeName: fallbackRuntimeName,
                initialCardID: cardID, opensFromCapsule: fromCapsule, onFile: openFile, onAttachment: openAttachment,
                catalog: catalog)
        case .files:
            if let meta = session.metadata, let cwd = meta.cwd {
                WorkspaceFilesSheet(connectorId: meta.connectorId,
                    deviceName: deviceName ?? meta.connectorId,
                    workspace: V2DeviceWorkspace(path: cwd, name: String(localized: "会话文件"), sessionCount: 1, lastActiveAt: nil),
                    service: fileService, session: session)
            }
        case .preview(let reference, let root):
            if let meta = session.metadata {
                WorkspaceFilePreviewSheet(connectorId: meta.connectorId, root: root ?? meta.cwd ?? ".", path: reference.path,
                    service: fileService, session: session, location: reference)
            }
        case .attachmentImage(let file, let image, let tappedAt, let localData):
            AttachmentImageViewerSheet(file: file, initialImage: image, tappedAt: tappedAt, loader: imageLoader, localData: localData)
        case .fileChoice(let choice):
            FileCandidateChooserSheet(requested: choice.requested, candidates: choice.candidates,
                onSelect: { candidate in chooseFile(candidate.path, location: choice.location) })
        }
    }
    @State private var toasts = ChatToastStore()
    @State private var pendingTakeover: Bool?
    @State private var hasStartedLoading = false
    @Environment(\.colorScheme) private var colorScheme
    /// A foreground return re-pulls the workspace file list (刷新时机 (b)).
    @Environment(\.scenePhase) private var scenePhase
    /// The app-level connection state. Its top banner already reports a
    /// connectivity outage, so this view withholds connection-class toasts while
    /// that banner is up (one incident, one message) and drops its own toasts
    /// below the banner when both are on screen.
    @EnvironmentObject private var appState: AppState
    @ScaledMetric(relativeTo: .body) private var bodyLineHeight: CGFloat = 22
    @ScaledMetric(relativeTo: .footnote) private var takeoverPillHeight: CGFloat = 32

    init(session: V2SessionModel, services: V2ClientServices, deviceName: String?,
         fallbackTitle: String? = nil, fallbackRuntimeName: String? = nil,
         onMenu: @escaping () -> Void) {
        _storage = StateObject(wrappedValue: StableViewModel {
            let chat = SessionChatModel(session: session, repository: services.sessionRepository, attachments: services.attachments,
                files: services.workspaceFiles)
            chat.onEditCreation = { [weak services, weak session] pending in
                if let session { services?.editCreation(session, pending: pending) }
            }
            chat.onDiscardCreation = { [weak services] in services?.discardCreation(session.id) }
            return chat
        })
        sessionIdentity = session
        self.deviceName = deviceName
        self.fallbackTitle = fallbackTitle
        self.fallbackRuntimeName = fallbackRuntimeName
        fileService = services.workspaceFiles; detailService = services.sessionDetail
        fileList = services.workspaceFileList
        imageLoader = services.attachmentImageLoader
        self.onMenu = onMenu
    }
    private var controls: ChatControlMetrics { .init(bodyLineHeight: bodyLineHeight) }
    private var session: V2SessionModel { model.session }
    private var requiresTakeover: Bool { session.metadata?.takeover == false }
    /// Approximate height of the app-level connection banner (RootView) so the
    /// session toast column clears it. The banner owns the exact geometry; this
    /// is only a stand-off and the 8pt gap tolerates the small error.
    private static let connectionBannerHeight: CGFloat = 72
    /// The app-level connection banner is showing; its message already covers a
    /// connectivity outage, so the session surface defers to it.
    private var connectionBannerVisible: Bool { appState.restoreConnectionError != nil }
    private var visibleToasts: [ChatToast] { toasts.visible(hidingConnectivity: connectionBannerVisible) }
    // Sidebar motion changes the containing card, not the session. Observable
    // model changes and real size/environment changes still update this subtree.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.sessionIdentity === rhs.sessionIdentity && lhs.deviceName == rhs.deviceName
            && lhs.fallbackTitle == rhs.fallbackTitle && lhs.fallbackRuntimeName == rhs.fallbackRuntimeName
    }
    var body: some View {
        GeometryReader { geometry in
            Group {
                if hasStartedLoading {
                    ChatTimelineView(model: model,
                        onAttachment: openAttachment, onFile: openFile, catalog: catalog,
                        onSubAgent: { sheet = .subagents($0, fromCapsule: false) })
                } else {
                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
                .overlay {
                    if showsEmptyState {
                        VStack(spacing: 12) {
                            Text(String(localized: "在这里继续你的任务")).foregroundStyle(.secondary)
                        }.allowsHitTesting(false)
                    }
                }
                .overlay { if model.showsOpeningMask { openingMask } }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    composerDockArea(maximumEditorHeight: min(160, max(72, geometry.size.height * 0.30)))
                }
                .overlay(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 4) {
                        // Metadata can arrive after history. Transient controls
                        // float below the header instead of resizing its inset.
                        if requiresTakeover {
                            takeoverPill.frame(maxWidth: .infinity, alignment: .center)
                        }
                        // The queue's own failure surface: first under the takeover
                        // pill, above the general error toasts, so a paused queue
                        // never duplicates its reason as a toast (§7.6) and stays
                        // the only place the queue resumes from.
                        SendQueueBanner(model: model)
                            .traceChatLayout("send-queue-banner")
                        ChatErrorToasts(items: visibleToasts, isRetrying: session.isLoading,
                            onRetry: { _ in await session.refresh() }, onDismiss: { toasts.dismiss($0) })
                        if let success = model.commandSuccess {
                            CommandSuccessToast(feedback: success) { model.commandSuccess = nil }
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        if let switched = model.switchFeedback {
                            CommandSuccessToast(feedback: switched) { model.switchFeedback = nil }
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                    }
                    // Drop clear of the app-level connection banner when it is
                    // up, so the two never stack at the same height.
                    .padding(.top, connectionBannerVisible ? Self.connectionBannerHeight + 8 : 8)
                }
        }
        .modifier(ChatPageToolbar(title: session.metadata?.title ?? fallbackTitle ?? String(localized: "会话"),
            subtitle: SessionHeaderSubtitle.text(metadata: session.metadata, deviceName: deviceName,
                fallbackRuntimeName: fallbackRuntimeName),
            status: model.headerStatus, alignsTitleLeading: true, onMenu: onMenu))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { sheet = .files } label: { AppSymbol("folder") }
                    .accessibilityLabel(String(localized: "文件管理"))
                    .disabled(session.metadata?.cwd?.isEmpty != false)
                Menu {
                    Button(String(localized: "会话详情与导出"), systemImage: "info.circle") { sheet = .details }
                    Button(String(localized: "复制会话 ID"), systemImage: "number") { UIPasteboard.general.string = session.id }
                } label: { AppSymbol("ellipsis") }
                .accessibilityLabel(String(localized: "会话菜单"))
            }
        }
        .modifier(SessionTakeoverConfirmation(pending: $pendingTakeover, isDsh: model.isDsh) { enabled in
            model.error = nil
            if !(await model.setTakeover(enabled)), let error = model.takeoverError { model.error = error }
        })
        // The cue is driven by authoritative turn endings, not by the running
        // flag's edge: an optimistic turn end (an accepted interrupt before
        // its facts land) and any status no live read confirmed can no longer
        // announce a completion the user never saw.
        .completionFeedback(trigger: session.runtime.authoritativeTurnEnds) { previous, current in
            current > previous && model.isOpeningReady && session.runtime.isFresh
                && session.runtime.state?.status == .idle
        }
        .sidebarDrawerSettledTask(id: hasStartedLoading) { settled in
            guard !hasStartedLoading, settled else { return }
            // Show feedback immediately, but let the drawer's completed
            // animation and the selection's final layout leave the main thread.
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { hasStartedLoading = true }
        }
        .task(id: hasStartedLoading) {
            guard hasStartedLoading else { return }
            // Reattaching a loaded detail only resumes observation.
            await model.prepareOpening()
            guard !Task.isCancelled else { return }
            // Recover a queue restored from disk: any attachment upload the last
            // page left in flight is finished here, and the queue re-evaluates
            // once its messages are whole. Runs before the long-lived loops
            // below, which only return when the view goes away.
            await model.completeQueuedUploads()
            guard !Task.isCancelled else { return }
            // The context ring observes the same repository stream as the
            // timeline: both loops share this task's lifetime and stop when
            // the view's task is cancelled.
            let chat = model
            let timeline = chat.timeline
            let repository = chat.repository
            let sessionID = session.id
            async let timelineRun: Void = timeline.run(sessionID: sessionID, repository: repository)
            async let usageRun: Void = chat.runContextUsage(sessionID: sessionID)
            _ = await (timelineRun, usageRun)
        }
        // (a) The workspace file catalog loads on its own task — background and
        // best-effort — after the page has already opened, so it never delays
        // the first frame. Its path links appear once this lands.
        .task(id: hasStartedLoading) {
            guard hasStartedLoading else { return }
            await loadFileCatalog()
        }
        // (b) The App returning to the foreground re-pulls the list — a file
        // written while backgrounded becomes clickable without a page reload.
        // The (re)load only fires for this view's own session root.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await refreshFileCatalog() }
        }
        .sheet(item: $sheet) { destination in
            sheetContent(for: destination)
        }
        .environment(\.openURL, OpenURLAction { url in
            // The file chip / card open through `FileLink` (`aafile://open?path=`).
            // Route it through the same `openReference` path as the inline
            // `aa-workspace-file` links, so absolute-vs-relative resolution and
            // the candidate chooser behave identically.
            if let raw = FileLink.path(from: url) {
                openReference(SessionFileReference.parse(raw))
                return .handled
            }
            if let reference = SessionFileReference.reference(from: url) {
                // The path resolves against the cached workspace catalog
                // client-side (no server scan); the line/column from the link
                // ride along so the preview still focuses the source location.
                openReference(reference)
                return .handled
            }
            return ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
        .quickLookPreview($previewURL)
        .onChange(of: previewURL) { _, url in if url == nil { cleanPreview() } }
        .onDisappear { if previewURL == nil { cleanPreview() } }
        .onChange(of: session.failure, initial: true) { _, failure in
            toasts.update(source: "session", failure: failure, canRetry: failure?.kind != .authentication)
        }
        .onChange(of: model.error, initial: true) { _, message in
            toasts.update(source: "operation", failure: message.map { V2ClientFailure(kind: .rejected, message: $0) })
        }
        .onChange(of: model.commandFailure) { _, feedback in
            // Each command failure is new, even when its text repeats a dismissed one.
            toasts.update(source: "command", failure: nil)
            toasts.update(source: "command", failure: feedback.map { V2ClientFailure(kind: .rejected, message: $0.message ?? "") }, title: feedback?.title)
        }
        .onChange(of: model.openingError, initial: true) { _, message in
            toasts.update(source: "opening", failure: message.map { V2ClientFailure(kind: .unavailable, message: $0) })
        }
        // The runtime's durable error, disclosed as its own notice. The field
        // outlives any single view, so this refires on every state read; the
        // store pins a dismissal to the event it acknowledged (the error code
        // plus its params), so the same incident cannot revive on reconnect
        // while a changed payload re-opens the notice.
        .onChange(of: ChatRuntimeErrorNotice.make(for: session.runtime.state?.error), initial: true) { _, notice in
            toasts.update(source: "runtime", notice: notice)
        }
        // The self-heal acknowledgement: the client rebuilt the session's data
        // from a snapshot because the incremental recovery could not be
        // applied. Its own source, so it never masks or inherits the session
        // failure it resolves. The disclosure is one-shot: once pushed to the
        // toast store it is cleared on the model (and the repository entry
        // behind it), so re-entering the session page cannot replay a notice
        // already shown; a later rebuild publishes a fresh, higher-numbered
        // payload that re-opens a dismissed toast instead of staying silent.
        // Only a non-nil notice is forwarded: clearing the field drives a
        // second change, and the store's `update(failure: nil)` would tear the
        // just-shown toast down again.
        .onChange(of: session.recoveryNotice, initial: true) { _, notice in
            guard let notice else { return }
            toasts.update(source: "sync-recovery",
                          failure: V2ClientFailure(kind: .transient, message: notice.message),
                          title: notice.title)
            session.clearRecoveryNotice()
        }
    }

    private var openingMask: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            VStack(spacing: 12) {
                if let error = model.openingError, !model.timeline.hasPresentedSnapshot {
                    Text(error).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button(String(localized: "重试")) { Task { await model.prepareOpening() } }
                } else {
                    ProgressView().progressViewStyle(.circular).accessibilityLabel(String(localized: "正在加载会话"))
                }
            }
            .padding(24).frame(maxWidth: 320)
        }
        .transition(.identity)
    }

    private var takeoverPill: some View {
        Button { pendingTakeover = true } label: {
            Label(String(localized: "接管会话以继续交互"), appSymbol: "hand.raised")
                .font(.footnote.weight(.medium))
                .foregroundStyle(AppTheme.primaryText(colorScheme))
                .padding(.horizontal, 14).frame(minHeight: takeoverPillHeight)
                .glassEffect(.regular.interactive(), in: .capsule)
                .frame(minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain).disabled(!model.canChangeTakeover)
        .accessibilityIdentifier("chat.session.takeover")
        .padding(.horizontal, 20).padding(.bottom, 4)
    }

    private func openFile(_ path: String) {
        guard session.isValid, !path.isEmpty else {
            openFailed(String(localized: "无法打开这个文件。"))
            return
        }
        openReference(SessionFileReference(path: path))
    }

    /// Opens a file reference using the cached workspace catalog, entirely
    /// client-side (§3.3c) — no server scan and no network round trip before
    /// the preview.
    ///
    /// - A full absolute path opens directly and never consults the catalog
    ///   (a very large workspace may truncate it out of the list); the server
    ///   preview decides existence / directory / missing and reports it.
    /// - A bare name or relative path resolves against the catalog: an exact or
    ///   single suffix hit opens directly, several hits ask the user to choose,
    ///   and no hit opens the raw path as-is.
    /// - With no catalog yet, the raw path opens directly (the list is still
    ///   loading in the background; the click is never blocked on it).
    private func openReference(_ reference: SessionFileReference) {
        let raw = reference.path
        guard session.isValid, !raw.isEmpty else {
            openFailed(String(localized: "无法打开这个文件。"))
            return
        }
        let absolute = SessionFileReference.isAbsolutePath(raw)
        // A bare name needs the session's workspace root; opening it against the
        // wrong root is exactly the bug this path avoids, so a missing cwd is an
        // explicit message. A full absolute path never needs the root.
        guard absolute || session.metadata?.cwd?.isEmpty == false else {
            openFailed(String(localized: "会话没有工作区根目录，无法打开文件。"))
            return
        }
        guard !absolute, let catalog else {
            // No catalog yet, or an absolute path: open as-is.
            present(SessionFileReference(path: raw, line: reference.line, column: reference.column))
            return
        }
        switch FileReferenceResolution.resolve(SessionFileReference.stripLineColumn(raw), catalog: catalog) {
        case .open(let path):
            present(SessionFileReference(path: path, line: reference.line, column: reference.column))
        case .choose(let candidates):
            let located = candidates.map {
                V2WorkspaceFileCandidate(path: $0, relative: $0, name: ($0 as NSString).lastPathComponent, score: 0)
            }
            sheet = .fileChoice(FileOpenChoice(requested: raw, candidates: located, location: reference))
        case .openAsIs(let path):
            present(SessionFileReference(path: path, line: reference.line, column: reference.column))
        }
    }

    /// Presents the preview for a resolved reference. The path is opened as-is;
    /// the server preview reports "directory" / "missing" on its own failure
    /// surface, so nothing is silently swallowed.
    private func present(_ reference: SessionFileReference) {
        guard session.isValid else { return }
        sheet = .preview(reference)
    }

    /// Opens a resolved preview from the candidate chooser, carrying the original
    /// source location so the preview focus survives disambiguation.
    private func chooseFile(_ path: String, location: SessionFileReference?) {
        guard session.isValid else { return }
        sheet = .preview(SessionFileReference(path: path, line: location?.line, column: location?.column))
    }

    /// (a) Background load of the workspace file catalog on session open. Never
    /// awaited on the render path — the page opens first, the paths become
    /// clickable when this lands.
    private func loadFileCatalog() async {
        guard let meta = session.metadata, let root = meta.cwd, !root.isEmpty else { return }
        await fileList.load(connectorId: meta.connectorId, root: root, service: fileService)
    }

    /// (b) Re-pulls the catalog (App returned to the foreground). Replaces any
    /// previous list for this root.
    private func refreshFileCatalog() async {
        guard let meta = session.metadata, let root = meta.cwd, !root.isEmpty else { return }
        await fileList.refresh(connectorId: meta.connectorId, root: root, service: fileService)
    }

    /// The shared, user-visible failure surface for opening a file. Uses the
    /// same `opening` toast source as the session-opening errors so a single
    /// kind of problem never stacks two toasts.
    private func openFailed(_ message: String) {
        toasts.update(source: "opening", failure: V2ClientFailure(kind: .unavailable, message: message))
    }

    private func openAttachment(_ file: V2AttachmentContent, thumbnail: UIImage?) {
        if file.readsFromDevice, let path = file.devicePath { sheet = .preview(SessionFileReference(path: path), root: file.root); return }
        // Images with a local original in hand — an optimistic send still in
        // flight, or a message waiting in the queue — open the instant viewer
        // straight on those bytes: no `openUrl` exists until the upload binds a
        // server id, so the network path below would 404. The loader is skipped
        // for this sheet.
        if let local = session.localImageRoute(for: file) {
            let initial = thumbnail ?? UIImage(data: local)
            sheet = .attachmentImage(file, image: initial, tappedAt: Date(), localData: local)
            return
        }
        // Images on the raw byte route open the instant viewer: it presents on
        // the thumbnail already in hand (the bubble's decoded image, or the
        // preview bytes the store kept for local sends) while the original
        // loads behind it. Everything else — non-images, and image payloads
        // without an `openUrl` — keeps the existing QuickLook chain unchanged.
        if file.isImage, file.openUrl != nil {
            let initial = thumbnail ?? session.attachmentPreviews.preview(for: file).flatMap { UIImage(data: $0) }
            sheet = .attachmentImage(file, image: initial, tappedAt: Date())
            return
        }
        guard !isDownloading, let fileID = file.fileId else { return }
        isDownloading = true
        model.error = nil
        Task { @MainActor in
            defer { isDownloading = false }
            do {
                let data = try await model.download(fileID)
                guard session.isValid, sheet == nil else { return }
                cleanPreview()
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("aa-preview-\(UUID().uuidString)", isDirectory: true)
                let name = (file.name ?? String(localized: "Attachment")) as NSString
                let safeName = name.lastPathComponent.isEmpty ? String(localized: "Attachment") : name.lastPathComponent
                let url = directory.appendingPathComponent(safeName)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                previewDirectory = directory; previewURL = url
            } catch { model.error = String(localized: "图片还没准备好，稍后再试；发送完成后即可查看。") }
        }
    }
    private func cleanPreview() {
        if let directory = previewDirectory { try? FileManager.default.removeItem(at: directory) }
        previewDirectory = nil
    }
}

/// The disambiguation picker for an in-message path that matched several
/// workspace files (层 B1). The candidates arrive ranked by the connector; the
/// user picks one and that file is previewed. Nothing is auto-selected — a bare
/// name that is not unique must never resolve by guess (宁缺勿假).
private struct FileCandidateChooserSheet: View {
    let requested: String
    let candidates: [V2WorkspaceFileCandidate]
    let onSelect: (V2WorkspaceFileCandidate) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List(candidates) { candidate in
                Button {
                    // Selecting a candidate swaps the presented item to the
                    // preview; the chooser is not dismissed separately, since
                    // that would nil the same binding and cancel the swap.
                    onSelect(candidate)
                } label: {
                    HStack(spacing: 12) {
                        AppSymbol("doc.text")
                        VStack(alignment: .leading, spacing: 5) {
                            Text(candidate.name).foregroundStyle(.primary)
                            Text(candidate.relative)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                    }.padding(.vertical, 6).contentShape(.rect)
                }.buttonStyle(.plain)
            }
            .navigationTitle(String(localized: "选择要打开的文件"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { SheetCloseToolbar { dismiss() } }
            .safeAreaInset(edge: .top, spacing: 0) {
                Text(String(localized: "『\(requested)』在工作区里匹配到多个文件，请选择要打开的一个。"))
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
            }
        }
        .appSheetPresentation(.compact)
    }
}

/// Command success is transient, like the Web/Desktop toast; failures use the
/// dismissible error toasts instead.
private struct CommandSuccessToast: View {
    let feedback: CommandFeedback
    let onDismiss: () -> Void

    var body: some View {
        Button(action: onDismiss) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                AppSymbol("checkmark.circle", size: 14).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(feedback.title).font(.subheadline.weight(.medium))
                    if let message = feedback.message, !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, ChatControlMetrics.collapsedHorizontalInset)
        .accessibilityHint(String(localized: "轻点关闭"))
        .task(id: feedback.id) {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { onDismiss() }
        }
    }
}
