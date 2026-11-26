import Combine
import SwiftUI
import UIKit

/// The C4 product timeline: the SwiftUI page's chrome (opening gate,
/// pending/queue/approval events, navigation suspension) around the collection
/// container.
///
/// The retired SwiftUI `ChatTimelineView` was deleted (2026-11-16), so this is
/// the page's only timeline container. I10–I13/I14/I15/I20 and the Markdown
/// externalization stay in C5 — the history prompts render, but their load
/// actions are inert until that wiring lands.
struct TimelineChatTimelineView: View {
    let model: SessionChatModel
    /// The tab page this bridge belongs to; its reader position is stored per
    /// page so two tabs showing one session restore independently.
    private let paneRole: ChatPaneRole
    /// Whether this page is the selected tab. A hidden page keeps its stream
    /// data (the model stays live) but parks every apply: streaming flushes
    /// otherwise re-group and re-lay the whole off-screen window on the main
    /// thread — the frames the Devices page dropped while scrolling during a
    /// stream (pp 2026-11-26). The parked content lands when the tab returns.
    private let isPageActive: Bool
    /// The renderer this bridge built, in the model's raw-value terms.
    private let renderModeName: String
    /// The page's SwiftUI safe area, read inside the composer `safeAreaBar`
    /// and outside the list's ignore: bar + home indicator + keyboard. This is
    /// the single inset source (official formula); no keyboard notifications
    /// are involved.
    let safeAreaInsets: EdgeInsets
    @StateObject private var bridge: TimelineChatBridge
    /// The outline's outstanding "scroll to this message" request. The sheet
    /// posts targets here; the bridge owns the paging and the scroll.
    @ObservedObject private var jumpRequest: ConversationOutlineJumpRequest
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
    /// The tab switch window (shell). Parking applies here is what keeps a
    /// refresh from stacking on the system transition (b1668: 300–570 ms).
    @Environment(\.shellTabTransitioning) private var shellTabTransitioning
    // The chat type scale is stored in UserDefaults, which is not observable.
    // Reading the same keys through AppStorage makes a Settings change
    // re-evaluate this wrapper and produce a new height key/reconfigure.
    @AppStorage(ChatTypeSettings.schemeKey) private var typeSchemeRaw = ChatTypeScheme.compact.rawValue
    @AppStorage(ChatTypeSettings.bodySizeKey) private var typeBodySize = 0.0
    @AppStorage(ChatTypeSettings.customKey) private var typeCustomRaw = ""
    /// The phase the haptics describe: settled, never a transient flap.
    @State private var settledPhase: ChatTurnPhase = .idle
    @State private var phaseSettleTask: Task<Void, Never>?
    @State private var phaseSeeded = false
    /// Cues stay disarmed through the seed, so a page opened mid-turn does not
    /// buzz on appearance.
    @State private var phaseHapticsArmed = false
    /// One placement per bridge. The model-level arm is shared by every pane
    /// showing the session; a second pane (or a rebuilt page) still has to
    /// land somewhere instead of leaving the new collection at offset zero.
    @State private var didPlaceOpening = false
    /// While the page is hidden, a catch-up pulse lets the parked content land
    /// about once every 1.5 s instead of accumulating until the tab returns.
    /// Parking everything froze the display for ~1.1 s when the reader came
    /// back after 27–94 s away (b1673 log: one grouping of 1485 rows plus a
    /// whole-window rebuild); a bounded catch-up keeps the return cheap.
    @State private var inactiveCatchUp = false
    @State private var catchUpTask: Task<Void, Never>?

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onOpenLink: @escaping (URL) -> Bool,
         onSubAgent: @escaping (String) -> Void,
         jumpRequest: ConversationOutlineJumpRequest,
         safeAreaInsets: EdgeInsets = EdgeInsets(),
         renderMode: TimelineRenderMode = .merged,
         paneRole: ChatPaneRole = .chat,
         isPageActive: Bool = true) {
        self.model = model
        self.safeAreaInsets = safeAreaInsets
        self.renderModeName = renderMode.rawValue
        self.paneRole = paneRole
        self.isPageActive = isPageActive
        _jumpRequest = ObservedObject(wrappedValue: jumpRequest)
        _bridge = StateObject(wrappedValue: TimelineChatBridge(model: model,
            onAttachment: onAttachment, onFile: onFile, onOpenLink: onOpenLink,
            onSubAgent: onSubAgent,
            renderMode: renderMode, paneRole: paneRole))
    }

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var navigationIsSuspended: Bool {
        sidebarIsTransitioning || sidebarObscuresDetail || shellTabTransitioning
            || (!isPageActive && !inactiveCatchUp)
    }
    /// The official turn phase, from the same live signals the orb reads.
    /// Drives the `TurnStatusView` haptic transfer: entry into writing is a
    /// selection, `writing -> idle` is the single light impact.
    private var turnPhase: ChatTurnPhase {
        // A stopped turn is over for the user the moment they tap stop. The
        // row snapshots still say `running` until the connector's terminal
        // row lands, and holding the phase that long fired the phase haptic
        // seconds after the visual settled — a buzz with no visible cause
        // (device 2026-11-14: it used to ride the late ⚠️). The optimistic
        // stop (tap or accepted ack) ends the phase here, so the cue lands
        // with the notice instead.
        if model.session.runtime.stopRequested || model.session.runtime.predictedIdle {
            return .idle
        }
        let signals = model.orbActivitySignals
        return ChatTurnPhase.resolve(
            toolActive: signals.hasActiveToolItem,
            writing: signals.isStreamingAssistantText,
            reasoning: signals.hasActiveReasoningItem)
    }
    /// How long a phase must hold before its haptic plays. iOS merges impacts
    /// fired within roughly 0.1 s; 150 ms collapses the `writing → idle → tool`
    /// handover into one cue and keeps the end-of-stream impact close enough
    /// to feel immediate.
    ///
    /// Left exactly as b1254 (pp 2026-11-16): the missing tool cue during a
    /// sub-agent run was the child-row leak in `orbActivitySignals`, not this
    /// window, so the cadence stays the release the reader already knows.
    private static let phaseSettleWindow: Duration = .milliseconds(150)

    /// Feeds one live phase into the settle: the first observation seeds the
    /// state without a cue; later changes only play if they still hold after
    /// `phaseSettleWindow` (a change back cancels the pending cue entirely).
    private func settlePhase(_ phase: ChatTurnPhase) {
        if !phaseSeeded {
            phaseSeeded = true
            settledPhase = phase
            DispatchQueue.main.async { phaseHapticsArmed = true }
            return
        }
        phaseSettleTask?.cancel()
        phaseSettleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.phaseSettleWindow)
            guard !Task.isCancelled else { return }
            if settledPhase != phase { settledPhase = phase }
        }
    }

    private var typography: TimelineTypographySnapshot {
        let scale = ChatTypeSettings.resolve(
            schemeRaw: typeSchemeRaw,
            bodySizeRaw: typeBodySize > 0 ? typeBodySize : nil,
            customRaw: typeCustomRaw)
        return TimelineChatContentAdapter.typography(
            dynamicType: String(describing: dynamicType),
            layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
            boldText: legibilityWeight == .bold,
            scale: scale)
    }

    var body: some View {
        // The adapter rebuilds from these observable fields; reading them here
        // is what re-evaluates the representable when a stream flush changes
        // row text in place (the rows array identity does not move).
        let _ = model.timeline.flushRevision
        let _ = model.timeline.pendingMessages
        // A pending send changes layout when an upload fails (failed card
        // instead of a file tile). Reading the delivery state here makes the
        // representable re-evaluate, so the adapter re-signs the row and the
        // height key re-prices it.
        let _ = model.timeline.pendingMessages.map(\.delivery)
        let _ = model.session.notices.notices
        let _ = model.session.sendQueue.items
        // A queued row's own state and the queue-wide pause add/remove the
        // trailing accessory, which changes wrapping and the tail's height.
        let _ = model.session.sendQueue.items.map(\.state)
        let _ = model.session.isSendQueuePaused
        let _ = model.responseRevision
        let _ = model.timeline.windowRevision
        // State fields the signatures read but no row flush necessarily
        // accompanies: a turn ending changes every group's suppression and
        // the tail's status line, and the history prompts depend on the
        // session's page flags.
        let _ = model.isRunning
        let _ = model.isAwaitingReply
        let _ = model.orbActivity
        let phase = self.turnPhase
        let _ = model.session.hasNewerItems
        let _ = model.session.hasOlderItems
        let _ = model.session.localOlderAvailable
        let _ = model.session.isLoadingHistory
        let _ = model.session.metadata?.cwd

        TimelineCollectionView(
            content: bridge.adapter,
            measurer: bridge.adapter.measurer,
            typography: typography,
            safeAreaInsets: safeAreaInsets,
            onPhaseChanged: { transition in
                if transition.gestureBegan {
                    bridge.readerDidTakeOver()
                    // A new gesture owns the continuation counter: a quiet
                    // reader never chains zero-progress pages.
                    bridge.zeroProgressContinuations = 0
                }
            },
            onViewportChanged: { viewport in bridge.viewportChanged(viewport) },
            onControllerReady: { controller in bridge.attach(controller) })
            // Match the SwiftUI timeline's soft navigation-bar edge. The
            // collection view also sets its own top edge style; this covers
            // the page-level bar treatment.
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Official `ScrollDownIndicator` above the composer. The official
            // Code page hosts it on the leading side of its pills bar; AA has
            // no pills bar, and pp chose the centred position on device
            // (2026-10-27). `safeAreaInsets.bottom` is bar + home + keyboard;
            // the list is full-bleed, so this lifts the control clear of the
            // bar. Eight points also keeps the whole 44 pt target clear of
            // the composer bar's hit region; the old 2 pt gap was tight, and
            // pp reported the keyboard rising on a return tap (whether the
            // tap reached the composer is unconfirmed [I]).
            .overlay(alignment: .bottom) {
                CodeScrollDownIndicator(state: bridge.scrollDownIndicator) {
                    // The indicator is the reader's explicit return: a
                    // follow-only request would refuse a page in `.reading`
                    // (TimelineCollectionController.requestBottom).
                    // The prompt row is gone (R5), so this tap is also the
                    // explicit latest request: clear the post-history guard
                    // that requires a fresh bottom visit before auto-loading
                    // newer rows.
                    // This line is what tells the reader's own tap apart from
                    // the app pulling the page to the bottom on its own: a
                    // `timeline.bottom.request` with forced=1 and no
                    // `timeline.pill.tap` beside it is the app's doing.
                    ClientDiagnosticsLog.shared.record(
                        kind: "timeline.pill.tap",
                        sessionID: model.session.id,
                        detail: ["pane": paneRole.rawValue])
                    bridge.controller?.allowLatestAfterHistoryGesture()
                    bridge.controller?.requestBottom(animated: true, forced: true)
                }
                .padding(.bottom, safeAreaInsets.bottom + 8)
            }
            .opacity(model.openingPositionSettled ? 1 : 0)
            .allowsHitTesting(model.isOpeningReady)
            .accessibilityHidden(!model.isOpeningReady)
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                // One placement per bridge (or renderer rebuild). A tab switch
                // re-appears the same page; it must not re-place the reader —
                // the held page keeps its own scroll position. A rebuilt page
                // or a second pane sharing this model (Devices tab opening the
                // session already open in Chats) still lands somewhere: the
                // saved anchor when there is one, the bottom otherwise.
                guard ready, !didPlaceOpening else { return }
                didPlaceOpening = true
                // A renderer switch lands bottom: the two renderers build
                // different item spaces, so the saved anchor cannot resolve.
                let firstOpen = model.armOpeningPositionIfNeeded()
                let rendererChanged = model.takeOpeningRenderModeChange(renderModeName)
                if firstOpen || rendererChanged {
                    bridge.beginOpening()
                } else if let anchor = model.scrollAnchor(for: paneRole) {
                    bridge.restoreScrollAnchor(anchor)
                } else {
                    bridge.beginOpening()
                }
            }
            // A hidden page lands its parked content on a slow pulse; the
            // pulse is a normal resume, so the apply goes through the same
            // path the tab return uses.
            .onChange(of: isPageActive, initial: true) { _, active in
                catchUpTask?.cancel()
                guard !active else { inactiveCatchUp = false; return }
                catchUpTask = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1.5))
                        guard !Task.isCancelled else { return }
                        inactiveCatchUp = true
                        // The resume applies synchronously on the main actor;
                        // this window only has to cover the state hop.
                        try? await Task.sleep(for: .milliseconds(60))
                        guard !Task.isCancelled else { return }
                        inactiveCatchUp = false
                    }
                }
            }
            .onDisappear { catchUpTask?.cancel() }
            .onChange(of: jumpRequest.token) { _, _ in
                guard let rowID = jumpRequest.rowID else { return }
                Task { await bridge.jump(toRowID: rowID) }
            }
            .onChange(of: model.openingRefreshCompleted) { _, _ in
                // A cached window can be on screen before `open()` returns;
                // re-check the latest edge once the opening read is done.
                bridge.updateHistoryAvailability()
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                bridge.setNavigationSuspended(suspended)
            }
            .onChange(of: reduceMotion, initial: true) { _, value in
                bridge.setReduceMotion(value)
            }
            // A response needs no explicit return: the content change lands a
            // page waiting at `.end` on the new bottom inside that update (or
            // through the inset spring when the composer collapses). Asking
            // for an animated return here stacked a second 0.4 s spring on
            // top of the composer's 0.24 s collapse, so the bubble was placed
            // while the page still glided. The pending/queued handlers below
            // force a return only for a reader away from the bottom, where no
            // follow exists at all.
            .onChange(of: model.responseRevision) { _, _ in
                if model.isOpeningReady {
                    bridge.controller?.requestBottom(animated: true, forced: false)
                }
            }
            // A send made while the window does not reach the newest edge
            // switches to the latest page at send time. Waiting for the
            // upload/echo let the replacement land seconds later and the whole
            // page changed mid-send (pp 2026-10-31: an attachment sent from a
            // history window jumped when the latest page finally arrived).
            .onChange(of: model.session.pendingMessages.map(\.id)) { oldIDs, newIDs in
                let added = Set(newIDs).subtracting(oldIDs)
                guard !added.isEmpty,
                      model.session.pendingMessages.contains(where: { pending in
                          added.contains(pending.id)
                              && (pending.delivery == .sending || pending.delivery == .accepted)
                      }) else { return }
                // A send pins the page to the bottom until the reader
                // scrolls: the new turn's rows (working row, then tool rows)
                // must land at the bottom, not 76 pt short of it (device
                // 2026-11-15 02:00:53).
                bridge.controller?.beginStickyFollow()
                if model.session.hasNewerItems {
                    bridge.noteComposerSend()
                } else if model.isOpeningReady, !hasInteractions,
                          let controller = bridge.controller, controller.isViewLoaded,
                          !controller.viewport.measuredAtBottom {
                    // A send is an explicit intent to see the new bubble, but
                    // the reader may be up in this window's history where the
                    // follow gate refuses (`requestBottom(forced: false)`).
                    // Only that case needs the forced return: at the bottom,
                    // the pending row's insert already lands through the
                    // content change, and a second spring on top of the
                    // composer collapse is exactly what this path avoids.
                    controller.requestBottom(animated: true, forced: true)
                }
            }
            // A queued message is the same intent while a turn is running.
            // The id list only changes on additions/removals; a removal must
            // not yank the page.
            .onChange(of: model.session.sendQueue.items.map(\.id)) { oldIDs, newIDs in
                let added = Set(newIDs).subtracting(oldIDs)
                guard !added.isEmpty, model.isOpeningReady, !hasInteractions,
                      let controller = bridge.controller, controller.isViewLoaded,
                      !controller.viewport.measuredAtBottom else { return }
                controller.requestBottom(animated: true, forced: true)
            }
            .onChange(of: model.timeline.windowRevision) { _, _ in
                bridge.reassertOpening()
            }
            .onChange(of: hasInteractions, initial: true) { _, presented in
                bridge.controller?.setInteractionPresented(presented)
            }
            .onChange(of: model.session.hasOlderItems, initial: true) { _, _ in
                bridge.updateHistoryAvailability()
            }
            .onChange(of: model.session.localOlderAvailable, initial: true) { _, _ in
                bridge.updateHistoryAvailability()
            }
            .onChange(of: model.session.hasNewerItems, initial: true) { _, _ in
                bridge.updateHistoryAvailability()
            }
            .onChange(of: model.session.isLoadingHistory, initial: true) { _, _ in
                bridge.updateHistoryAvailability()
            }
            // I4's cold-load mask fallback: a no-op scroll or a window that
            // never arrives must not hold the mask forever.
            .task(id: model.isOpeningReady) {
                guard model.isOpeningReady else { return }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard !Task.isCancelled else { return }
                bridge.fallbackOpeningSettle()
            }
            .onDisappear {
                // The page may be hidden (tab switch) or torn down; either way
                // keep the reader's row so a rebuilt page returns to it.
                bridge.captureScrollAnchor()
                bridge.cancel()
            }
            // Official TurnStatusView transfer: the end of a stream is the
            // one light impact; other phase changes are selections. Streamed
            // tokens never play a haptic.
            // A phase change caused by the user's own stop is not a stream
            // event: the stop key already played its tap feedback, and the
            // phase's own cue would land right behind it as a second buzz
            // (device 2026-11-14). The stop's optimistic idle therefore never
            // plays here; only stream-driven transitions do.
            // The cue describes the *settled* phase, not every transient flap:
            // a text→tool handover flashes `idle` for a frame or two, and
            // playing both cues landed two buzzes 15–150 ms apart (pp
            // 2026-11-15; 49 of the 158 cues in the b1221 log sat <350 ms
            // from the previous one). `phaseSettleTask` collapses those.
            .sensoryFeedback(.selection, trigger: settledPhase) { old, new in
                phaseHapticsArmed
                    && TurnPhaseHaptics.feedback(from: old, to: new) == .selection
                    && !sidebarIsTransitioning && HapticGate.statusAllowed()
                    && !model.session.runtime.stopRequested
                    && !model.session.runtime.predictedIdle
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 1.0),
                             trigger: settledPhase) { old, new in
                phaseHapticsArmed
                    && TurnPhaseHaptics.feedback(from: old, to: new) == .impactLight
                    && !sidebarIsTransitioning && HapticGate.statusAllowed()
                    && !model.session.runtime.stopRequested
                    && !model.session.runtime.predictedIdle
            }
            .onChange(of: phase, initial: true) { _, new in
                settlePhase(new)
            }
            .onDisappear { phaseSettleTask?.cancel() }
            // Diagnostics trail for the "double buzz" report (device
            // 2026-11-14): record each settled cue with the gates that decide
            // whether the sensory feedback actually plays.
            .onChange(of: settledPhase) { old, new in
                guard phaseHapticsArmed else { return }
                let feedback = TurnPhaseHaptics.feedback(from: old, to: new)
                guard feedback != .none else { return }
                ClientDiagnosticsLog.shared.record(
                    kind: "timeline.haptic",
                    sessionID: model.session.id,
                    detail: [
                        "source": "phase-settled",
                        "from": String(old.rawValue),
                        "to": String(new.rawValue),
                        "feedback": feedback == .impactLight ? "impactLight" : "selection",
                        "allowed": (!sidebarIsTransitioning && HapticGate.statusAllowed()
                            && !model.session.runtime.stopRequested
                            && !model.session.runtime.predictedIdle) ? "1" : "0",
                        "stopRequested": model.session.runtime.stopRequested ? "1" : "0",
                        "predictedIdle": model.session.runtime.predictedIdle ? "1" : "0",
                    ],
                    dedupe: false)
            }
            // The working row's text is the "the server has this message"
            // signal; its first appearance plays one selection cue. The send
            // itself and the bubble stay silent (pp 2026-11-16).
            .sensoryFeedback(.selection, trigger: bridge.sendConfirmedTick) { _, _ in
                !sidebarIsTransitioning && HapticGate.statusAllowed()
                    && !model.session.runtime.stopRequested
                    && !model.session.runtime.predictedIdle
            }
            .onChange(of: bridge.sendConfirmedTick) { _, _ in
                ClientDiagnosticsLog.shared.record(
                    kind: "timeline.haptic",
                    sessionID: model.session.id,
                    detail: [
                        "source": "send-confirmed",
                        "allowed": (!sidebarIsTransitioning && HapticGate.statusAllowed()
                            && !model.session.runtime.stopRequested
                            && !model.session.runtime.predictedIdle) ? "1" : "0",
                        "stopRequested": model.session.runtime.stopRequested ? "1" : "0",
                        "predictedIdle": model.session.runtime.predictedIdle ? "1" : "0",
                    ],
                    dedupe: false)
            }
            // The Code page's tool detail (official full-screen presentation).
            // Rows report taps through the adapter; this page-level sheet
            // survives the streaming reconfigures that rebuild every cell.
            .sheet(item: $bridge.codeDetailRequest) { request in
                switch request {
                case let .tool(tool):
                    // The official first layer is the span summary list;
                    // tapping one of its rows pushes the single-call page.
                    CodeToolGroupDetailView(calls: tool.calls,
                                            cwd: model.session.metadata?.cwd,
                                            chat: model)
                case let .thinking(thinking):
                    CodeThinkingDetailView(text: thinking.text, itemID: thinking.id,
                                           sourceIDs: thinking.sourceIDs, chat: model,
                                           startsAtBottom: thinking.startsAtBottom,
                                           onOpenLink: bridge.onOpenLink)
                case let .stepGroup(stepGroup):
                    CodeStepGroupDetailView(group: stepGroup.group,
                                            cwd: model.session.metadata?.cwd,
                                            chat: model,
                                            liveGroups: bridge.adapter.liveStepGroups,
                                            startsAtBottom: stepGroup.startsAtBottom)
                }
            }
#if AA_TIMELINE_PROBE
            // The store rides the page lifecycle; the UI entry points moved
            // to the session menu and Settings (2026-10-31).
            .modifier(TimelineProbeAttachment(controller: bridge.controller,
                                              adapter: bridge.adapter,
                                              ready: bridge.controllerAttached))
#endif
    }

}

/// Owns the adapter and the controller handshake. A struct cannot capture
/// itself in the representable's escaping callbacks; this reference box keeps
/// the opening/event state in one place.
@MainActor
final class TimelineChatBridge: ObservableObject {
    let model: SessionChatModel
    let adapter: TimelineChatContentAdapter
    /// The tab page this bridge belongs to (reader position is per page).
    let paneRole: ChatPaneRole
    /// The page's body-link router; the thinking detail renders File
    /// references too and must resolve them the same way the rows do.
    let onOpenLink: (URL) -> Bool
    /// Only the floating return control observes this; the page body stays
    /// unscaled by scroll-driven visibility changes.
    let scrollDownIndicator = CodeScrollDownIndicatorState()
    private(set) weak var controller: TimelineCollectionController?
    /// Probe-only attach trigger: a weak `controller` cannot publish, and the
    /// floating overlay must learn when the representable hands one over.
    @Published private(set) var controllerAttached = false
    /// Gesture-triggered zero-progress pages continue loading until rows
    /// appear; a new gesture resets the counter so a parked reader never
    /// chains pages.
    var zeroProgressContinuations = 0
    /// The Code page's tool detail sheet. Held at the page level, not in the
    /// row: a streaming reconfigure rebuilds the hosted cell's view, and a
    /// cell-local `@State` sheet could be dismissed mid-read.
    @Published var codeDetailRequest: CodePageDetailRequest?
    /// One tick per server-acknowledged send: the page plays the send's
    /// confirmation haptic on this edge (pp 2026-11-16).
    @Published private(set) var sendConfirmedTick = 0
    private(set) var readerTookOver = false
    private var navigationSuspended = false
    private var reduceMotion = false
    private var openingPending = false
    private var openingSettled = false
    private var historyGeneration = 0
    private var isLoadingOlder = false
    private var isLoadingLatest = false
    /// Whether the last published viewport was at the newest edge. The edge
    /// transition is the signal that the projection may stop history-anchoring.
    private var wasAtBottom = false

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onOpenLink: @escaping (URL) -> Bool,
         onSubAgent: @escaping (String) -> Void,
         renderMode: TimelineRenderMode = .merged,
         paneRole: ChatPaneRole = .chat) {
        self.model = model
        self.paneRole = paneRole
        self.onOpenLink = onOpenLink
        let adapter = TimelineChatContentAdapter(model: model, onAttachment: onAttachment,
                                                 onFile: onFile, onOpenLink: onOpenLink,
                                                 onSubAgent: onSubAgent,
                                                 renderMode: renderMode)
        self.adapter = adapter
        // The adapter owns the row views; the page owns the presentation.
        adapter.onCodeToolDetail = { [weak self] request in
            self?.codeDetailRequest = .tool(request)
        }
        adapter.onCodeThinkingDetail = { [weak self] request in
            self?.codeDetailRequest = .thinking(request)
        }
        adapter.onCodeStepGroupDetail = { [weak self] request in
            self?.codeDetailRequest = .stepGroup(request)
        }
        adapter.onWorkingTextShown = { [weak self] in
            self?.sendConfirmedTick &+= 1
        }
    }

    func attach(_ controller: TimelineCollectionController) {
        self.controller = controller
        controllerAttached = true
        adapter.attach(controller)
        // Do not read the indicator state here: attach runs from
        // `onControllerReady` before SwiftUI loads the controller's view, and
        // the viewport getter dereferences the not-yet-created collection view
        // (build 601 crashed on open). The first viewport publication delivers
        // the initial value through this callback.
        controller.onScrollDownIndicatorChanged = { [weak self] visible in
            self?.scrollDownIndicator.isVisible = visible
        }
        controller.onApplyCompleted = { [weak self] in self?.applyCompleted() }
        controller.onBottomArrived = { [weak self] in self?.openingArrived() }
        controller.onLoadOlder = { [weak self] in self?.loadOlder() }
        controller.onLoadLatest = { [weak self] in self?.loadLatest() }
        controller.onReaderScrollToTop = { [weak self] in self?.readerDidTakeOver() }
        controller.onNeedsOlder = { [weak self] in self?.loadOlder() }
        controller.onNeedsLatest = { [weak self] in
            // The opening path owns its own latest fetch; a viewport trigger
            // must wait until the page is ready or the two reads race.
            guard let self else { return }
            guard self.model.openingRefreshCompleted else {
                self.controller?.rearmLatestAutoLoad()
                return
            }
            self.loadLatest(auto: true)
        }
        adapter.onLoadOlder = { [weak self] in self?.loadOlder() }
        adapter.onLoadLatest = { [weak self] in self?.loadLatest() }
        controller.setNavigationSuspended(navigationSuspended)
        controller.setReduceMotion(reduceMotion)
        controller.setInteractionPresented(hasInteractions)
        updateHistoryAvailability()
        if openingPending, !controller.items.isEmpty { applyCompleted() }
    }

    /// Scrolls to the row that carries `rowID`, paging older history while the
    /// row is not in the loaded window. Returns true when the row landed.
    @discardableResult
    func jump(toRowID rowID: String) async -> Bool {
        if scrollToLoadedRow(rowID) { return true }
        var pages = 0
        // The outline lists everything the row store holds (5000 rows), and a
        // history page is 200 rows; 40 pages covers that whole cache when the
        // goal is the oldest row in the list.
        while pages < 40, model.session.canLoadOlder, !Task.isCancelled {
            let oldest = model.session.timeline.first?.value.orderSeq
            await model.session.loadOlder()
            pages += 1
            // The collection's diffable data source applies on the next run
            // loop tick; poll briefly instead of racing the apply.
            for _ in 0..<20 {
                if scrollToLoadedRow(rowID) { return true }
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            if model.session.timeline.first?.value.orderSeq == oldest { break }
        }
        return false
    }

    private func scrollToLoadedRow(_ rowID: String) -> Bool {
        guard let controller,
              let item = adapter.item(containingRow: rowID),
              let path = controller.indexPath(for: item) else { return false }
        controller.collectionView.scrollToItem(at: path, at: .centeredVertically, animated: true)
        return true
    }

    /// Keeps the reader's row and offset on the model so a rebuilt tab page
    /// can return to the same place (official holds the page itself; AA holds
    /// the model and this anchor).
    func captureScrollAnchor() {
        // `viewport` dereferences the implicitly-unwrapped collection view;
        // onDisappear can run before (or after) the controller's view exists.
        guard let controller else { return recordAnchorSkip("no_controller") }
        guard controller.isViewLoaded else { return recordAnchorSkip("not_loaded") }
        guard let anchor = controller.anchor(at: controller.viewport.offsetY) else {
            return recordAnchorSkip("no_anchor")
        }
        model.setScrollAnchor(
            ChatScrollAnchor(itemID: anchor.id, offsetIntoRow: anchor.offsetIntoRow),
            for: paneRole)
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.anchor.capture",
            sessionID: model.session.id,
            detail: ["pane": paneRole.rawValue, "item": anchor.id,
                     "offset": String(Int(anchor.offsetIntoRow.rounded()))])
    }

    private func recordAnchorSkip(_ reason: String) {
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.anchor.capture.skip",
            sessionID: model.session.id,
            detail: ["pane": paneRole.rawValue, "reason": reason])
    }

    /// Restores a saved reader position after the page is rebuilt. The row
    /// store window is already present (the model stayed open), so this is a
    /// placement, not a history request.
    func restoreScrollAnchor(_ anchor: ChatScrollAnchor) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            ClientDiagnosticsLog.shared.record(
                kind: "timeline.anchor.restore.start",
                sessionID: self.model.session.id,
                detail: ["pane": self.paneRole.rawValue, "item": anchor.itemID,
                         "offset": String(Int(anchor.offsetIntoRow.rounded()))])
            for attempt in 1...20 {
                if self.restoreLoadedAnchor(anchor) {
                    ClientDiagnosticsLog.shared.record(
                        kind: "timeline.anchor.restore",
                        sessionID: self.model.session.id,
                        detail: ["pane": self.paneRole.rawValue,
                                 "item": anchor.itemID,
                                 "attempts": String(attempt)])
                    return
                }
                // The anchor cannot land (row gone with the window, or the
                // page never loaded). A fresh page defaults to the bottom;
                // leaving it at the oldest loaded row is the bug this restore
                // exists to prevent. A reader who already scrolled owns the
                // page and is left alone.
                if self.readerTookOver {
                    ClientDiagnosticsLog.shared.record(
                        kind: "timeline.anchor.restore.abandoned",
                        sessionID: self.model.session.id,
                        detail: ["pane": self.paneRole.rawValue, "reason": "reader"])
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard !self.readerTookOver else {
                ClientDiagnosticsLog.shared.record(
                    kind: "timeline.anchor.restore.abandoned",
                    sessionID: self.model.session.id,
                    detail: ["pane": self.paneRole.rawValue, "reason": "reader"])
                return
            }
            ClientDiagnosticsLog.shared.record(
                kind: "timeline.anchor.fallback",
                sessionID: self.model.session.id,
                detail: ["pane": self.paneRole.rawValue, "item": anchor.itemID,
                         "controller": self.controller == nil ? "nil" : "loaded"])
            self.beginOpening()
        }
    }

    private func restoreLoadedAnchor(_ anchor: ChatScrollAnchor) -> Bool {
        // Same nil-window rule as capture: the retry loop runs through the
        // representable's attach → viewDidLoad window.
        guard let controller, controller.isViewLoaded else { return false }
        // A retained tab page is already at the captured point. Re-scrolling
        // there would run a full collection layout during the tab switch — a
        // visible hitch for no move at all.
        if let current = controller.anchor(at: controller.viewport.offsetY),
           current.id == anchor.itemID,
           abs(current.offsetIntoRow - anchor.offsetIntoRow) < 0.5 {
            return true
        }
        guard let item = adapter.item(forItemID: anchor.itemID),
              let path = controller.indexPath(for: item) else { return false }
        // A settled bottom-follow target must not pull the reader back down
        // while the restored position is placed.
        controller.disarmBottom()
        controller.collectionView.scrollToItem(at: path, at: .top, animated: false)
        if anchor.offsetIntoRow > 0.5 {
            var offset = controller.collectionView.contentOffset
            offset.y += anchor.offsetIntoRow
            let maxY = controller.collectionView.contentSize.height
                - controller.collectionView.bounds.height
                + controller.collectionView.adjustedContentInset.bottom
            offset.y = min(offset.y, maxY)
            controller.collectionView.setContentOffset(offset, animated: false)
        }
        return true
    }

    /// The prompt/pull gates read the session's page flags, not a copy that
    /// goes stale after a request.
    func updateHistoryAvailability() {
        controller?.canLoadOlder = model.session.isValid && model.session.canLoadOlder
            && !model.session.isLoadingHistory && !isLoadingOlder
        controller?.canLoadLatest = model.session.isValid && model.session.hasNewerItems
            && !model.session.isLoadingHistory && !isLoadingLatest
        if !model.session.hasNewerItems { controller?.rearmLatestAutoLoad() }
        // A window flag can arrive while the viewport is already parked at an
        // edge; no scroll will fire to re-run the auto-page check.
        controller?.requestOlderIfNearTop()
        controller?.requestLatestIfAtBottom()
    }

    /// The reader is at the newest edge of the held window. This is the only
    /// place the projection stops anchoring on a history row; live creates
    /// then append without waiting for the latest page.
    func viewportChanged(_ viewport: TimelineViewport) {
        let atBottom = viewport.measuredAtBottom
        guard atBottom != wasAtBottom else { return }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(
            "bridge viewport bottom=\(wasAtBottom ? 1 : 0)->\(atBottom ? 1 : 0) "
            + "off=\(viewport.offsetY) contentH=\(viewport.contentHeight) "
            + "visH=\(viewport.visibleHeight) inset=\(viewport.topInset)")
#endif
        wasAtBottom = atBottom
        if atBottom {
            model.session.followLatest()
        } else if controller?.isReaderScrolling == true {
            // Only a reader-owned scroll may abandon a local-first latest
            // page's background reconcile. A window replacement flips this
            // edge while it swaps the content and offset; cancelling there
            // dropped the new reply until the page was reopened (device report
            // 2026-10-31 08:31). Explicit history paging cancels its own
            // reconcile in `loadOlder`.
            model.session.cancelLatestReconcile()
        }
    }

    private func loadOlder() {
        guard !navigationSuspended, model.session.isValid,
              model.session.canLoadOlder, !model.session.isLoadingHistory,
              !isLoadingOlder, let controller else {
            // The one-shot near-top trigger already disarmed when it fired;
            // no read started, so nothing will move the viewport off the top
            // to re-arm it. Restore it or the reader must tap the prompt.
            self.controller?.rearmOlderAutoLoad()
            return
        }
        // Capture the row under the viewport top and the current first row
        // before the request. The adapter installs the absolute prepend
        // target on the refresh that brings the new page, before the
        // controller applies it.
        // A history load is a browsing action; a bottom follow target left
        // from an earlier state must not fight the prepend's anchor.
        controller.disarmBottom()
        // A prepend that trims the far-newest edge bumps `windowRevision`;
        // the opening re-assert must not pull a reader who is browsing history
        // back to the bottom.
        readerDidTakeOver()
        guard let anchor = controller.visibleAnchorRowID(),
              let before = adapter.firstRowID else {
            controller.rearmOlderAutoLoad()
            return
        }
        // The visible row, not the oldest row: the projection must keep the
        // reader's place while it trims the far-old and far-new edges.
        let anchorOrderSeq = adapter.orderSeq(forRowID: anchor)
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(
            "bridge loadOlder anchor=\(anchor) order=\(anchorOrderSeq.map { String($0) } ?? "-") "
            + "beforeFirst=\(before) items=\(controller.items.count) "
            + "older=\(model.session.hasOlderItems ? 1 : 0) "
            + "local=\(model.session.localOlderAvailable ? 1 : 0)")
#endif
        // Official-style history paging: the anchor driver keeps the reading
        // placement; the adapter does not install a one-shot firstRowID target.
        controller.beginHistoryPaging(anchorRowID: anchor)
        isLoadingOlder = true
        adapter.historyLoadDirection = .older
        historyGeneration &+= 1
        adapter.pendingHistoryRequest = .init(generation: historyGeneration,
            anchorRowID: anchor, beforeFirstRowID: before, edge: .top,
            createdAt: .now)
        updateHistoryAvailability()
        // Capture the window before the page arrives so a zero-progress page
        // (rows that merge into an already-visible group, so the group count
        // and the window size both stay put) can continue automatically.
        let itemsBefore = controller.items.count
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.session.loadOlder(anchorOrderSeq: anchorOrderSeq)
            self.adapter.historyLoadDirection = nil
            self.isLoadingOlder = false
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteHistory(
                "bridge loadOlder done off=\(self.controller?.collectionView.contentOffset.y ?? -1) "
                + "items=\(self.controller?.items.count ?? 0) "
                + "newer=\(self.model.session.hasNewerItems ? 1 : 0) "
                + "older=\(self.model.session.hasOlderItems ? 1 : 0) "
                + "local=\(self.model.session.localOlderAvailable ? 1 : 0)")
#endif
            self.updateHistoryAvailability()
            self.continueOlderIfZeroProgress(itemsBefore: itemsBefore)
        }
    }

    /// A gesture-triggered page that produced no visible rows keeps loading
    /// until something shows or the store runs out, bounded per gesture.
    ///
    /// The reader's gesture already armed the trigger; without this, one
    /// gesture can only ever load one page, and a page whose rows all merge
    /// into an already-visible group is invisible (b754 report: six fires,
    /// items stuck at 156, `older=0 local=1`). The counter resets on the next
    /// gesture, so a parked reader is never chain-loaded.
    private static let zeroProgressContinuationLimit = 4

    private func continueOlderIfZeroProgress(itemsBefore: Int) {
        guard !navigationSuspended, let controller else { return }
        guard controller.items.count == itemsBefore,
              model.session.localOlderAvailable,
              model.session.canLoadOlder,
              !model.session.isLoadingHistory, !isLoadingOlder else {
            zeroProgressContinuations = 0
            return
        }
        guard zeroProgressContinuations < Self.zeroProgressContinuationLimit else {
            zeroProgressContinuations = 0
            return
        }
        zeroProgressContinuations += 1
        controller.rearmOlderAutoLoad()
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(
            "auto-older continue page=\(zeroProgressContinuations) "
            + "items=\(controller.items.count)")
#endif
        loadOlder()
    }

    /// A composer send made while the window does not reach the newest edge
    /// switches to the latest page now. The pending bubble then lands in the
    /// newest window with the reply, instead of the whole window changing
    /// seconds later when the upload/echo finally lands.
    func noteComposerSend() {
        guard model.session.hasNewerItems else { return }
        loadLatest(authoritative: true)
    }

    private func loadLatest(auto: Bool = false, authoritative: Bool = false) {
        guard !navigationSuspended, model.session.isValid,
              model.session.hasNewerItems, !model.session.isLoadingHistory,
              !isLoadingLatest else { return }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(
            "bridge loadLatest auto=\(auto ? 1 : 0) auth=\(authoritative ? 1 : 0) "
            + "off=\(controller?.collectionView.contentOffset.y ?? -1) "
            + "items=\(controller?.items.count ?? 0)")
#endif
        if !auto { controller?.allowLatestAfterHistoryGesture() }
        isLoadingLatest = true
        adapter.historyLoadDirection = .latest
        updateHistoryAvailability()
        // The newer window can replace every row before the post-await return
        // runs; record the return intent first so the apply can re-resolve the
        // bottom against the new content (device report 2026-10-23).
        controller?.beginWindowReplacementReturn()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.session.loadLatest(authoritative: authoritative)
            self.adapter.historyLoadDirection = nil
            self.isLoadingLatest = false
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteHistory(
                "bridge loadLatest done auto=\(auto ? 1 : 0) auth=\(authoritative ? 1 : 0) "
                + "off=\(self.controller?.collectionView.contentOffset.y ?? -1) "
                + "items=\(self.controller?.items.count ?? 0) "
                + "newer=\(self.model.session.hasNewerItems ? 1 : 0)")
#endif
            // A stale local-first page intentionally keeps `hasNewerItems`
            // until its background reconcile lands. Do not let the bottom
            // trigger immediately start the same read again.
            if self.model.session.hasNewerItems {
                self.controller?.suppressLatestAutoLoad()
            }
            self.updateHistoryAvailability()
            // A viewport-triggered load must not yank a reader who scrolled
            // into history while it was in flight. A manual latest request
            // owns the return as before.
            if !auto || self.controller?.viewport.measuredAtBottom == true {
                self.controller?.requestBottom(animated: true, forced: true)
            }
        }
    }

    func beginOpening() {
        openingPending = true
        // A new opening: reset the driver's "landing reported" fact so the
        // cold landing places directly again. Without it every session after
        // the first skipped the direct landing and glided in from the top
        // (b1648 regression).
        controller?.beginOpeningBottom(resetLanding: true)
        // A cached snapshot can already be applied before `isOpeningReady`
        // flips; no later apply completion would settle the mask. Defer one
        // main-queue turn so the newly built representable has laid out.
        if controller?.items.isEmpty == false {
            DispatchQueue.main.async { [weak self] in self?.applyCompleted() }
        }
    }

    private func applyCompleted() {
        guard openingPending, let controller else { return }
        // Settle only on the measured arrival. `onApplyCompleted` can fire
        // before the first layout; releasing the mask then would reveal the
        // top of the window before the return lands (the old path waits for
        // the tail/visible-bottom verdict, with 400 ms only as a fallback).
        guard controller.settleOpeningBottom() else { return }
        openingSettled = true
        openingPending = false
        model.openingPositionDidSettle()
        controller.requestLatestIfAtBottom()
    }

    /// The measured viewport reached the bottom after the apply completion
    /// (e.g. pending measurements changed the content height). Release the
    /// cold-load mask here instead of waiting for the 400 ms fallback.
    private func openingArrived() {
        guard openingPending, let controller, controller.viewport.measuredAtBottom else { return }
        openingPending = false
        openingSettled = true
        model.openingPositionDidSettle()
        controller.requestLatestIfAtBottom()
    }

    /// The old timeline's 400 ms bounded fallback: release the cold-load mask
    /// even when the first return never lands (no-op scroll, missed target).
    func fallbackOpeningSettle() {
        guard !openingSettled else { return }
        openingSettled = true
        openingPending = false
        model.openingPositionDidSettle()
    }

    /// A whole-window replacement (opening trim/latest-page surgery, recovery
    /// snapshot) re-asserts the opening return unless the reader has taken over
    /// or the drawer is moving. The controller's forced target does the same
    /// instant landing the opening used.
    func reassertOpening() {
        guard !readerTookOver, !navigationSuspended, model.isOpeningReady,
              controller?.isHistoryPrependActive != true else { return }
        controller?.beginOpeningBottom()
    }

    func readerDidTakeOver() {
        readerTookOver = true
        openingPending = false
    }

    func setNavigationSuspended(_ suspended: Bool) {
        navigationSuspended = suspended
        controller?.setNavigationSuspended(suspended)
    }

    func setReduceMotion(_ value: Bool) {
        reduceMotion = value
        controller?.setReduceMotion(value)
    }

    func cancel() {
        openingPending = false
    }

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
}
