import SwiftUI
import Observation
import UIKit
#if DEBUG
import OSLog
#endif

/// The reader signals the backfill reads, taken from the existing scroll
/// state machine. Equatable so `.onChange` fires on either half.
private struct BackfillReaderSignals: Equatable {
    let scrolling: Bool
    let parkedInHistory: Bool
}

struct ChatTimelineView: View {
    let model: SessionChatModel
    /// The second argument is the thumbnail the bubble already decoded, when
    /// it has one; the image viewer opens on it before the original loads.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let onFile: (String) -> Void
    /// L2: opens the SubAgent panel from a card's 查看详情 entry.
    let onSubAgent: (String) -> Void
    @State private var historyLayout: TimelineHistoryLayout?
    @State private var historyPosition: TimelineHistoryPosition?
    @State private var hasRequestedOlder = false
    @State private var position = ScrollPosition()
    @State private var scrolling = TimelineScrollState()
    @State private var viewportSample = ChatViewportSample()
    @State private var viewportUpdates = ChatLayoutUpdate<TimelineViewport>()
    @State private var historyUpdates = ChatLayoutUpdate<TimelineHistoryLayout>()
    @State private var windowUpdates = ChatLayoutUpdate<TimelineWindowUnitMeasurement>()
    @State private var latestPull = TimelineHistoryPull()
    @State private var olderPull = TimelineHistoryPull(edge: .older)
    @State private var olderPromptVisible = false
    @State private var olderLoadRequest: Int?
    @State private var latestPromptVisible = false
    @State private var latestLoadRequest: Int?
    @State private var nativePhase = TimelineScrollState.Phase.idle
    /// The keyboard flag lives in a leaf-observed monitor (S2): the page body
    /// never reads it, so opening or closing the keyboard re-evaluates the
    /// return pill and the dismiss layer instead of the whole timeline chain.
    @State private var keyboard = TimelineKeyboardMonitor()
    /// Set while a keyboard-driven pin holds the bottom, so a transition end
    /// releases exactly what its own window pinned and nothing else.
    @State private var keyboardPinnedBottom = false
    /// The windowed timeline's render-set store (P2 对策A). The content reads
    /// its published move revision; the geometry callbacks feed it per frame.
    @State private var windowBox = TimelineWindowStore()
    /// Armed while a render-window expand/shrink settles: the same anchor
    /// math `historyPosition` runs for history pages, watching the render
    /// window's own boundary signal. One move at a time (the next is refused
    /// until this one settles).
    @State private var windowAnchor: TimelineHistoryPosition?
    @State private var windowGeneration = 0
    /// §7 feature flag: default on; `AA_TIMELINE_WINDOW=0` (debug/simulator)
    /// falls back to the pre-windowed full render for A/B comparison.
    private static let timelineWindowEnabled = ProcessInfo.processInfo.environment["AA_TIMELINE_WINDOW"] != "0"
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail
#if DEBUG
    private static let drawerLayoutLog = Logger(subsystem: "agents.anywhere", category: "drawer-layout")
#endif

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var viewport: TimelineViewport { viewportSample.value ?? scrolling.viewport }
    private var navigationIsSuspended: Bool { sidebarIsTransitioning || sidebarObscuresDetail }
    var body: some View {
        // A sibling overlay receives taps independently of the scroll view's
        // deceleration recognizer. The explicit return intent survives its callbacks.
        ZStack(alignment: .bottom) {
            ScrollView {
                ChatTimelineContent(model: model, onAttachment: onAttachment, onFile: onFile, onSubAgent: onSubAgent,
                    latestPullReady: latestPull.isReady, isLoadingLatest: latestLoadRequest != nil,
                    olderPullReady: olderPull.isReady, isLoadingOlder: olderLoadRequest != nil,
                    keepsOlderPrompt: hasRequestedOlder, historyAnchor: historyPosition?.origin,
                    queueRoster: model.session.sendQueue.renderRoster,
                    window: windowBox, windowEnabled: Self.timelineWindowEnabled,
                    // F2: a committed window move publishes only through this
                    // revision — the store object itself never changes — so the
                    // equatable seam has to carry it or the body is skipped.
                    windowMoveRevision: windowBox.moveRevision,
                    onLoadOlder: loadOlder, onLoadLatest: loadLatest,
                    onHistoryLayout: historyDidLayOut,
                    onUnitFrame: windowUnitDidMeasure,
                    onPromptVisibility: { latestPromptVisible = $0 },
                    onOlderPromptVisibility: { olderPromptVisible = $0 },
                    onTailVisibility: { region, visible in
                        scrolling.tailVisibilityChanged(region, visible: visible)
                        acknowledgeInstantOpeningIfArrived()
                    })
                    .equatable()
                    .opacity(model.openingPositionSettled ? 1 : 0)
                    .background { ChatPageScrollEdge() }
            }
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always, axes: .vertical)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // The opening positioning is owned by the instant command path: any
            // pre-armed target here would be applied by the scroll view when the
            // content arrives — outside our animation-disabled transaction — and
            // scroll visibly. The opacity gate below keeps the (top-anchored)
            // first layout invisible until the position lands.
            .defaultScrollAnchor(.top, for: .initialOffset)
            .defaultScrollAnchor(.top, for: .alignment)
            // Container-size changes are the keyboard (the phone drawer folds
            // the keyboard's height into the page's inset) and the composer
            // growing. Anchoring those to the bottom keeps the newest row at
            // the input bar and moves it in the same layout pass the system
            // animates, instead of leaving the follow to the 24 ms-coalesced
            // programmatic return. Only the container role is bottom: the
            // opening offsets stay top-anchored so the opening positioning
            // keeps owning its own first layout (see the note above). This is
            // the system's own follow; no keyboard-height arithmetic.
            .defaultScrollAnchor(.bottom, for: .sizeChanges)
            .allowsHitTesting(model.isOpeningReady)
            .accessibilityHidden(!model.isOpeningReady)
            .onScrollPhaseChange { _, phase, context in
                // A phase callback carries a newer authoritative sample.
                viewportUpdates.cancel()
                let mapped: TimelineScrollState.Phase
                switch phase {
                case .idle: mapped = .idle
                case .tracking: mapped = .tracking
                case .interacting: mapped = .interacting
                case .decelerating: mapped = .decelerating
                case .animating: mapped = .animating
                @unknown default: mapped = .idle
                }
                let current = TimelineViewport(geometry: context.geometry)
                let wasInteracting = scrolling.phase == .interacting
                viewportSample.value = current
                scrolling.geometryChanged(current)
                viewportSample.tailUpdatedAtPublish = scrolling.tail
                nativePhase = mapped
                // The drawer owns horizontal navigation. Do not interpret its
                // interrupted scroll callbacks as a fresh vertical reading intent.
                if navigationIsSuspended { return }
                if scrolling.phaseChanged(mapped, viewport: current) {
                    // Release ScrollPosition's persistent edge target as soon
                    // as the user takes over, including interrupted animations.
                    releaseScrollPosition()
                    historyPosition?.cancelRestoration()
                    windowAnchor?.cancelRestoration()
                    olderPull.begin(at: current, promptVisible: olderPromptVisible,
                        canLoad: model.session.hasOlderItems && !model.session.isLoadingHistory && olderLoadRequest == nil && latestLoadRequest == nil)
                    latestPull.begin(at: current, promptVisible: latestPromptVisible,
                        canLoad: model.session.hasNewerItems && !model.session.isLoadingHistory && latestLoadRequest == nil && olderLoadRequest == nil)
                }
                // F3: every sample the gesture (or its fling) delivered had its
                // window judgement refused — the anchor correction must not
                // write a point target under the reader's finger — and the
                // geometry that stopped moving does not deliver another one by
                // itself. Judge once the reader lets go.
                if mapped == .idle { timelineWindowDidSample(current) }
                if mapped == .interacting { latestPull.update(current); olderPull.update(current) }
                if mapped == .idle || mapped == .decelerating {
                    let shouldLoadLatest = latestPull.end(), shouldLoadOlder = olderPull.end()
                    if wasInteracting {
                        if shouldLoadOlder { loadOlder() }
                        else if shouldLoadLatest { loadLatest() }
                    }
                } else if mapped == .animating { latestPull.cancel(); olderPull.cancel() }
            }
            .onScrollGeometryChange(for: TimelineViewport.self) { geometry in
                TimelineViewport(geometry: geometry)
            } action: { previous, value in
#if DEBUG
                // A device recording cannot distinguish a changed native
                // offset from an upstream reflow. Record only vertical changes
                // during drawer navigation, without logging message contents.
                if ChatLayoutDiagnostics.isEnabled, navigationIsSuspended,
                   abs(value.contentHeight - previous.contentHeight) > 1
                    || abs(value.visibleHeight - previous.visibleHeight) > 1
                    || abs(value.offsetY - previous.offsetY) > 1 {
                    Self.drawerLayoutLog.debug("Drawer geometry: content \(previous.contentHeight, privacy: .public) -> \(value.contentHeight, privacy: .public), viewport \(previous.visibleHeight, privacy: .public) -> \(value.visibleHeight, privacy: .public), offset \(previous.offsetY, privacy: .public) -> \(value.offsetY, privacy: .public)")
                }
#endif
                viewportUpdates.submit(value) { value in
                    // Offset samples are needed for restoration, but do not change
                    // the rendered page. Publish only dimensions used by following,
                    // and not even those while the keyboard animation drives them.
                    viewportSample.value = value
                    pinBottomForKeyboard(value)
                    publishViewportSample(value, keyboardTransitionActive: keyboardDrivingLayout)
                    // A landed instant return is confirmed by geometry even when
                    // the tail callback arrived before this sample did.
                    acknowledgeInstantOpeningIfArrived()
                    // The render window is judged by every delivered sample:
                    // the decision is pure and bounded, and view state is
                    // written only when an expand/shrink move is actually due.
                    timelineWindowDidSample(value)
                    if !navigationIsSuspended && scrolling.phase == .interacting {
                        var latest = latestPull, older = olderPull
                        latest.update(value); older.update(value)
                        if latest != latestPull { latestPull = latest }
                        if older != olderPull { olderPull = older }
                    }
                }
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                viewportUpdates.cancel()
                scrolling.setNavigationSuspended(suspended)
                if suspended {
                    releaseScrollPosition()
                    latestPull.cancel(); olderPull.cancel()
                } else {
                    scrolling.phaseChanged(nativePhase, viewport: viewport)
                    if let historyLayout { historyDidLayOut(historyLayout) }
                }
            }
            .onChange(of: model.session.pendingMessages.last?.id) { _, id in
                if model.isOpeningReady, id != nil && !hasInteractions { scrolling.requestBottom() }
            }
            .onChange(of: model.session.sendQueue.items.map(\.id)) { _, ids in
                // A newly queued message must land in view when the reader is
                // already at the bottom; removals never yank them back.
                if model.isOpeningReady, !ids.isEmpty, !hasInteractions { scrolling.requestBottom() }
            }
            .onChange(of: model.responseRevision) { _, _ in
                if model.isOpeningReady { scrolling.requestBottom() }
            }
            .onChange(of: model.timeline.windowRevision) { _, _ in
                // A wholesale window change (the opening's trim/latest-page
                // surgery, or a recovery/snapshot replacement) can land after
                // the opening return settled or timed out. Every content-size
                // change is anchored to the top, so the replacement would
                // render from the new window's top and park the reader away
                // from the newest rows until a manual scroll (2026-10-08,
                // sess_ps8Z29uknMTIhw). Re-arm the opening's own instant
                // return for the landing instead of trusting the follow gates,
                // which can all be closed at that instant. The state refuses
                // on its own once the reader has taken over the page — except
                // a reader resting back at the bottom (following), where the
                // re-pin is motionless and spares them the animated lurch.
                _ = scrolling.reassertOpeningReturn()
            }
            .onChange(of: hasInteractions, initial: true) { _, presented in
                scrolling.setInteractionPresented(presented)
            }
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                if ready { scrolling.open(interactionPresented: hasInteractions) }
            }
            .task(id: model.openingPositionSettled) {
                // P2: the automatic full-history backfill starts strictly
                // post-paint — the opening return has landed (or its bounded
                // fallback expired), so the first frame is on screen and its
                // position is settled. Nothing here touches the opening path.
                //
                // Opening-flood governance (2026-10-10): the backfill's pages
                // then land back to back and used to repaint/re-assert per
                // page while the opening's own machinery was still settling.
                // A short quiet beat keeps the first fetch from racing the
                // landing layout; the presentation coalescer
                // (`TimelinePrependCoalescer`) folds the rest of the flood
                // into few landings.
                guard model.openingPositionSettled else { return }
                do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
                guard !Task.isCancelled else { return }
                model.session.beginHistoryBackfill()
                // The opening's own last geometry sample was delivered while
                // the window gate was still closed: judge it now, so a cold
                // open settles its render window without waiting for the
                // reader's first scroll.
                if let sample = viewportSample.value { timelineWindowDidSample(sample) }
            }
            .onChange(of: BackfillReaderSignals(
                scrolling: scrolling.userIsScrolling,
                parkedInHistory: scrolling.backfillReaderIsParked(atOlderPrompt: olderPromptVisible)
            ), initial: true) { _, signals in
                // P2 throttle, both halves taken from the existing scroll
                // state machine: a page the backfill has waiting is not
                // merged under an active scroll, and not under a reader
                // parked mid-history under their own control (B11 — a
                // prepend there has no anchor and would jump the page). The
                // loop resumes once both clear, or the reader reaches the
                // top's older-pull region.
                model.session.setBackfillReaderState(scrolling: signals.scrolling,
                    parkedInHistory: signals.parkedInHistory)
            }
            .onChange(of: scrolling.navigationGeneration) { _, _ in
                releaseScrollPosition()
            }
            .task(id: scrolling.pendingBottomRequest) {
                guard let request = scrolling.pendingBottomRequest, !navigationIsSuspended else { return }
                // Coalesce actual layout changes. Scrolling through the same
                // layout cannot restart this animation on every offset callback.
                // This delay is load-bearing for the opening return too: it
                // lets the timeline finish its first layout measurement, so the
                // instant target resolves against the real content height
                // instead of a half-measured one. The opening
                // gate hides these milliseconds anyway. A keyboard-matched
                // return (K5) begins in the notification's own turn and marks
                // its request, so it never reaches this delay.
                do { try await Task.sleep(for: .milliseconds(24)) } catch { return }
                guard !Task.isCancelled, !navigationIsSuspended, let command = scrolling.begin(request) else { return }
                scrollToBottom(command)
            }
            .task(id: model.isOpeningReady) {
                guard model.isOpeningReady else { return }
                // The cold-load mask waits for the first return. A no-op
                // native scroll, an interrupted command or a missed arrival
                // callback must not hold the mask or the return forever, so
                // settle it on a bounded fallback.
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard !Task.isCancelled else { return }
                if let command = scrolling.activeCommand, command.instant {
                    finishScrollToBottom(command)
                }
                model.openingPositionDidSettle()
            }
            .task(id: UserScrollSettlement(needed: scrolling.needsUserScrollSettlement,
                tail: scrolling.tail, generation: scrolling.navigationGeneration)) {
                guard scrolling.needsUserScrollSettlement else { return }
                // Reconcile visibility after the native phase callback. This
                // never holds opening behind a spinner or repeats a scroll.
                do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled else { return }
                scrolling.settleUserScroll()
            }
            .task(id: olderLoadRequest) {
                guard let request = olderLoadRequest else { return }
                await model.session.loadOlder()
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if !model.session.isValid { historyPosition = nil; olderLoadRequest = nil; return }
                historyPosition?.receivedPage(firstRowID: model.session.timeline.first { $0.value.isVisibleInChat }?.id)
            }
            .task(id: HistorySettlement(id: historyPosition?.id, ready: historyPosition?.isReadyToFinish == true,
                offset: historyPosition?.restoredOffset)) {
                guard let request = historyPosition?.id, historyPosition?.isReadyToFinish == true else { return }
                // Let the point correction reach native layout before releasing
                // its target or ending the spinner. A new measurement restarts this.
                do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled, historyPosition?.id == request else { return }
                if scrolling.navigationGeneration == request, historyPosition?.restoredOffset != nil {
                    position.isPositionedByUser = true
                }
                historyPosition = nil; olderLoadRequest = nil
            }
            .task(id: WindowMoveSettlement(id: windowAnchor?.id, ready: windowAnchor?.isReadyToFinish == true,
                offset: windowAnchor?.restoredOffset)) {
                guard let request = windowAnchor?.id, windowAnchor?.isReadyToFinish == true else { return }
                // Same settlement as a history pan: the correction's own
                // reports restart this, and 64 ms of quiet ends the move.
                do { try await Task.sleep(for: .milliseconds(64)) } catch { return }
                guard !Task.isCancelled, windowAnchor?.id == request else { return }
                // Release the point target a landed correction left behind —
                // unless a bottom return has since taken ownership of the
                // viewport (its own completion releases).
                if windowAnchor?.restoredOffset != nil, scrolling.activeCommand == nil {
                    releaseScrollPosition()
                }
                windowAnchor = nil
                // A move can need chaining (a fast scroll's overscan, or the
                // cold open trimming a deep default window) and no further
                // geometry sample is guaranteed once the layout settles —
                // judge the latest sample once more. The decision terminates
                // on its own: thresholds stop the chain, expansions are
                // bounded by the data's top, releases by the keep guard.
                if let sample = viewportSample.value { timelineWindowDidSample(sample) }
            }
            .task(id: latestLoadRequest) {
                guard let generation = latestLoadRequest else { return }
                await model.session.loadLatest()
                guard !Task.isCancelled else { return }
                // A drag during the fetch must not be undone when it finishes.
                if scrolling.navigationGeneration == generation { scrolling.requestBottom() }
                latestLoadRequest = nil
            }
            // The return pill would sit on top of the keyboard while typing,
            // so it hides while the keyboard is up. (The SubAgent capsule no
            // longer shares this stack — it is docked above the composer.)
            TimelinePillStack(keyboard: keyboard,
                isBottomShown: scrolling.showsBottomButton(),
                onBottom: {
                    latestPull.cancel(); olderPull.cancel()
                    historyPosition?.cancelRestoration()
                    scrolling.requestBottom()
                })
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // K3: with the keyboard up, a tap on empty message space closes it.
        // Text surfaces and controls keep their own taps; the recognizer is
        // passive and armed only while the keyboard is visible.
        .modifier(TimelineKeyboardDismissLayer(keyboard: keyboard))
        .traceChatLayout("timeline-viewport")
        .onDisappear { viewportUpdates.cancel(); historyUpdates.cancel(); windowUpdates.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
            keyboard.setVisible(true)
            keyboardTransitionBegan(TimelineKeyboardEvent(source: .willShow, userInfo: note.userInfo ?? [:]))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
            keyboard.setVisible(false)
            keyboardTransitionBegan(TimelineKeyboardEvent(source: .willHide, userInfo: note.userInfo ?? [:]))
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
            keyboardFrameWillChange(TimelineKeyboardEvent(source: .willChangeFrame, userInfo: note.userInfo ?? [:]))
        }
    }
    private func loadOlder() {
        guard model.session.isValid, model.session.hasOlderItems,
              !model.session.isLoadingHistory, olderLoadRequest == nil, latestLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        scrolling.browseHistory(byReader: true)
        position.isPositionedByUser = true
        let layout = historyLayout.flatMap { $0.firstRowID == model.timeline.rows.first?.id ? $0 : nil }
        historyPosition = TimelineHistoryPosition(id: scrolling.navigationGeneration, layout: layout,
            offsetY: viewport.offsetY, topInset: viewport.topInset)
        hasRequestedOlder = true
        olderLoadRequest = scrolling.navigationGeneration
    }
    private func loadLatest() {
        guard model.session.isValid, model.session.hasNewerItems,
              !model.session.isLoadingHistory, latestLoadRequest == nil, olderLoadRequest == nil else { return }
        olderPull.cancel(); latestPull.cancel()
        historyPosition?.cancelRestoration()
        scrolling.requestBottom()
        latestLoadRequest = scrolling.navigationGeneration
    }
    private func scrollToBottom(_ command: TimelineScrollState.BottomCommand) {
        if command.instant {
            // The opening return lands without an animation (D4) so a cached
            // window never plays a visible top-to-bottom scroll. A
            // disablesAnimations transaction carries no completion, so the
            // return settles when the end marker reports arrival (or on the
            // bounded fallback) instead of releasing the edge target before
            // the scroll can apply.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(edge: .bottom) }
            acknowledgeInstantOpeningIfArrived()
            return
        }
        let animation = Self.returnSpring
        withAnimation(reduceMotion ? nil : animation,
            completionCriteria: .removed) {
            // Let the scroll view resolve its own safe-area/inset coordinate
            // system. The edge target is released when this animation finishes
            // or as soon as a gesture/drawer/approval cancels the command.
            position.scrollTo(edge: .bottom)
        } completion: {
            finishScrollToBottom(command)
        }
    }
    private static let returnSpring = Animation.interactiveSpring(response: 0.28, dampingFraction: 1, blendDuration: 0.12)
    /// The opening return settles once the native end marker reports arrival
    /// (immediately for content that already fits). Releasing before the
    /// pending edge target applied would clear it instead of landing, so the
    /// acknowledgement also requires the current viewport to reach the end of
    /// the current content: a tail sample left over from an earlier, shorter
    /// layout must not release the target of a return that has not landed yet
    /// (B3.5). At rest at the true bottom `visibleBottom` equals
    /// `contentHeight`; the small tolerance covers the half-visible 2pt end
    /// marker and native rounding.
    private func acknowledgeInstantOpeningIfArrived() {
        guard let command = scrolling.activeCommand, command.instant, scrolling.tail.isAtBottom,
              viewport.visibleBottom >= viewport.contentHeight - 2 else { return }
        finishScrollToBottom(command)
    }
    private func finishScrollToBottom(_ command: TimelineScrollState.BottomCommand) {
        guard scrolling.complete(command) else { return }
        releaseScrollPosition()
        // Unblocks the cold-load mask: the window is at the bottom now (D4).
        model.openingPositionDidSettle()
    }
    private func releaseScrollPosition() {
        guard position.edge != nil || position.point != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.isPositionedByUser = true }
    }
    /// The keyboard owns the layout while its transition window is open, and
    /// while the keyboard is visible an active drag (the K4 interactive
    /// dismissal) changes the container between its frame notifications too.
    private var keyboardDrivingLayout: Bool {
        keyboard.transitionActive || (keyboard.isVisible && scrolling.userIsScrolling)
    }
    /// Keeps the newest row on the input bar for as long as the keyboard is
    /// moving. Inside the transition window the page mutes its own follow
    /// paths, so the bottom rests on the scroll view's default anchor alone —
    /// a default, not a guarantee, and one a manual scroll detaches. The pin is
    /// a no-animation edge target, so it rides the keyboard's own animation
    /// frame by frame instead of racing it, and it is re-derived from the
    /// freshest sample every frame, so a release landing in between (a
    /// navigation generation bump, a streaming revision) heals on the next one.
    private func pinBottomForKeyboard(_ sample: TimelineViewport) {
        guard keyboard.transitionActive, keyboard.isVisible else { return }
        guard TimelineKeyboardBottomPin.shouldPin(isFollowing: scrolling.mode == .following,
            isScrolling: scrolling.userIsScrolling, navigationSuspended: navigationIsSuspended,
            isMeasured: sample.isMeasured, atBottom: sample.measuredAtBottom) else { return }
        // Assign once per window: a per-frame write would re-evaluate the page
        // body on every sample, the storm S2 exists to remove.
        if !keyboardPinnedBottom { keyboardPinnedBottom = true }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { position.scrollTo(edge: .bottom) }
    }
    /// Writes a sample into view state only when it changes a decision (S2).
    /// Sampling stays per-frame in the non-invalidating box; publishing
    /// re-evaluates the page body, so a keyboard transition that only
    /// stretches the visible height must not do it per frame.
    private func publishViewportSample(_ value: TimelineViewport, keyboardTransitionActive: Bool) {
        let tailChanged = viewportSample.tailUpdatedAtPublish != scrolling.tail
        let outcome = TimelineViewportPublicationDecision.outcome(published: scrolling.viewport, next: value,
            keyboardTransitionActive: keyboardTransitionActive, tailChanged: tailChanged)
        // R2 backstop, judged *outside* the publication gate by the freshest
        // sample: a filtered sample can still carry newer physical truth
        // than the published viewport. The burst coalescer delivers only the
        // confirm replace's last frame, so the intermediate frame's native
        // clamp never publishes — the stale "at bottom" viewport would
        // refuse the request gate and the backstop at once and park the
        // page until the next content change. The same delivery also ends
        // the displacement episode when it shows the page measurably at the
        // bottom: the latch's re-arm must not depend on the publication
        // gate or the phase echo either — a filtered arrival frame is often
        // the only report that ever arrives. Both judgements are pure (S2):
        // the common filtered tick — an offset-only scroll frame — writes
        // nothing, and each mutating outcome is itself bounded (the ask by
        // its latch, the re-arm to once per spent episode). While the
        // keyboard transition window is open both stay quiet: its end
        // re-evaluates the settled sample with the window closed (rule ⑤).
        if outcome != .publish, !keyboardTransitionActive {
            if scrolling.needsBottomReconcile(using: value) {
                scrolling.reconcileToBottom(using: value)
            } else if scrolling.needsBottomReconcileRearm(using: value) {
                scrolling.rearmBottomReconcile(using: value)
            }
        }
        guard outcome == .publish else { return }
        scrolling.geometryChanged(value)
        viewportSample.tailUpdatedAtPublish = scrolling.tail
        // R2 backstop: even with the geometry gates, a published sample can
        // still find the page measurably short with nothing on the way (a
        // lost probe flip, or a confirm replace that round-trips back to the
        // claimed request). The state asks at most once per episode; an
        // in-flight command, a reader gesture or an armed request keep it
        // quiet, and the 24 ms coalescing task keeps its own claim. The
        // judgement reads the freshest sample — the one just published.
        scrolling.reconcileToBottom(using: value)
    }
    /// Every frame change restarts the transition window; the window's close
    /// settles the withheld sample. The end is scheduled for every event,
    /// even a zero-duration one: the immediate close is what releases
    /// whatever an earlier window withheld (S2 publication gating).
    private func keyboardTransitionBegan(_ event: TimelineKeyboardEvent) {
        keyboard.noteLayoutEvent(event)
        let token = keyboard.beginTransition()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(event.duration, 0)))
            keyboardTransitionDidEnd(token: token)
        }
    }
    /// A frame change of any kind restarts the transition window — a
    /// keyboard's own height change (the predictive row) is the same kind of
    /// transition. No follow is attached: the page does not move with the
    /// keyboard (reverted 2026-10-02 at pp's direction).
    private func keyboardFrameWillChange(_ event: TimelineKeyboardEvent) {
        keyboardTransitionBegan(event)
    }
    private func keyboardTransitionDidEnd(token: Int) {
        guard keyboard.finishTransition(token: token) else { return }
        // Release this window's own pin before the settled sample is judged,
        // so the regular machinery decides on a page that no target of ours is
        // holding. A return already in flight keeps its own target — it owns
        // the release, and its completion releases it.
        if keyboardPinnedBottom {
            keyboardPinnedBottom = false
            if scrolling.activeCommand == nil { releaseScrollPosition() }
        }
        // Rule ⑤: evaluate the latest sample with the window closed, so a
        // visible height withheld during the transition lands now and the
        // `lastRequest` dedup cannot stay pinned to a pre-keyboard value.
        if let sample = viewportSample.value {
            publishViewportSample(sample, keyboardTransitionActive: false)
        }
        acknowledgeInstantOpeningIfArrived()
    }
    private func historyDidLayOut(_ layout: TimelineHistoryLayout) {
        historyUpdates.submit(layout) { layout in
            if historyLayout != layout { historyLayout = layout }
            guard !navigationIsSuspended, var restoration = historyPosition else { return }
            let offset = restoration.laidOut(layout, generation: scrolling.navigationGeneration)
            if historyPosition != restoration { historyPosition = restoration }
            guard let offset else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: offset) }
        }
    }
    private struct HistorySettlement: Equatable {
        let id: Int?
        let ready: Bool
        let offset: CGFloat?
    }
    private struct WindowMoveSettlement: Equatable {
        let id: Int?
        let ready: Bool
        let offset: CGFloat?
    }
    private struct UserScrollSettlement: Equatable {
        let needed: Bool
        let tail: TimelineTailVisibility
        let generation: Int
    }

    // MARK: - Windowed timeline (P2 对策A)

    /// One geometry sample's judgement of the render window. The guard list is
    /// deliberately conservative (see `TimelineWindowMoveGate`): no move while
    /// the navigation is suspended, while a history load or an in-flight
    /// bottom command owns the viewport, while a previous window move is still
    /// settling, while the keyboard drives the layout — or while the reader's
    /// own gesture owns the offset (F3): the anchor correction a commit arms
    /// writes a point target, which would fight a live drag or fling. A refused
    /// move is retried by later samples, and once when the gesture settles.
    private func timelineWindowDidSample(_ sample: TimelineViewport) {
        guard TimelineWindowMoveGate(
            windowingEnabled: Self.timelineWindowEnabled,
            openingSettled: model.openingPositionSettled,
            navigationSuspended: navigationIsSuspended,
            moveSettling: windowAnchor != nil,
            historySettling: historyPosition != nil,
            historyLoadInFlight: olderLoadRequest != nil || latestLoadRequest != nil,
            bottomCommandInFlight: scrolling.activeCommand != nil,
            keyboardDrivingLayout: keyboardDrivingLayout,
            userIsScrolling: scrolling.userIsScrolling
        ).allows else { return }
        guard let plan = windowBox.planMove(viewport: sample) else { return }
        applyWindowMove(plan)
    }

    /// Commits one expand/shrink: arms the anchor against the post-move first
    /// unit (the unit that stays rendered across the move), then applies the
    /// slice change. The spacer gives back exactly the estimates it charged,
    /// so the reader's displacement is only the estimate error — which the
    /// anchor's own measured reports correct, no animation, the same math a
    /// history page prepend runs through `historyPosition`.
    private func applyWindowMove(_ plan: TimelineWindowStore.PlannedWindowMove) {
        guard let dataFirst = model.timeline.rows.first?.id else { return }
        windowGeneration &+= 1
        var anchor = TimelineHistoryPosition(id: windowGeneration, layout: TimelineHistoryLayout(
            firstRowID: dataFirst, renderFirstRowID: plan.renderFirstUnitID,
            anchorRowID: plan.anchorUnitID, edge: .top, y: plan.anchorY),
            offsetY: plan.sample.viewport.offsetY, topInset: plan.sample.viewport.topInset,
            signal: .renderWindow)
        // The window anchor's completion does not depend on the data window's
        // first row: a history page landing mid-settle must not hold it open
        // (the layout reports carry whatever the data first row is by then).
        anchor.receivedPage(firstRowID: nil)
        windowAnchor = anchor
        windowBox.commit(plan)
    }

    /// Every rendered unit's frame lands here. The store keeps the measured
    /// truth (the spacer's refinement source and the shrink arithmetic); a
    /// frame of the armed anchor additionally drives the point correction —
    /// deferred out of the geometry callback through the same main-queue box
    /// the history layout uses, so no scroll target is written mid-layout.
    private func windowUnitDidMeasure(_ measurement: TimelineWindowUnitMeasurement) {
        windowBox.recordUnitFrame(measurement)
        guard windowAnchor?.origin?.anchorRowID == measurement.id else { return }
        windowUpdates.submit(measurement) { measurement in
            guard var anchor = windowAnchor, anchor.origin?.anchorRowID == measurement.id,
                  let dataFirst = model.timeline.rows.first?.id else { return }
            let layout = TimelineHistoryLayout(firstRowID: dataFirst,
                renderFirstRowID: windowBox.resolvedFirstUnitID ?? "",
                anchorRowID: measurement.id, edge: .top, y: measurement.y)
            let offset = anchor.laidOut(layout, generation: windowGeneration)
            if windowAnchor != anchor { windowAnchor = anchor }
            guard let offset else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { position.scrollTo(y: offset) }
        }
    }
}

/// Keep the latest measurement without publishing View state inside a layout
/// callback. One main-queue delivery handles a burst; removal invalidates it.
@MainActor private final class ChatLayoutUpdate<Value> {
    private var pending: (() -> Void)?
    private var scheduled = false
    private var generation = 0

    func submit(_ value: Value, apply: @escaping (Value) -> Void) {
        pending = { apply(value) }
        guard !scheduled else { return }
        scheduled = true
        let token = generation
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token else { return }
            let update = self.pending
            self.pending = nil
            self.scheduled = false
            update?()
        }
    }

    func cancel() {
        generation &+= 1
        pending = nil
        scheduled = false
    }
}

private struct ChatTimelineContent: View, Equatable {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    let onFile: (String) -> Void
    let onSubAgent: (String) -> Void
    let latestPullReady: Bool
    let isLoadingLatest: Bool
    let olderPullReady: Bool
    let isLoadingOlder: Bool
    let keepsOlderPrompt: Bool
    let historyAnchor: TimelineHistoryLayout?
    /// The queue's ids and states, captured by the parent so the equatable
    /// seam (and the queue section's animation) notice roster and state
    /// changes; the rows themselves read the live model.
    let queueRoster: String
    /// The windowed timeline's store (P2 对策A). The body resolves the
    /// rendered slice through it; its caches rebuild off row membership, so
    /// token streams never re-estimate.
    let window: TimelineWindowStore
    /// The §7 feature flag, hoisted so the content's equality sees it.
    let windowEnabled: Bool
    /// The store's committed-move revision, read by the parent (F2): the store
    /// is the same object across a commit, so this is the only value that can
    /// carry the move through `.equatable()`.
    let windowMoveRevision: Int
    let onLoadOlder: () -> Void
    let onLoadLatest: () -> Void
    let onHistoryLayout: (TimelineHistoryLayout) -> Void
    let onUnitFrame: (TimelineWindowUnitMeasurement) -> Void
    let onPromptVisibility: (Bool) -> Void
    let onOlderPromptVisibility: (Bool) -> Void
    let onTailVisibility: (TimelineTailVisibility.Region, Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The content column's measured width — the height model's key input.
    @State private var contentWidth: CGFloat = 0
    /// F1 (pp 2026-10-07): the tail spacer's resting height — the two-tier
    /// contract is 32 with a status line present and this value at rest, so
    /// the SubAgent capsule seats near the content when the session is idle.
    private static let idleTailHeight: CGFloat = 12
    /// The two-tier height's only input: the status line's presence. The body
    /// reads this one boolean for both the frame and the animation value.
    private var hasStatusLine: Bool { model.sendingPlaceholder != nil }

    /// The value half of the seam, so it can be pinned by unit tests: see
    /// `ChatTimelineContentInputs`. Two contents over the same model and the
    /// same store are equal only while every compared input — including the
    /// store's committed-move revision — still matches.
    var equatableInputs: ChatTimelineContentInputs {
        ChatTimelineContentInputs(latestPullReady: latestPullReady, isLoadingLatest: isLoadingLatest,
            olderPullReady: olderPullReady, isLoadingOlder: isLoadingOlder,
            keepsOlderPrompt: keepsOlderPrompt, historyAnchor: historyAnchor,
            queueRoster: queueRoster, windowEnabled: windowEnabled,
            windowMoveRevision: windowMoveRevision)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.window === rhs.window
            && lhs.equatableInputs == rhs.equatableInputs
    }

    /// The window's height-model inputs, read from the environment: the
    /// Dynamic Type bucket is the stable cache dimension, the scale is only
    /// the estimator's coarse multiplier.
    private var typeScaleBucket: Int { DynamicTypeSize.allCases.firstIndex(of: dynamicTypeSize) ?? 3 }
    private var typeScale: CGFloat {
        // ≈ UIKit's body-text ratios per category (large = 1.0).
        let scales: [CGFloat] = [0.82, 0.88, 0.94, 1.0, 1.12, 1.23, 1.35, 1.64, 1.95, 2.35, 2.76, 3.12]
        return scales.indices.contains(typeScaleBucket) ? scales[typeScaleBucket] : 1.0
    }

    var body: some View {
        let targets = Set(model.session.notices.notices.filter(\.isVisible).compactMap(\.timelineTargetID))
        // The windowed render set: everything below the boundary is rendered —
        // the tail sentinels, status line and queue must stay inside the
        // rendered region — and everything older is one spacer on top.
        let frame = windowEnabled
            ? window.frame(rows: model.timeline.rows, revision: model.timeline.membershipRevision,
                interactionTargets: targets, width: contentWidth,
                typeScaleKey: typeScaleBucket, typeScale: typeScale, disclosures: model.disclosures)
            : TimelineWindowFrame(startRowIndex: 0, firstUnitID: model.timeline.rows.first?.id,
                spacerHeight: 0, hiddenRowCount: 0, renderedRowCount: model.timeline.rows.count)
        let start = min(max(0, frame.startRowIndex), model.timeline.rows.count)
        let groups = TimelineGrouping.groups(Array(model.timeline.rows[start...]), interactionTargets: targets)
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: model.isRunning || model.session.hasNewerItems,
            hasPendingUserMessage: !model.session.hasNewerItems && (!model.timeline.pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty))
        // Prefer a message whose start cannot move into a prefixed tool group.
        // For an all-tools page, retain the existing group's trailing edge.
        let anchorGroup = historyAnchor.flatMap { anchor in groups.first { $0.rows.contains { $0.id == anchor.anchorRowID } } }
            ?? groups.first { $0.rows.first?.structure.groupKind == .single } ?? groups.last
        let anchorEdge = historyAnchor?.edge ?? (anchorGroup?.rows.first?.structure.groupKind == .single ? .top : .bottom)
        // Keep actual row geometry available as Markdown grows and tool groups
        // change height. Hidden tool details own their deferred work separately.
        VStack(alignment: .leading, spacing: TimelineRenderWindow.unitSpacing) {
            if model.session.hasOlderItems || keepsOlderPrompt {
                Group {
                    if isLoadingOlder {
                        HStack(spacing: 8) {
                            ProgressView().progressViewStyle(.circular).controlSize(.small)
                            Text(String(localized: "正在加载较早的消息…"))
                        }.accessibilityElement(children: .combine)
                    } else if model.session.hasOlderItems {
                        Button(action: onLoadOlder) {
                            Text(olderPullReady ? String(localized: "松开加载较早的消息") : String(localized: "加载较早的消息"))
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                        }.disabled(model.session.isLoadingHistory || isLoadingLatest)
                    } else {
                        // Retain the prompt's footprint on the final page; removing
                        // it after restoring would move the reader by another row.
                        Text(String(localized: "已到达会话开头")).foregroundStyle(.secondary)
                    }
                }
                .font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                .onScrollVisibilityChange(threshold: 0.9) { onOlderPromptVisibility($0) }
            }
            // The window's single top placeholder: one blank child standing in
            // for every unrendered older unit. Its height reproduces the
            // rendered list's own spacing arithmetic exactly (see
            // TimelineRenderWindow.spacerHeight), so materializing a boundary
            // block moves only the estimate error — which the window anchor
            // corrects without animation.
            if frame.spacerHeight > 0 {
                Color.clear
                    .frame(height: frame.spacerHeight)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            ForEach(groups) { group in
                SessionTimelineGroupView(group: group, chat: model, onAttachment: onAttachment, onFile: onFile,
                    turnAction: actions[group.id], onSubAgent: onSubAgent)
                    .id(group.id)
                    .background {
                        // Every rendered unit reports its frame: measured truth
                        // for the spacer model and the shrink arithmetic, and —
                        // while a window move settles — the anchor's own
                        // correction reports.
                        Color.clear.onGeometryChange(for: TimelineWindowUnitMeasurement.self) { geometry in
                            let unitFrame = geometry.frame(in: .named("chat.timeline.content"))
                            return TimelineWindowUnitMeasurement(id: group.id, y: unitFrame.minY, height: unitFrame.height)
                        } action: { onUnitFrame($0) }
                    }
                    .background {
                        if group.id == anchorGroup?.id, let firstRowID = model.timeline.rows.first?.id {
                            Color.clear.onGeometryChange(for: TimelineHistoryLayout.self) { geometry in
                                let geometryFrame = geometry.frame(in: .named("chat.timeline.content"))
                                return TimelineHistoryLayout(firstRowID: firstRowID,
                                    renderFirstRowID: frame.firstUnitID ?? "",
                                    anchorRowID: historyAnchor?.anchorRowID ?? group.id, edge: anchorEdge,
                                    y: anchorEdge == .top ? geometryFrame.minY : geometryFrame.maxY)
                            } action: { onHistoryLayout($0) }
                        }
                    }
            }
            ForEach(model.session.notices.notices.filter { notice in
                notice.isVisible && !notice.blocks(model.session.id)
                    && !model.timeline.rows.contains(where: { $0.id == notice.timelineTargetID })
            }) { item in SessionInteractionCard(item: item, chat: model) }
            ForEach(model.timeline.pendingMessages) { pending in
                PendingMessageRow(pending: pending, chat: model, onAttachment: onAttachment,
                    onDismiss: { model.session.dismissPendingMessage(id: pending.id) })
                    .id(pending.id)
            }
            if model.session.hasNewerItems {
                Button(action: onLoadLatest) {
                    Group {
                        if isLoadingLatest { ProgressView(String(localized: "正在加载更新的记录…")) }
                        else { Text(latestPullReady ? String(localized: "松开加载更新的记录") : String(localized: "继续上拉加载更新的记录")) }
                    }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
                }
                .disabled(model.session.isLoadingHistory || isLoadingLatest || isLoadingOlder)
                .onScrollVisibilityChange { onPromptVisibility($0) }
            }
            // Dual-tier breathing room (pp 2026-10-07): the spacer is 32 with
            // a status line present and `idleTailHeight` at rest. The old
            // single-constant convention is upgraded, not abolished: the tier
            // follows only that one boolean, so status text and card counts
            // still cannot change this spacer or create a spurious follow
            // request. Only the top edge condenses — the content's bottom edge
            // and both bottom-anchored probes stay put.
            //
            // The queue's waiting messages ride above the status line, still
            // inside the list (pp 2026-10-08: the queue belongs to the
            // timeline, not to a dock pinned over the composer; pp 2026-10-09:
            // it seats above the status line so the status line keeps the
            // block's own bottom edge). Both probes stay anchored to the
            // block's own bottom edge, which remains the content's true end.
            VStack(alignment: .leading, spacing: 8) {
                if !model.session.sendQueue.items.isEmpty {
                    VStack(spacing: 6) {
                        ForEach(model.session.sendQueue.items) { item in
                            QueuedMessageRow(item: item, model: model)
                                .id(item.id)
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: queueRoster)
                }

                Group {
                    if let text = model.sendingPlaceholder {
                        HStack(spacing: 8) {
                            ThinkingOrbView(activity: model.orbActivity, size: 30, pulse: model.session.incomingPulse)
                            OrbStatusText(text: text).font(.footnote).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    } else { Color.clear }
                }.frame(height: hasStatusLine ? 32 : Self.idleTailHeight)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: hasStatusLine)
                    .traceChatLayout("tail-spacer")
            }
            .traceChatLayout("tail-block")
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: 96)
                    .onScrollVisibilityChange(threshold: 0.01) { onTailVisibility(.near, $0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .overlay(alignment: .bottom) {
                Color.clear.frame(height: 2)
                    .onScrollVisibilityChange(threshold: 0.5) { onTailVisibility(.end, $0) }
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            .id("tail")
        }
        // The column width is the height model's cache dimension: a rotation
        // or column change re-estimates through the store's signature.
        // Measured before the column modifier so it reflects the text width,
        // not the padded container.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            if abs(width - contentWidth) > 1 { contentWidth = width }
        }
        .modifier(ChatPageContentColumn(horizontalInset: nil))
        .coordinateSpace(name: "chat.timeline.content")
        .traceChatLayout("timeline-content", state: "groups=\(groups.count), footers=\(actions.count), running=\(model.isRunning)")
    }

}

private extension TimelineViewport {
    init(geometry: ScrollGeometry) {
        self.init(contentHeight: geometry.contentSize.height, containerHeight: geometry.containerSize.height,
            topInset: geometry.contentInsets.top, bottomInset: geometry.contentInsets.bottom, offsetY: geometry.contentOffset.y)
    }
}

/// Native offset storage deliberately does not invalidate the SwiftUI view tree.
@MainActor private final class ChatViewportSample {
    var value: TimelineViewport?
    /// The tail visibility that accompanied the last published sample. A flip
    /// since then must not be dismissed by the keyboard-transition rule (④):
    /// the bottom truth moved and the sample has to publish with it.
    var tailUpdatedAtPublish: TimelineTailVisibility?
}

/// K5/S2 leaf: the return pill floats at the timeline's bottom edge. Only this
/// leaf observes the keyboard monitor — the page body never reads it. The
/// keyboard owns the layout while its transition window is open: the stack
/// animates its own slot change with the keyboard's event duration and curve,
/// so the pill collapses and re-expands with the keyboard instead of popping.
/// (The SubAgent capsule, its old stack-mate, now rides the composer dock.)
private struct TimelinePillStack: View {
    let keyboard: TimelineKeyboardMonitor
    let isBottomShown: Bool
    let onBottom: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            TimelineBottomPill(keyboard: keyboard, isShown: isBottomShown, onTap: onBottom)
        }
        .animation(keyboard.layoutAnimation, value: keyboard.isVisible)
    }
}

/// K5/S2 leaf: only this view observes the keyboard monitor, so a keyboard
/// toggle re-evaluates the return pill (and the dismiss layer below) instead
/// of the whole timeline body.
private struct TimelineBottomPill: View {
    let keyboard: TimelineKeyboardMonitor
    let isShown: Bool
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .caption) private var height: CGFloat = 32

    var body: some View {
        if isShown && !keyboard.isVisible {
            Button(action: onTap) {
                Label(String(localized: "到底部"), appSymbol: "arrow.down").font(.caption.weight(.medium)).foregroundStyle(.primary)
                    .padding(.horizontal, 12).frame(height: height)
                    .glassEffect(.regular.interactive(), in: .capsule)
                    .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("chat.timeline.bottom")
            .padding(.bottom, 2)
        }
    }
}

/// K3/S2 leaf: the tap-to-dismiss gesture reads the keyboard monitor here so
/// arming and disarming it never re-evaluates the timeline body.
private struct TimelineKeyboardDismissLayer: ViewModifier {
    let keyboard: TimelineKeyboardMonitor

    func body(content: Content) -> some View {
        content.keyboardDismissTapGesture(isEnabled: keyboard.isVisible)
    }
}

/// Timeline keyboard state in a leaf-observed object. The page body never
/// reads it (S2): opening or closing the keyboard cannot re-evaluate the
/// timeline modifier chain. `transitionActive` marks the window in which
/// per-frame visible-height samples and programmatic returns are withheld
/// while the keyboard animates (K5).
@MainActor @Observable private final class TimelineKeyboardMonitor {
    private(set) var isVisible = false
    private(set) var transitionActive = false
    /// The newest keyboard event's own duration and curve, as a SwiftUI
    /// animation (L2 pill stack §3.2). Nil without a transition (or a
    /// zero-duration one), which applies the change without animation.
    private(set) var layoutAnimation: Animation?
    private var transitionToken = 0

    func setVisible(_ visible: Bool) {
        isVisible = visible
    }

    /// Records the system clock the pill stack's slot change animates on: the
    /// return pill collapses and re-expands on the keyboard's own duration and
    /// curve instead of popping while the keyboard transitions.
    func noteLayoutEvent(_ event: TimelineKeyboardEvent) {
        guard !event.isFinal else { layoutAnimation = nil; return }
        switch event.curve {
        case .easeIn: layoutAnimation = .easeIn(duration: event.duration)
        case .easeOut: layoutAnimation = .easeOut(duration: event.duration)
        case .linear: layoutAnimation = .linear(duration: event.duration)
        case .easeInOut, .privateSpring, .unknown: layoutAnimation = .easeInOut(duration: event.duration)
        }
    }

    /// Opens (or restarts) the window and returns the token its end schedule
    /// must present. Superseded tokens are rejected by `finishTransition`.
    @discardableResult
    func beginTransition() -> Int {
        transitionToken &+= 1
        transitionActive = true
        return transitionToken
    }

    /// True only for the newest transition: an end schedule superseded by a
    /// later frame change must not close the newer window or settle early.
    func finishTransition(token: Int) -> Bool {
        guard token == transitionToken, transitionActive else { return false }
        transitionActive = false
        return true
    }
}

/// The queue's render signature: ids with their states. Captured by the
/// timeline content's parent so equality and the queue section's animation
/// both notice a roster or state change; rows read the live model directly.
private extension V2SendQueue {
    var renderRoster: String {
        items.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }
}

/// The windowed timeline's view-side store (P2 对策A). Wraps the pure
/// `TimelineRenderWindow` with the caches the content body and the geometry
/// callbacks share.
///
/// Publishing discipline (S2): `moveRevision` is the only observed property —
/// the content body reads it through `frame(...)`, so only committed moves
/// re-render the slice. Every other write (caches, measurements) is
/// `@ObservationIgnored`, so per-frame callbacks never re-evaluate the page.
@MainActor @Observable private final class TimelineWindowStore {
    struct PlannedWindowMove {
        let move: TimelineRenderWindow.Move
        let sample: TimelineWindowSample
        /// The unit that stays rendered across the move: the current first
        /// unit for an expansion, the post-move first unit for a shrink.
        let anchorUnitID: String
        /// Its pre-move content y — the correction's origin.
        let anchorY: CGFloat
        /// The pre-move render-window first unit (the signal origin).
        let renderFirstUnitID: String
    }

    private(set) var moveRevision = 0
    /// The render window's first unit right now (nil before the first bind).
    var resolvedFirstUnitID: String? { lastFrame.firstUnitID }

    @ObservationIgnored private var window = TimelineRenderWindow()
    @ObservationIgnored private var heights = TimelineUnitHeightCache()
    /// The frames of the currently rendered units (y is meaningful only while
    /// the unit is rendered — pruned at every move).
    @ObservationIgnored private var measurements: [String: TimelineWindowUnitMeasurement] = [:]
    /// The rendered units' current heights, the bake source for a move.
    @ObservationIgnored private var measuredHeights: [String: CGFloat] = [:]
    @ObservationIgnored private var facts: [String: TimelineUnitHeightFacts] = [:]
    @ObservationIgnored private var lastFrame = TimelineWindowFrame(
        startRowIndex: 0, firstUnitID: nil, spacerHeight: 0, hiddenRowCount: 0, renderedRowCount: 0)
    @ObservationIgnored private var signature: Signature?
    @ObservationIgnored private var lastWidthKey = 0
    @ObservationIgnored private var lastTypeScaleKey = 0

    private struct Signature: Equatable {
        let revision: Int
        let targets: String
        let width: Int
        let typeScale: Int
    }

    /// Resolves the rendered slice for the content body. Rebuilds the unit
    /// list only when the data membership, the interaction targets or the
    /// geometry keys change — never per token flush.
    func frame(rows: [ChatTimelineRowModel], revision: Int, interactionTargets: Set<String>,
               width: CGFloat, typeScaleKey: Int, typeScale: CGFloat,
               disclosures: TimelineDisclosureState) -> TimelineWindowFrame {
        _ = moveRevision // Observation hook: a committed move re-renders the slice.
        let widthKey = Int(width.rounded())
        let next = Signature(revision: revision, targets: interactionTargets.sorted().joined(separator: ","),
            width: widthKey, typeScale: typeScaleKey)
        if next != signature {
            rebuild(rows: rows, interactionTargets: interactionTargets, width: width,
                widthKey: widthKey, typeScaleKey: typeScaleKey, typeScale: typeScale, disclosures: disclosures)
            signature = next
        }
        return lastFrame
    }

    /// Records one rendered unit's frame: the measured-truth cache for the
    /// height model, the current-height bake source for moves, and the y the
    /// anchor correction reads while a move settles.
    func recordUnitFrame(_ measurement: TimelineWindowUnitMeasurement) {
        measurements[measurement.id] = measurement
        measuredHeights[measurement.id] = measurement.height
        guard let unitFacts = facts[measurement.id] else { return }
        heights.record(measurement.height, for: TimelineUnitHeightKey(id: measurement.id,
            width: lastWidthKey, typeScale: lastTypeScaleKey,
            isCollapsed: unitFacts.isCollapsed, isStreaming: unitFacts.isStreaming))
    }

    /// Judges the window and prepares everything a move's anchor needs, from
    /// the pre-move state. Pure with respect to view state (cache writes
    /// only): the caller commits or drops the plan.
    func planMove(viewport: TimelineViewport) -> PlannedWindowMove? {
        guard let first = lastFrame.firstUnitID, let top = measurements[first] else { return nil }
        // The shrink arithmetic must give the spacer the heights the rendered
        // rows actually occupied, not the estimates they replaced — with
        // measured truth a shrink's displacement is zero by construction.
        window.applyMeasuredHeights(measuredHeights)
        let sample = TimelineWindowSample(viewport: viewport, windowTop: top.y)
        switch window.move(sample: sample) {
        case .none:
            return nil
        case .expand:
            // The new block materializes above the current first unit: that
            // unit survives the move and is the correction's anchor.
            return PlannedWindowMove(move: .expand, sample: sample,
                anchorUnitID: first, anchorY: top.y, renderFirstUnitID: first)
        case .shrink:
            let count = window.shrinkableCount(sample: sample)
            guard count > 0, window.start + count < window.units.count else { return nil }
            let anchorID = window.units[window.start + count].id
            guard let anchor = measurements[anchorID] else { return nil }
            return PlannedWindowMove(move: .shrink, sample: sample,
                anchorUnitID: anchorID, anchorY: anchor.y, renderFirstUnitID: first)
        }
    }

    /// Applies a planned move and publishes it. Measurements of units that
    /// just left the render set are pruned — their y stops being meaningful,
    /// and a stale y must never stand in for a fresh report.
    func commit(_ plan: PlannedWindowMove) {
        switch plan.move {
        case .expand: _ = window.expand(sample: plan.sample)
        case .shrink: _ = window.shrink(sample: plan.sample)
        case .none: return
        }
        lastFrame = window.frame
        let rendered = Set(window.units[window.start...].map(\.id))
        measurements = measurements.filter { rendered.contains($0.key) }
        measuredHeights = measuredHeights.filter { rendered.contains($0.key) }
        moveRevision &+= 1
    }

    private func rebuild(rows: [ChatTimelineRowModel], interactionTargets: Set<String>, width: CGFloat,
                         widthKey: Int, typeScaleKey: Int, typeScale: CGFloat,
                         disclosures: TimelineDisclosureState) {
        let groups = TimelineGrouping.groups(rows, interactionTargets: interactionTargets)
        // F1: each unit carries its first row's raw index — the basis the
        // content body slices `rows` on. Grouping's own count of the rows
        // behind the boundary is not that index whenever a skipped row (a
        // SubAgent child) sits above it.
        let rawStarts = TimelineGrouping.rawStartIndices(in: rows, for: groups)
        let keysMatch = widthKey == lastWidthKey && typeScaleKey == lastTypeScaleKey
        if !keysMatch {
            // Every recorded or measured height is geometry for another
            // column or type size: retire it and re-estimate.
            measurements.removeAll()
            measuredHeights.removeAll()
        }
        var carried: [String: TimelineRenderUnit] = [:]
        if keysMatch {
            carried.reserveCapacity(window.units.count)
            for unit in window.units { carried[unit.id] = unit }
        }
        var nextFacts: [String: TimelineUnitHeightFacts] = [:]
        var units: [TimelineRenderUnit] = []
        units.reserveCapacity(groups.count)
        nextFacts.reserveCapacity(groups.count)
        for (index, group) in groups.enumerated() {
            let unitFacts = Self.unitFacts(of: group, disclosures: disclosures)
            nextFacts[group.id] = unitFacts
            var height: CGFloat
            var isMeasured = false
            if let carriedUnit = carried[group.id] {
                height = carriedUnit.height
                isMeasured = carriedUnit.isMeasured
            } else {
                let key = TimelineUnitHeightKey(id: group.id, width: widthKey, typeScale: typeScaleKey,
                    isCollapsed: unitFacts.isCollapsed, isStreaming: unitFacts.isStreaming)
                if let recorded = heights.height(for: key) {
                    height = recorded
                    isMeasured = true
                } else {
                    height = TimelineUnitHeightEstimator.height(unitFacts, width: width, typeScale: typeScale)
                }
            }
            units.append(TimelineRenderUnit(id: group.id, rowCount: group.rows.count,
                height: height, isMeasured: isMeasured,
                rawStartRowIndex: index < rawStarts.count ? rawStarts[index] : nil))
        }
        facts = nextFacts
        lastWidthKey = widthKey
        lastTypeScaleKey = typeScaleKey
        window.adopt(units)
        lastFrame = window.frame
    }

    private static func unitFacts(of group: ChatTimelineGroup,
                                  disclosures: TimelineDisclosureState) -> TimelineUnitHeightFacts {
        var textLength = 0
        var attachmentCount = 0
        var isStreaming = false
        for row in group.rows {
            textLength += row.text.count
            if case let .message(message) = row.value.content {
                attachmentCount += message.attachments.count
            }
            if row.structure.isStreamingText { isStreaming = true }
        }
        let multi = group.kind != .single
        return TimelineUnitHeightFacts(kind: group.kind,
            isCollapsed: multi && !disclosures.isExpandedIfKnown(group.id),
            rowCount: group.rows.count, textLength: textLength,
            attachmentCount: attachmentCount, isStreaming: isStreaming)
    }
}
