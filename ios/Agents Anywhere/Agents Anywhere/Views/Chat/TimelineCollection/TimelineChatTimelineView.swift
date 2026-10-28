import Combine
import SwiftUI
import UIKit

/// The C4 product timeline: the SwiftUI page's chrome (opening gate,
/// pending/queue/approval events, navigation suspension) around the collection
/// container.
///
/// The old `ChatTimelineView` stays intact and selectable; this view is only
/// built when `aa.timeline.collectionView` is on. I10–I13/I14/I15/I20 and the
/// Markdown externalization stay in C5 — the history prompts render, but their
/// load actions are inert until that wiring lands.
struct TimelineChatTimelineView: View {
    let model: SessionChatModel
    /// The page's SwiftUI safe area, read inside the composer `safeAreaBar`
    /// and outside the list's ignore: bar + home indicator + keyboard. This is
    /// the single inset source (official formula); no keyboard notifications
    /// are involved.
    let safeAreaInsets: EdgeInsets
    @StateObject private var bridge: TimelineChatBridge
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
    // The chat type scale is stored in UserDefaults, which is not observable.
    // Reading the same keys through AppStorage makes a Settings change
    // re-evaluate this wrapper and produce a new height key/reconfigure.
    @AppStorage(ChatTypeSettings.schemeKey) private var typeSchemeRaw = ChatTypeScheme.compact.rawValue
    @AppStorage(ChatTypeSettings.bodySizeKey) private var typeBodySize = 0.0
    @AppStorage(ChatTypeSettings.customKey) private var typeCustomRaw = ""

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void,
         safeAreaInsets: EdgeInsets = EdgeInsets()) {
        self.model = model
        self.safeAreaInsets = safeAreaInsets
        _bridge = StateObject(wrappedValue: TimelineChatBridge(model: model,
            onAttachment: onAttachment, onFile: onFile, onSubAgent: onSubAgent))
    }

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var navigationIsSuspended: Bool {
        sidebarIsTransitioning || sidebarObscuresDetail
    }
    /// The official turn phase, from the same live signals the orb reads.
    /// Drives the `TurnStatusView` haptic transfer: entry into writing is a
    /// selection, `writing -> idle` is the single light impact.
    private var turnPhase: ChatTurnPhase {
        let signals = model.orbActivitySignals
        return ChatTurnPhase.resolve(
            toolActive: signals.hasActiveToolItem,
            writing: signals.isStreamingAssistantText,
            reasoning: signals.hasActiveReasoningItem)
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
        let _ = model.disclosures.revision
        let _ = model.responseRevision
        let _ = model.timeline.windowRevision
        // State fields the signatures read but no row flush necessarily
        // accompanies: a turn ending changes every group's suppression and
        // the tail's status line, and the history prompts depend on the
        // session's page flags.
        let _ = model.isRunning
        let _ = model.sendingPlaceholder
        let _ = model.orbActivity
        let phase = self.turnPhase
        let _ = model.session.hasNewerItems
        let _ = model.session.hasOlderItems
        let _ = model.session.isLoadingHistory
        let _ = model.session.metadata?.cwd

        TimelineCollectionView(
            content: bridge.adapter,
            measurer: bridge.adapter.measurer,
            typography: typography,
            safeAreaInsets: safeAreaInsets,
            onPhaseChanged: { transition in
                if transition.gestureBegan { bridge.readerDidTakeOver() }
            },
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
                    bridge.controller?.requestBottom(animated: true, forced: true)
                }
                .padding(.bottom, safeAreaInsets.bottom + 8)
            }
            .opacity(model.openingPositionSettled ? 1 : 0)
            .allowsHitTesting(model.isOpeningReady)
            .accessibilityHidden(!model.isOpeningReady)
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                if ready { bridge.beginOpening() }
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                bridge.setNavigationSuspended(suspended)
            }
            .onChange(of: reduceMotion, initial: true) { _, value in
                bridge.setReduceMotion(value)
            }
            // A pending/queued row needs no explicit return: its insertion is
            // a content change, and a page waiting at `.end` lands on the new
            // bottom inside that update (or through the inset spring when the
            // composer collapses). Asking for an animated return here stacked
            // a second 0.4 s spring on top of the composer's 0.24 s collapse,
            // so the bubble was placed while the page still glided.
            .onChange(of: model.responseRevision) { _, _ in
                if model.isOpeningReady {
                    bridge.controller?.requestBottom(animated: true, forced: false)
                }
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
            .onDisappear { bridge.cancel() }
            // Official TurnStatusView transfer: the end of a stream is the
            // one light impact; other phase changes are selections. Streamed
            // tokens never play a haptic.
            .sensoryFeedback(.selection, trigger: phase) { old, new in
                TurnPhaseHaptics.feedback(from: old, to: new) == .selection
            }
            .sensoryFeedback(.impact(weight: .light, intensity: 1.0),
                             trigger: phase) { old, new in
                TurnPhaseHaptics.feedback(from: old, to: new) == .impactLight
            }
            // The Code page's tool detail (official full-screen presentation).
            // Rows report taps through the adapter; this page-level sheet
            // survives the streaming reconfigures that rebuild every cell.
            .sheet(item: $bridge.codeDetailRequest) { request in
                switch request {
                case let .tool(tool):
                    CodeToolDetailView(call: tool.call,
                                       followingCalls: tool.following,
                                       cwd: model.session.metadata?.cwd)
                case let .thinking(thinking):
                    CodeThinkingDetailView(text: thinking.text)
                }
            }
            // Probe builds add a floating diagnostics button; other builds
            // compile the call site to `self` (TimelineProbe.swift).
            .timelineProbeOverlay(controller: bridge.controller,
                                  adapter: bridge.adapter,
                                  ready: bridge.controllerAttached)
#if AA_TIMELINE_PROBE
            // Copies the C3 inset log (proxy value, inherited animation
            // duration, offset before/after) without a screen recording. The
            // list ignores the safe area, so the pill sits on the leading
            // edge at mid-height — inside the reachable area on every device.
            .overlay(alignment: .leading) {
                AnchorProbeLogOverlay().padding(.leading, 8)
            }
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
    /// Only the floating return control observes this; the page body stays
    /// unscaled by scroll-driven visibility changes.
    let scrollDownIndicator = CodeScrollDownIndicatorState()
    private(set) weak var controller: TimelineCollectionController?
    /// Probe-only attach trigger: a weak `controller` cannot publish, and the
    /// floating overlay must learn when the representable hands one over.
    @Published private(set) var controllerAttached = false
    /// The Code page's tool detail sheet. Held at the page level, not in the
    /// row: a streaming reconfigure rebuilds the hosted cell's view, and a
    /// cell-local `@State` sheet could be dismissed mid-read.
    @Published var codeDetailRequest: CodePageDetailRequest?
    private(set) var readerTookOver = false
    private var navigationSuspended = false
    private var reduceMotion = false
    private var openingPending = false
    private var openingSettled = false
    private var historyGeneration = 0
    private var isLoadingOlder = false
    private var isLoadingLatest = false

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void) {
        self.model = model
        let adapter = TimelineChatContentAdapter(model: model, onAttachment: onAttachment,
                                                 onFile: onFile, onSubAgent: onSubAgent)
        self.adapter = adapter
        // The adapter owns the row views; the page owns the presentation.
        adapter.onCodeToolDetail = { [weak self] request in
            self?.codeDetailRequest = .tool(request)
        }
        adapter.onCodeThinkingDetail = { [weak self] request in
            self?.codeDetailRequest = .thinking(request)
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
        adapter.onLoadOlder = { [weak self] in self?.loadOlder() }
        adapter.onLoadLatest = { [weak self] in self?.loadLatest() }
        controller.setNavigationSuspended(navigationSuspended)
        controller.setReduceMotion(reduceMotion)
        controller.setInteractionPresented(hasInteractions)
        updateHistoryAvailability()
        if openingPending, !controller.items.isEmpty { applyCompleted() }
    }

    /// The prompt/pull gates read the session's page flags, not a copy that
    /// goes stale after a request.
    func updateHistoryAvailability() {
        controller?.canLoadOlder = model.session.isValid && model.session.hasOlderItems
            && !model.session.isLoadingHistory && !isLoadingOlder
        controller?.canLoadLatest = model.session.isValid && model.session.hasNewerItems
            && !model.session.isLoadingHistory && !isLoadingLatest
    }

    private func loadOlder() {
        guard !navigationSuspended, model.session.isValid,
              model.session.hasOlderItems, !model.session.isLoadingHistory,
              !isLoadingOlder, let controller else { return }
        // Capture the row under the viewport top and the current first row
        // before the request. The adapter installs the absolute prepend
        // target on the refresh that brings the new page, before the
        // controller applies it.
        // A history load is a browsing action; a bottom follow target left
        // from an earlier state must not fight the prepend's anchor.
        controller.disarmBottom()
        guard let anchor = controller.visibleAnchorRowID(),
              let before = adapter.firstRowID else { return }
        isLoadingOlder = true
        historyGeneration &+= 1
        adapter.pendingHistoryRequest = .init(generation: historyGeneration,
            anchorRowID: anchor, beforeFirstRowID: before, edge: .top,
            createdAt: .now)
        updateHistoryAvailability()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.session.loadOlder()
            self.isLoadingOlder = false
            self.updateHistoryAvailability()
        }
    }

    private func loadLatest() {
        guard !navigationSuspended, model.session.isValid,
              model.session.hasNewerItems, !model.session.isLoadingHistory,
              !isLoadingLatest else { return }
        isLoadingLatest = true
        updateHistoryAvailability()
        // The newer window can replace every row before the post-await return
        // runs; record the return intent first so the apply can re-resolve the
        // bottom against the new content (device report 2026-10-23).
        controller?.beginWindowReplacementReturn()
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.session.loadLatest()
            self.isLoadingLatest = false
            self.updateHistoryAvailability()
            // The latest page lands at the bottom; an explicit request owns
            // the return even if the reader had scrolled into history.
            self.controller?.requestBottom(animated: true, forced: true)
        }
    }

    func beginOpening() {
        openingPending = true
        controller?.beginOpeningBottom()
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
    }

    /// The measured viewport reached the bottom after the apply completion
    /// (e.g. pending measurements changed the content height). Release the
    /// cold-load mask here instead of waiting for the 400 ms fallback.
    private func openingArrived() {
        guard openingPending, let controller, controller.viewport.measuredAtBottom else { return }
        openingPending = false
        openingSettled = true
        model.openingPositionDidSettle()
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
        guard !readerTookOver, !navigationSuspended, model.isOpeningReady else { return }
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
