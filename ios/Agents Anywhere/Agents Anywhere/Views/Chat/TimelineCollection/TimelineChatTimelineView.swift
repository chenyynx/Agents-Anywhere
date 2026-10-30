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
         safeAreaInsets: EdgeInsets = EdgeInsets(),
         renderMode: TimelineRenderMode = .code) {
        self.model = model
        self.safeAreaInsets = safeAreaInsets
        _bridge = StateObject(wrappedValue: TimelineChatBridge(model: model,
            onAttachment: onAttachment, onFile: onFile, onSubAgent: onSubAgent,
            renderMode: renderMode))
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
        let _ = model.session.localOlderAvailable
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
                    // The official first layer is the span summary list;
                    // tapping one of its rows pushes the single-call page.
                    CodeToolGroupDetailView(calls: tool.calls,
                                            cwd: model.session.metadata?.cwd)
                case let .thinking(thinking):
                    CodeThinkingDetailView(text: thinking.text)
                case let .stepGroup(stepGroup):
                    CodeStepGroupDetailView(group: stepGroup.group,
                                            cwd: model.session.metadata?.cwd,
                                            liveGroups: bridge.adapter.liveStepGroups,
                                            startsAtBottom: stepGroup.startsAtBottom)
                }
            }
#if AA_TIMELINE_PROBE
            // Both probe entry points sit on the leading edge at mid-height:
            // the top-trailing corner belongs to the status bar / navigation
            // chrome on a real device and cannot be tapped. Stacking them
            // keeps the timeline report and the C3 inset log reachable.
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 8) {
                    TimelineProbeOverlay(controller: bridge.controller,
                                         adapter: bridge.adapter,
                                         controllerReady: bridge.controllerAttached)
                    AnchorProbeLogOverlay()
                }
                .padding(.leading, 8)
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
    /// Whether the last published viewport was at the newest edge. The edge
    /// transition is the signal that the projection may stop history-anchoring.
    private var wasAtBottom = false

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void,
         renderMode: TimelineRenderMode = .code) {
        self.model = model
        let adapter = TimelineChatContentAdapter(model: model, onAttachment: onAttachment,
                                                 onFile: onFile, onSubAgent: onSubAgent,
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
        } else {
            // A local-first latest page may still be reconciling; a reader
            // moving into history must not have the window replaced.
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
        }
    }

    private func loadLatest(auto: Bool = false) {
        guard !navigationSuspended, model.session.isValid,
              model.session.hasNewerItems, !model.session.isLoadingHistory,
              !isLoadingLatest else { return }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteHistory(
            "bridge loadLatest auto=\(auto ? 1 : 0) off=\(controller?.collectionView.contentOffset.y ?? -1) "
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
            await self.model.session.loadLatest()
            self.adapter.historyLoadDirection = nil
            self.isLoadingLatest = false
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteHistory(
                "bridge loadLatest done auto=\(auto ? 1 : 0) "
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
