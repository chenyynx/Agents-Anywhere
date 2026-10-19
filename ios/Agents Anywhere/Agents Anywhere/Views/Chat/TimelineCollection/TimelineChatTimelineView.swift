import SwiftUI
import UIKit

/// The C4 product timeline: the SwiftUI page's chrome (opening gate, keyboard
/// window, pending/queue/approval events, navigation suspension) around the
/// collection container.
///
/// The old `ChatTimelineView` stays intact and selectable; this view is only
/// built when `aa.timeline.collectionView` is on. I10–I13/I14/I15/I20 and the
/// Markdown externalization stay in C5 — the history prompts render, but their
/// load actions are inert until that wiring lands.
struct TimelineChatTimelineView: View {
    let model: SessionChatModel
    @StateObject private var bridge: TimelineChatBridge
    @State private var keyboard = TimelineKeyboardMonitor()
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @Environment(\.sidebarDrawerIsTransitioning) private var sidebarIsTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var sidebarObscuresDetail

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void) {
        self.model = model
        _bridge = StateObject(wrappedValue: TimelineChatBridge(model: model,
            onAttachment: onAttachment, onFile: onFile, onSubAgent: onSubAgent))
    }

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
    private var navigationIsSuspended: Bool {
        sidebarIsTransitioning || sidebarObscuresDetail
    }
    private var typography: TimelineTypographySnapshot {
        TimelineChatContentAdapter.typography(
            dynamicType: String(describing: dynamicType),
            layoutDirection: layoutDirection == .rightToLeft ? 1 : 0,
            boldText: legibilityWeight == .bold)
    }

    var body: some View {
        // The adapter rebuilds from these observable fields; reading them here
        // is what re-evaluates the representable when a stream flush changes
        // row text in place (the rows array identity does not move).
        let _ = model.timeline.flushRevision
        let _ = model.timeline.pendingMessages
        let _ = model.session.notices.notices
        let _ = model.session.sendQueue.items
        let _ = model.disclosures.revision
        let _ = model.responseRevision
        let _ = model.timeline.windowRevision

        TimelineCollectionView(
            content: bridge.adapter,
            measurer: bridge.adapter.measurer,
            typography: typography,
            onPhaseChanged: { transition in
                if transition.gestureBegan { bridge.readerDidTakeOver() }
            },
            onControllerReady: { controller in bridge.attach(controller) })
            .opacity(model.openingPositionSettled ? 1 : 0)
            .allowsHitTesting(model.isOpeningReady)
            .accessibilityHidden(!model.isOpeningReady)
            .onChange(of: model.isOpeningReady, initial: true) { _, ready in
                if ready { bridge.beginOpening() }
            }
            .onChange(of: navigationIsSuspended, initial: true) { _, suspended in
                bridge.setNavigationSuspended(suspended)
            }
            .onChange(of: model.session.pendingMessages.last?.id) { _, id in
                // A new pending bubble pulls the page to the bottom exactly as
                // the SwiftUI timeline did; an approval card keeps it away.
                if model.isOpeningReady, id != nil, !hasInteractions {
                    bridge.controller?.requestBottom(animated: true, forced: false)
                }
            }
            .onChange(of: model.session.sendQueue.items.map(\.id)) { _, ids in
                if model.isOpeningReady, !ids.isEmpty, !hasInteractions {
                    bridge.controller?.requestBottom(animated: true, forced: false)
                }
            }
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
            // I4's cold-load mask fallback: a no-op scroll or a window that
            // never arrives must not hold the mask forever.
            .task(id: model.isOpeningReady) {
                guard model.isOpeningReady else { return }
                do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
                guard !Task.isCancelled else { return }
                bridge.fallbackOpeningSettle()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                keyboard.setVisible(true)
                bridge.controller?.setKeyboardVisible(true)
                keyboardTransitionBegan(TimelineKeyboardEvent(source: .willShow, userInfo: note.userInfo ?? [:]))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { note in
                keyboard.setVisible(false)
                bridge.controller?.setKeyboardVisible(false)
                keyboardTransitionBegan(TimelineKeyboardEvent(source: .willHide, userInfo: note.userInfo ?? [:]))
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { note in
                keyboardTransitionBegan(TimelineKeyboardEvent(source: .willChangeFrame, userInfo: note.userInfo ?? [:]))
            }
            .onDisappear { bridge.cancel() }
    }

    private func keyboardTransitionBegan(_ event: TimelineKeyboardEvent) {
        keyboard.noteLayoutEvent(event)
        bridge.controller?.beginKeyboardTransition(duration: event.duration)
    }
}

/// Owns the adapter and the controller handshake. A struct cannot capture
/// itself in the representable's escaping callbacks; this reference box keeps
/// the opening/event state in one place.
@MainActor
final class TimelineChatBridge: ObservableObject {
    let model: SessionChatModel
    let adapter: TimelineChatContentAdapter
    private(set) weak var controller: TimelineCollectionController?
    private(set) var readerTookOver = false
    private var navigationSuspended = false
    private var openingPending = false
    private var openingSettled = false

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onSubAgent: @escaping (String) -> Void) {
        self.model = model
        adapter = TimelineChatContentAdapter(model: model, onAttachment: onAttachment,
                                             onFile: onFile, onSubAgent: onSubAgent)
    }

    func attach(_ controller: TimelineCollectionController) {
        self.controller = controller
        adapter.attach(controller)
        controller.onApplyCompleted = { [weak self] in self?.applyCompleted() }
        controller.setNavigationSuspended(navigationSuspended)
        controller.setInteractionPresented(hasInteractions)
        if openingPending, !controller.items.isEmpty { applyCompleted() }
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
        guard openingPending else { return }
        openingPending = false
        openingSettled = true
        controller?.beginOpeningBottom()
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

    func cancel() {
        openingPending = false
    }

    private var hasInteractions: Bool {
        model.session.notices.notices.contains { $0.isVisible && $0.notice.type == "interaction" }
    }
}
