import SwiftUI
import Observation
#if DEBUG
import OSLog
#endif

struct ChatTimelineView: View {
    let model: SessionChatModel
    let onAttachment: (V2AttachmentContent) -> Void
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
                    onLoadOlder: loadOlder, onLoadLatest: loadLatest,
                    onHistoryLayout: historyDidLayOut,
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
            .defaultScrollAnchor(.top, for: .sizeChanges)
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
                    olderPull.begin(at: current, promptVisible: olderPromptVisible,
                        canLoad: model.session.hasOlderItems && !model.session.isLoadingHistory && olderLoadRequest == nil && latestLoadRequest == nil)
                    latestPull.begin(at: current, promptVisible: latestPromptVisible,
                        canLoad: model.session.hasNewerItems && !model.session.isLoadingHistory && latestLoadRequest == nil && olderLoadRequest == nil)
                }
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
                    publishViewportSample(value, keyboardTransitionActive: keyboardDrivingLayout)
                    // A landed instant return is confirmed by geometry even when
                    // the tail callback arrived before this sample did.
                    acknowledgeInstantOpeningIfArrived()
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
            .onChange(of: model.responseRevision) { _, _ in
                if model.isOpeningReady { scrolling.requestBottom() }
            }
            .onChange(of: hasInteractions, initial: true) { _, presented in
                scrolling.setInteractionPresented(presented)
            }
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                if ready { scrolling.open(interactionPresented: hasInteractions) }
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
        .onDisappear { viewportUpdates.cancel(); historyUpdates.cancel() }
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
        scrolling.browseHistory()
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
    /// Writes a sample into view state only when it changes a decision (S2).
    /// Sampling stays per-frame in the non-invalidating box; publishing
    /// re-evaluates the page body, so a keyboard transition that only
    /// stretches the visible height must not do it per frame.
    private func publishViewportSample(_ value: TimelineViewport, keyboardTransitionActive: Bool) {
        let tailChanged = viewportSample.tailUpdatedAtPublish != scrolling.tail
        let outcome = TimelineViewportPublicationDecision.outcome(published: scrolling.viewport, next: value,
            keyboardTransitionActive: keyboardTransitionActive, tailChanged: tailChanged)
        guard outcome == .publish else { return }
        scrolling.geometryChanged(value)
        viewportSample.tailUpdatedAtPublish = scrolling.tail
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
    private struct UserScrollSettlement: Equatable {
        let needed: Bool
        let tail: TimelineTailVisibility
        let generation: Int
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
    let onAttachment: (V2AttachmentContent) -> Void
    let onFile: (String) -> Void
    let onSubAgent: (String) -> Void
    let latestPullReady: Bool
    let isLoadingLatest: Bool
    let olderPullReady: Bool
    let isLoadingOlder: Bool
    let keepsOlderPrompt: Bool
    let historyAnchor: TimelineHistoryLayout?
    let onLoadOlder: () -> Void
    let onLoadLatest: () -> Void
    let onHistoryLayout: (TimelineHistoryLayout) -> Void
    let onPromptVisibility: (Bool) -> Void
    let onOlderPromptVisibility: (Bool) -> Void
    let onTailVisibility: (TimelineTailVisibility.Region, Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.model === rhs.model && lhs.latestPullReady == rhs.latestPullReady && lhs.isLoadingLatest == rhs.isLoadingLatest
            && lhs.olderPullReady == rhs.olderPullReady && lhs.isLoadingOlder == rhs.isLoadingOlder
            && lhs.keepsOlderPrompt == rhs.keepsOlderPrompt && lhs.historyAnchor == rhs.historyAnchor
    }
    var body: some View {
        let groups = TimelineGrouping.groups(model.timeline.rows, interactionTargets: Set(model.session.notices.notices
            .filter(\.isVisible).compactMap(\.timelineTargetID)))
        let actions = TimelineTurnActions.build(groups: groups, suppressLatest: model.isRunning || model.session.hasNewerItems,
            hasPendingUserMessage: !model.session.hasNewerItems && (!model.timeline.pendingMessages.isEmpty || !model.session.pendingMessages.isEmpty))
        // Prefer a message whose start cannot move into a prefixed tool group.
        // For an all-tools page, retain the existing group's trailing edge.
        let anchorGroup = historyAnchor.flatMap { anchor in groups.first { $0.rows.contains { $0.id == anchor.anchorRowID } } }
            ?? groups.first { $0.rows.first?.structure.groupKind == .single } ?? groups.last
        let anchorEdge = historyAnchor?.edge ?? (anchorGroup?.rows.first?.structure.groupKind == .single ? .top : .bottom)
        // Keep actual row geometry available as Markdown grows and tool groups
        // change height. Hidden tool details own their deferred work separately.
        VStack(alignment: .leading, spacing: 20) {
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
            ForEach(groups) { group in
                SessionTimelineGroupView(group: group, chat: model, onAttachment: onAttachment, onFile: onFile,
                    turnAction: actions[group.id], onSubAgent: onSubAgent)
                    .id(group.id)
                    .background {
                        if group.id == anchorGroup?.id, let firstRowID = model.timeline.rows.first?.id {
                            Color.clear.onGeometryChange(for: TimelineHistoryLayout.self) { geometry in
                                let frame = geometry.frame(in: .named("chat.timeline.content"))
                                return TimelineHistoryLayout(firstRowID: firstRowID,
                                    anchorRowID: historyAnchor?.anchorRowID ?? group.id, edge: anchorEdge,
                                    y: anchorEdge == .top ? frame.minY : frame.maxY)
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
            // Constant breathing room: status text and card counts cannot
            // change this spacer or create a spurious follow request.
            Group {
                if let text = model.sendingPlaceholder {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else { Color.clear }
            }.frame(height: 32)
                .traceChatLayout("tail-spacer")
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
