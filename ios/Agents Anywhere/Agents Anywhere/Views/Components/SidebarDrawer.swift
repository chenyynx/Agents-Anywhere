import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
/// Requests the screen's maximum refresh rate while the drawer moves.
/// The official drawer animates its card with a keyframe animation whose
/// `preferredFrameRateRange` is the screen maximum (120Hz on ProMotion);
/// AA's SwiftUI spring otherwise settles at 60Hz (device probe: every
/// transition measured 16.7ms). Keeping a display link alive for the
/// transition raises the display to the maximum, and the probe build's
/// `period` field measures it (8.3ms on ProMotion, pp 2026-10-31).
@MainActor
final class SidebarDrawerRefresh {
    static let shared = SidebarDrawerRefresh()
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        let maxFPS = Float(UIScreen.main.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: maxFPS,
                                                        preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    /// The link only requests the rate; its callback has nothing to do.
    @objc private func tick(_ link: CADisplayLink) {}
}
#endif


struct SidebarDrawerConfiguration: Sendable {
    /// The official drawer is `min(320pt, 85% of the container)` wide
    /// (EVIDENCE: 320 @0x105a62f78, 0.85 @0x1059bd000+0xfe0).
    let revealFraction: CGFloat
    let maximumWidth: CGFloat
    let edgeActivationWidth: CGFloat
    let sidebarHeaderEdgeEffectStyle: ScrollEdgeEffectStyle

    init(
        revealFraction: CGFloat = 0.85,
        maximumWidth: CGFloat = 320,
        edgeActivationWidth: CGFloat = 44,
        sidebarHeaderEdgeEffectStyle: ScrollEdgeEffectStyle = .soft
    ) {
        self.revealFraction = revealFraction
        self.maximumWidth = maximumWidth
        self.edgeActivationWidth = edgeActivationWidth
        self.sidebarHeaderEdgeEffectStyle = sidebarHeaderEdgeEffectStyle
    }

    static let chat = SidebarDrawerConfiguration()
}

enum SidebarDrawerPresentation: Equatable, Sendable {
    case drawer
    case nativeSidebar
}

private struct SidebarDrawerPresentationKey: EnvironmentKey {
    static let defaultValue = SidebarDrawerPresentation.drawer
}

private struct SidebarDrawerTransitionKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SidebarDrawerObscuresDetailKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var sidebarDrawerObscuresDetail: Bool {
        get { self[SidebarDrawerObscuresDetailKey.self] }
        set { self[SidebarDrawerObscuresDetailKey.self] = newValue }
    }
    var sidebarDrawerIsTransitioning: Bool {
        get { self[SidebarDrawerTransitionKey.self] }
        set { self[SidebarDrawerTransitionKey.self] = newValue }
    }
    var sidebarDrawerPresentation: SidebarDrawerPresentation {
        get { self[SidebarDrawerPresentationKey.self] }
        set { self[SidebarDrawerPresentationKey.self] = newValue }
    }
}

/// Runs work only while the drawer rests closed over the page. The drawer
/// flips its environment when a pan begins and ends; reading it here keeps
/// that flip from re-evaluating the entire page body in the middle of motion.
private struct SidebarDrawerSettledTask<ID: Equatable>: ViewModifier {
    let id: ID
    let action: (_ settled: Bool) async -> Void
    @Environment(\.sidebarDrawerIsTransitioning) private var isTransitioning
    @Environment(\.sidebarDrawerObscuresDetail) private var obscuresDetail

    private struct Key: Equatable {
        let id: ID
        let settled: Bool
    }

    func body(content: Content) -> some View {
        let settled = !isTransitioning && !obscuresDetail
        content.task(id: Key(id: id, settled: settled)) { await action(settled) }
    }
}

extension View {
    /// Like `task(id:)`, restarted whenever the drawer settles or starts moving.
    func sidebarDrawerSettledTask<ID: Equatable>(
        id: ID,
        _ action: @escaping (_ settled: Bool) async -> Void
    ) -> some View {
        modifier(SidebarDrawerSettledTask(id: id, action: action))
    }
}

struct SidebarDrawer<SidebarHeader: View, SidebarContent: View, MainContent: View>: View {
    @Binding private var isOpen: Bool

    private let presentation: SidebarDrawerPresentation
    private let configuration: SidebarDrawerConfiguration
    private let sidebarHeader: (EdgeInsets) -> SidebarHeader
    private let sidebarContent: (EdgeInsets) -> SidebarContent
    private let mainContent: (EdgeInsets) -> MainContent

    init(
        isOpen: Binding<Bool>,
        presentation: SidebarDrawerPresentation,
        configuration: SidebarDrawerConfiguration,
        @ViewBuilder sidebarHeader: @escaping (EdgeInsets) -> SidebarHeader,
        @ViewBuilder sidebar: @escaping (EdgeInsets) -> SidebarContent,
        @ViewBuilder content: @escaping (EdgeInsets) -> MainContent
    ) {
        _isOpen = isOpen
        self.presentation = presentation
        self.configuration = configuration
        self.sidebarHeader = sidebarHeader
        self.sidebarContent = sidebar
        self.mainContent = content
    }

    var body: some View {
        if presentation == .nativeSidebar {
            SidebarDrawerNativeSplitView(
                isOpen: $isOpen,
                sidebarHeaderEdgeEffectStyle: configuration.sidebarHeaderEdgeEffectStyle,
                sidebarHeader: sidebarHeader,
                sidebarContent: sidebarContent,
                mainContent: mainContent
            )
        } else {
            // Resolve page builders above the state that changes on every pan
            // sample. Equality on the resulting page cannot prevent expensive
            // work that has already happened in its initializer.
            GeometryReader { geometry in
                SidebarDrawerPages(
                    isOpen: $isOpen,
                    configuration: configuration,
                    safeAreaInsets: geometry.safeAreaInsets,
                    sidebarHeader: sidebarHeader,
                    sidebarContent: sidebarContent,
                    mainContent: mainContent
                )
            }
        }
    }
}

/// GeometryReader can revisit its closure even when the insets are unchanged.
/// A view boundary keeps that layout pass from invoking the page factories.
private struct SidebarDrawerPages<SidebarHeader: View, SidebarContent: View, MainContent: View>: View {
    @Binding var isOpen: Bool
    let configuration: SidebarDrawerConfiguration
    let safeAreaInsets: EdgeInsets
    let sidebarHeader: (EdgeInsets) -> SidebarHeader
    let sidebarContent: (EdgeInsets) -> SidebarContent
    let mainContent: (EdgeInsets) -> MainContent

    var body: some View {
        SidebarDrawerInteractive(
            isOpen: $isOpen,
            configuration: configuration,
            safeAreaInsets: safeAreaInsets,
            sidebarHeader: sidebarHeader(safeAreaInsets),
            sidebarContent: sidebarContent(safeAreaInsets),
            mainContent: mainContent(safeAreaInsets)
        )
    }
}

private struct SidebarDrawerInteractive<
    SidebarHeader: View,
    SidebarContent: View,
    MainContent: View
>: View {
    @Binding private var isOpen: Bool

    private let configuration: SidebarDrawerConfiguration
    private let safeAreaInsets: EdgeInsets
    private let sidebarHeader: SidebarHeader
    private let sidebarContent: SidebarContent
    private let mainContent: MainContent

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var motion: SidebarDrawerMotion
    @State private var dragStartProgress: CGFloat?
    @State private var dragDisposition: DragDisposition?
    @State private var animationGeneration = 0
    @State private var isAnimating = false
    @State private var feedbackTrigger = 0
#if AA_TIMELINE_PROBE
    /// Visual variant for the drawer A/B run (see TimelineProbeStore). Set at
    /// the start of each transition; the report averages the frame gaps per
    /// variant so one sliding session attributes the per-frame cost.
    @State private var probeVariant = 0
#endif
    /// The last open/closed target this drawer committed. `isOpen` is
    /// published one main-queue turn after the spring lands, so a fast
    /// open→close leaves the binding stale and made the close gesture look
    /// like "no flip" (pp 2026-11-03: fast swipes played only one cue).
    @State private var committedOpen: Bool

    init(
        isOpen: Binding<Bool>,
        configuration: SidebarDrawerConfiguration,
        safeAreaInsets: EdgeInsets,
        sidebarHeader: SidebarHeader,
        sidebarContent: SidebarContent,
        mainContent: MainContent
    ) {
        _isOpen = isOpen
        _motion = State(initialValue: SidebarDrawerMotion(progress: isOpen.wrappedValue ? 1 : 0))
        _committedOpen = State(initialValue: isOpen.wrappedValue)
        self.configuration = configuration
        self.safeAreaInsets = safeAreaInsets
        self.sidebarHeader = sidebarHeader
        self.sidebarContent = sidebarContent
        self.mainContent = mainContent
    }

    var body: some View {
#if AA_TIMELINE_PROBE
        let _ = TimelineProbeStore.shared.noteDrawerBodyEval()
#endif
        GeometryReader { fullScreenGeometry in
            let screenSize = fullScreenGeometry.size
            let revealWidth = max(
                min(configuration.maximumWidth,
                    screenSize.width * configuration.revealFraction.clamped(to: 0.01 ... 1)),
                1
            )
            let interaction = DrawerInteractionState(isOpen: isOpen, progress: motion.restingProgress,
                isAnimating: isAnimating, isDragging: dragStartProgress != nil)

            ZStack(alignment: .leading) {
                drawerSidebarBackground

                SidebarDrawerSidebar(
                    width: revealWidth,
                    safeAreaInsets: safeAreaInsets,
                    edgeEffectStyle: configuration.sidebarHeaderEdgeEffectStyle,
                    header: sidebarHeader,
                    content: sidebarContent
                )
                .allowsHitTesting(interaction.acceptsSidebarTouches)
                .accessibilityHidden(!interaction.acceptsSidebarTouches)
                .modifier(SidebarDrawerSidebarShade(motion: motion,
                                                    enabled: probeSidebarShadeEnabled))

                SidebarDrawerMainCard(
                    size: screenSize,
                    isFullyClosed: interaction.acceptsContentTouches,
                    clipsContent: probeCardClipEnabled,
                    content: mainContent
                )
                .modifier(SidebarDrawerCardMotion(
                    motion: motion,
                    isFullyClosed: interaction.acceptsContentTouches,
                    revealWidth: revealWidth
                ))
                .allowsHitTesting(interaction.acceptsContentTouches)
                .accessibilityHidden(!interaction.acceptsContentTouches)

                // Only the screen-space strip occupied by the visible card
                // closes the drawer. Its untranslated hit targets are disabled.
                SidebarDrawerCloseArea(motion: motion, revealWidth: revealWidth)
                    .onTapGesture(perform: closeFromOverlay)
                    .allowsHitTesting(interaction.acceptsSidebarTouches)
                    .accessibilityHidden(!interaction.acceptsSidebarTouches)
                    .accessibilityLabel(String(localized: "关闭侧栏"))
                    .accessibilityAddTraits(.isButton)

#if !canImport(UIKit)
                if usesOpeningEdgeGestureRegion {
                    Color.clear
                        .frame(
                            width: max(configuration.edgeActivationWidth, 0),
                            height: screenSize.height
                        )
                        .contentShape(Rectangle())
                        .highPriorityGesture(drawerGesture(revealWidth: revealWidth))
                }
#endif
            }
            .frame(width: screenSize.width, height: screenSize.height)
            // Window rounding belongs to the drawer surface, not to the card:
            // the card's left edge is a seam and must stay straight, while
            // this full-screen clip supplies the display's own corners at
            // every offset (pp 2026-11-01). The frame above is the full
            // screen, so the clip cannot inset the drawer's content.
            .modifier(SidebarDrawerScreenClip(radius: SidebarDrawerScreenCorner.radius,
                                              enabled: probeContainerClipEnabled))
            .contentShape(Rectangle())
#if canImport(UIKit)
            .gesture(
                SidebarDrawerPanGesture(
                    progress: motion.restingProgress,
                    onBegan: beginDirectionalPan,
                    onChanged: { translationX in
                        updateDirectionalPan(
                            translationX: translationX,
                            revealWidth: revealWidth
                        )
                    },
                    onEnded: { translationX, velocityX, cancelled in
                        endDirectionalPan(
                            translationX: translationX,
                            velocityX: velocityX,
                            revealWidth: revealWidth,
                            cancelled: cancelled
                        )
                    }
                )
            )
#else
            .simultaneousGesture(
                drawerGesture(revealWidth: revealWidth),
                isEnabled: !usesOpeningEdgeGestureRegion
            )
#endif
            .onChange(of: isOpen) { _, newValue in
                synchronizeProgress(with: newValue)
            }
        }
        .ignoresSafeArea()
        .environment(\.sidebarDrawerPresentation, .drawer)
        .environment(\.sidebarDrawerObscuresDetail, isOpen || motion.restingProgress > 0)
        .environment(\.sidebarDrawerIsTransitioning, isAnimating || dragStartProgress != nil
            || motion.restingProgress != (isOpen ? 1 : 0))
#if AA_TIMELINE_PROBE
        // The drawer's motion is not a collection-view scroll phase; tell the
        // probe explicitly or the sidebar's dropped frames never reach the
        // report (pp 2026-10-31: drawer jank was not recorded).
        .onChange(of: isAnimating || dragStartProgress != nil
                  || motion.restingProgress != (isOpen ? 1 : 0), initial: true) { _, active in
            if active {
                probeVariant = TimelineProbeStore.shared.nextDrawerVariant()
            }
            TimelineProbeStore.shared.noteDrawerTransition(active,
                                                           opening: motion.progress < 0.5,
                                                           variant: probeVariant)
        }
#endif
        // [E] The official drawer uses the parameterless `.impact`; its
        // weight/intensity are unpublished (CANONICAL/11-motion-haptics.md
        // §2.5), so passing light+1 is a different feedback.
        .sensoryFeedback(.impact, trigger: feedbackTrigger)
        #if canImport(UIKit)
        .onDisappear { SidebarDrawerRefresh.shared.stop() }
        #endif
    }

    private var usesOpeningEdgeGestureRegion: Bool {
        motion.restingProgress == 0 || dragStartProgress.map { $0 <= 0.001 } == true
    }

    /// Probe A/B switches, one effect off per variant. Shipping builds keep
    /// every effect (the `#else` arms).
    private var probeContainerClipEnabled: Bool {
#if AA_TIMELINE_PROBE
        probeVariant != 1
#else
        true
#endif
    }
    private var probeCardClipEnabled: Bool {
#if AA_TIMELINE_PROBE
        probeVariant != 2
#else
        true
#endif
    }
    private var probeSidebarShadeEnabled: Bool {
#if AA_TIMELINE_PROBE
        probeVariant != 3
#else
        true
#endif
    }

    private func beginDirectionalPan() {
        animationGeneration &+= 1
        dragStartProgress = motion.progress
        #if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteDrawerIntent("drag")
        #endif
        #if canImport(UIKit)
        SidebarDrawerRefresh.shared.start()
        #endif
    }

    private func updateDirectionalPan(translationX: CGFloat, revealWidth: CGFloat) {
        guard let dragStartProgress else { return }

        let nextProgress = dragStartProgress + (translationX / revealWidth)
        moveWithoutAnimation(to: nextProgress.clamped(to: 0 ... 1))
    }

    private func moveWithoutAnimation(to next: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            motion.move(to: next)
        }
    }

    private func endDirectionalPan(
        translationX: CGFloat,
        velocityX: CGFloat,
        revealWidth: CGFloat,
        cancelled: Bool
    ) {
        defer { resetDrag() }
        guard let dragStartProgress else { return }

        let releaseProgress: CGFloat
        if cancelled {
            releaseProgress = motion.progress
        } else {
            // The last .changed sample can lag the release; advance to the
            // finger's final translation before deciding where it lands.
            releaseProgress = (dragStartProgress + translationX / revealWidth)
                .clamped(to: 0 ... 1)
            if releaseProgress != motion.progress {
                moveWithoutAnimation(to: releaseProgress)
            }
        }

        // A cancelled gesture keeps the position-only snap: the system took
        // the touch away, so its remaining velocity is not trustworthy.
        let target = cancelled
            ? SidebarDrawerGestureRules.snapTarget(progress: releaseProgress)
            : SidebarDrawerGestureRules.targetProgress(
                progress: releaseProgress,
                velocityX: velocityX
            )
        let initialVelocity = cancelled ? 0 : SidebarDrawerGestureRules.normalizedVelocity(
            velocityX: velocityX,
            progress: releaseProgress,
            targetProgress: target,
            revealWidth: revealWidth
        )

        // The haptic follows the open/closed flip, not the release velocity.
        // A fast flick can end in `.cancelled` (the system takes the touch
        // away), and `feedback: !cancelled` swallowed the close cue exactly
        // when the drawer still snapped shut. `shouldProvideFeedback` in
        // `settle` already refuses a gesture that springs back to the same
        // state, so cancellation only decides the target, not the cue.
        settle(to: target, initialVelocity: initialVelocity, feedback: true)
    }

    private func drawerGesture(revealWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                beginDragIfNeeded(value)

                guard
                    dragDisposition == .horizontal,
                    let dragStartProgress
                else {
                    return
                }

                let nextProgress = dragStartProgress + (value.translation.width / revealWidth)
                moveWithoutAnimation(to: nextProgress.clamped(to: 0 ... 1))
            }
            .onEnded { value in
                defer { resetDrag() }

                guard
                    dragDisposition == .horizontal,
                    let dragStartProgress
                else {
                    return
                }

                let releaseProgress = (dragStartProgress + value.translation.width / revealWidth)
                    .clamped(to: 0 ... 1)
                if releaseProgress != motion.progress {
                    moveWithoutAnimation(to: releaseProgress)
                }
                let target = SidebarDrawerGestureRules.targetProgress(
                    progress: releaseProgress,
                    velocityX: value.velocity.width
                )
                let initialVelocity = SidebarDrawerGestureRules.normalizedVelocity(
                    velocityX: value.velocity.width,
                    progress: releaseProgress,
                    targetProgress: target,
                    revealWidth: revealWidth
                )
                settle(to: target, initialVelocity: initialVelocity, feedback: true)
            }
    }

    private func beginDragIfNeeded(_ value: DragGesture.Value) {
        guard dragDisposition == nil else { return }

        let horizontalDistance = abs(value.translation.width)
        let verticalDistance = abs(value.translation.height)

        guard horizontalDistance > verticalDistance else {
            dragDisposition = .vertical
            return
        }

        guard canBeginHorizontalDrag(value) else {
            dragDisposition = .rejected
            return
        }

        animationGeneration &+= 1
        dragStartProgress = motion.progress
        dragDisposition = .horizontal
    }

    private func canBeginHorizontalDrag(_ value: DragGesture.Value) -> Bool {
        if motion.progress <= 0.001 {
            return value.startLocation.x <= max(configuration.edgeActivationWidth, 0)
                && value.translation.width > 0
        }

        if motion.progress >= 0.999 {
            return value.translation.width < 0
        }

        return true
    }

    private func resetDrag() {
        dragStartProgress = nil
        dragDisposition = nil
    }

    private func closeFromOverlay() {
        guard motion.progress > 0.001 else { return }
        #if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteDrawerIntent("scrim")
        #endif
        settle(to: 0, feedback: true)
    }

    private func synchronizeProgress(with open: Bool) {
        let target: CGFloat = open ? 1 : 0
        guard abs(motion.progress - target) > 0.001 else { return }
        #if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteDrawerIntent("tap")
        #endif
        // Official haptic trigger is the `isOpen` value itself: a button or
        // programmatic toggle fires once, exactly like a drag that commits.
        // `isOpen` already carries the new value here, so the flip check
        // below would always be false — force the feedback for this path.
        settle(to: target, feedback: true, forceFeedback: true)
    }

    // Confirms the snap immediately, then commits external semantic state on completion.
    private func settle(
        to rawTarget: CGFloat,
        initialVelocity: Double = 0,
        feedback: Bool,
        forceFeedback: Bool = false
    ) {
        let target = rawTarget.clamped(to: 0 ... 1)
        // Only a real open/closed flip haptics; a drag that springs back to
        // the same target does not (CANONICAL/11-motion-haptics.md §2.1).
        // The comparison uses the last committed target, not `isOpen`: the
        // binding is published one main-queue turn after the spring lands, so
        // a fast open→close read `isOpen == false` and suppressed the close
        // cue (pp 2026-11-03: fast swipes played only one of the two).
        let shouldProvideFeedback = feedback
            && (forceFeedback
                || SidebarDrawerGestureRules.commitsFlip(targetProgress: target,
                                                         committedOpen: committedOpen))
        committedOpen = target > 0.5

        animationGeneration &+= 1
        let generation = animationGeneration
        isAnimating = true
        #if canImport(UIKit)
        SidebarDrawerRefresh.shared.start()
        #endif

        if shouldProvideFeedback {
            // The drawer's cue is a direct-manipulation haptic: it owns the
            // engine briefly so a turn/tool phase cue cannot swallow it.
            HapticGate.noteUserAction()
            feedbackTrigger &+= 1
        }

        let completion = {
            guard generation == animationGeneration else { return }
            #if canImport(UIKit)
            SidebarDrawerRefresh.shared.stop()
            #endif

            isAnimating = false
            motion.move(to: target)

            // Publishing `isOpen` rebuilds the page body (session list,
            // environment flips, timeline chain) in the frame the spring
            // lands. Defer the write one main-queue turn so the completion
            // frame only tears down the animation, rechecking the generation
            // there: a gesture starting in between owns the state, not this
            // stale target.
            let targetIsOpen = target == 1
            if isOpen != targetIsOpen {
                DispatchQueue.main.async {
                    guard generation == animationGeneration else { return }
                    if isOpen != targetIsOpen {
                        isOpen = targetIsOpen
                    }
                }
            }
        }

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                motion.move(to: target)
            }
            completion()
        } else {
            withAnimation(
                .interpolatingSpring(
                    Spring(response: 0.2, dampingRatio: 1.0),
                    initialVelocity: initialVelocity
                ),
                completionCriteria: .removed
            ) {
                motion.move(to: target)
            } completion: {
                completion()
            }
        }
    }
}

private struct SidebarDrawerNativeSplitView<
    SidebarHeader: View,
    SidebarContent: View,
    MainContent: View
>: View {
    @Binding private var isOpen: Bool

    private let sidebarHeader: (EdgeInsets) -> SidebarHeader
    private let sidebarContent: (EdgeInsets) -> SidebarContent
    private let mainContent: (EdgeInsets) -> MainContent
    private let sidebarHeaderEdgeEffectStyle: ScrollEdgeEffectStyle

    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var isAnimating = false
    @State private var animationGeneration = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        isOpen: Binding<Bool>,
        sidebarHeaderEdgeEffectStyle: ScrollEdgeEffectStyle,
        sidebarHeader: @escaping (EdgeInsets) -> SidebarHeader,
        sidebarContent: @escaping (EdgeInsets) -> SidebarContent,
        mainContent: @escaping (EdgeInsets) -> MainContent
    ) {
        _isOpen = isOpen
        _columnVisibility = State(initialValue: isOpen.wrappedValue ? .all : .detailOnly)
        self.sidebarHeaderEdgeEffectStyle = sidebarHeaderEdgeEffectStyle
        self.sidebarHeader = sidebarHeader
        self.sidebarContent = sidebarContent
        self.mainContent = mainContent
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GeometryReader { geometry in
                let safeAreaInsets = geometry.safeAreaInsets

                SidebarDrawerNativeSidebar(
                    edgeEffectStyle: sidebarHeaderEdgeEffectStyle,
                    header: sidebarHeader(safeAreaInsets),
                    content: sidebarContent(safeAreaInsets)
                )
                .toolbar(removing: .sidebarToggle)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 360)
        } detail: {
            GeometryReader { geometry in
                mainContent(geometry.safeAreaInsets)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.sidebarDrawerPresentation, .nativeSidebar)
        .environment(\.sidebarDrawerIsTransitioning, isAnimating || columnsNeedUpdate)
        .onChange(of: isOpen) { _, newValue in
            updateColumns(open: newValue)
        }
        .onChange(of: columnVisibility) { _, newValue in
            switch newValue {
            case .all, .doubleColumn:
                if !isOpen {
                    isOpen = true
                }
            case .detailOnly:
                if isOpen {
                    isOpen = false
                }
            case .automatic:
                break
            default:
                break
            }
        }
    }

    private func updateColumns(open: Bool) {
        animationGeneration &+= 1
        let generation = animationGeneration
        isAnimating = true
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.3), completionCriteria: .removed) {
            columnVisibility = open ? .all : .detailOnly
        } completion: {
            if animationGeneration == generation { isAnimating = false }
        }
    }

    private var columnsNeedUpdate: Bool {
        switch columnVisibility {
        case .all, .doubleColumn: return !isOpen
        case .detailOnly: return isOpen
        default: return false
        }
    }
}

private struct SidebarDrawerNativeSidebar<Header: View, Content: View>: View {
    let edgeEffectStyle: ScrollEdgeEffectStyle
    let header: Header
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectStyle(edgeEffectStyle, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                SidebarDrawerHeaderBar(
                    safeAreaInsets: EdgeInsets(),
                    header: header
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SidebarDrawerHeaderBar<Header: View>: View {
    let safeAreaInsets: EdgeInsets
    let header: Header

    var body: some View {
        header
            .padding(.top, safeAreaInsets.top)
            .padding(.leading, safeAreaInsets.leading)
            .padding(.trailing, safeAreaInsets.trailing)
            .frame(maxWidth: .infinity)
    }
}

private struct SidebarDrawerSidebar<Header: View, Content: View>: View {
    let width: CGFloat
    let safeAreaInsets: EdgeInsets
    let edgeEffectStyle: ScrollEdgeEffectStyle
    let header: Header
    let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .scrollEdgeEffectStyle(edgeEffectStyle, for: .top)
            .safeAreaBar(edge: .top, spacing: 0) {
                SidebarDrawerHeaderBar(
                    safeAreaInsets: safeAreaInsets,
                    header: header
                )
            }
            .frame(width: width)
            .frame(maxHeight: .infinity, alignment: .leading)
            .background(drawerSidebarBackground)
    }
}

private struct SidebarDrawerMainCard<Content: View>: View {
    let size: CGSize
    let isFullyClosed: Bool
    /// Probe A/B: shipping always clips; variant 2 removes the mask to
    /// measure whether the full-screen clip is the per-frame render cost.
    var clipsContent: Bool = true
    let content: Content

    var body: some View {
        // The card is the official full-window rounded rectangle: the same
        // display-radius corners at every offset, clipped once with the
        // drawer surface so the screen corners always match (pp 2026-11-01).
        let screenShape = SidebarDrawerCardShape.shape(isFullyClosed: isFullyClosed)

        content
            // [E] Only the card's artwork may ignore the safe area; the page
            // itself must keep the window's insets so its navigation bar,
            // `safeAreaBar` composer and scroll content settle in the official
            // full-screen positions (R21 chrome-verify.md). Ignoring the safe
            // area here forced the page to re-add it with padding, which is
            // what painted opaque status-bar/home-indicator strips.
            .frame(width: size.width, height: size.height)
            .background(drawerCardBackground, in: screenShape)
            .modifier(SidebarDrawerCardClip(shape: screenShape, enabled: clipsContent))
            .contentShape(screenShape)
    }
}

private struct SidebarDrawerCardClip: ViewModifier {
    let shape: RoundedRectangle
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.clipShape(shape)
        } else {
            content
        }
    }
}

private struct SidebarDrawerScreenClip: ViewModifier {
    let radius: CGFloat
    let enabled: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content.clipShape(RoundedRectangle(cornerRadius: radius, style: .circular))
        } else {
            content
        }
    }
}

/// The card's visible left outline: the top-left corner arc, the straight
/// left edge, then the bottom-left arc. Official drawerA measures this arc
/// at radius 165px = 55pt, i.e. the display's own corner radius, and the 1px
/// edge line follows it (pp 2026-11-01).
private struct CardSeamLine: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        var path = Path()
        path.move(to: CGPoint(x: r, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY + r),
                    radius: r)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - r))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX + r, y: rect.maxY),
                    radius: r)
        return path
    }
}

/// The display's own corner radius. UIKit exposes it on the screen; the
/// fallback is the common Pro/Plus radius so a missing key still rounds.
private enum SidebarDrawerScreenCorner {
    static var radius: CGFloat {
#if canImport(UIKit)
        let screen = UIScreen.main
        // KVC (not perform) — the property returns a CGFloat, which
        // objc_msgSend hands back in a register, not as an object.
        if screen.responds(to: NSSelectorFromString("displayCornerRadius")),
           let value = screen.value(forKey: "displayCornerRadius") as? NSNumber,
           value.doubleValue > 0 {
            return CGFloat(value.doubleValue)
        }
        return 55
#else
        return 0
#endif
    }
}

private enum SidebarDrawerCardShape {
    /// The card is the full-window rounded rectangle at the display's own
    /// corner radius (official drawerA: the top-left arc fits a 165px = 55pt
    /// circle, the edge line follows it). The container clip keeps the screen
    /// corners; the card shape is identical at every offset so the seam never
    /// jumps during the drag (pp 2026-11-01).
    static func shape(isFullyClosed: Bool) -> RoundedRectangle {
        _ = isFullyClosed
        return RoundedRectangle(cornerRadius: SidebarDrawerScreenCorner.radius,
                                style: .circular)
    }
}

/// Drawer position, read only by the small render modifiers below. A pan
/// sample then updates their effects without re-evaluating the drawer
/// container, the page modifier chains, or anything that reads the drawer's
/// environment. Code that only needs to know where the drawer rests reads
/// `restingProgress`, which changes once per gesture instead of every frame.
@MainActor @Observable final class SidebarDrawerMotion {
    private(set) var progress: CGFloat
    /// 0 when closed, 1 when fully open, 0.5 anywhere in between.
    private(set) var restingProgress: CGFloat

    init(progress: CGFloat) {
        self.progress = progress
        restingProgress = Self.resting(progress)
    }

    func move(to next: CGFloat) {
        // A clamped overscroll repeats the bound and a stationary finger
        // repeats the same sample; writing either again invalidates every
        // reader for nothing. Equal values imply equal rest states, and
        // restingProgress already matches the last change, so both fields
        // are correct as-is.
        guard next != progress else { return }
        progress = next
        let resting = Self.resting(next)
        if restingProgress != resting { restingProgress = resting }
    }

    private static func resting(_ progress: CGFloat) -> CGFloat {
        progress <= 0.001 ? 0 : progress >= 0.999 ? 1 : 0.5
    }
}

private struct SidebarDrawerCardMotion: ViewModifier {
    let motion: SidebarDrawerMotion
    let isFullyClosed: Bool
    let revealWidth: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    /// The official card edge: 1px hairline in rgb(205,205,202) on light.
    /// The dark value is not closed yet, so the previous primary hairline
    /// stays there.
    private var edgeLineColor: Color {
        colorScheme == .dark
            ? Color.primary.opacity(0.2)
            : Color(red: 205.0 / 255.0, green: 205.0 / 255.0, blue: 202.0 / 255.0)
    }

    func body(content: Content) -> some View {
        let progress = motion.progress
        let screenShape = SidebarDrawerCardShape.shape(isFullyClosed: isFullyClosed)

        content
            .background {
                // [E] The content pane's own shadow (black, radius 6,
                // opacity 0.1) only turns on when the content edges are
                // exposed — the side-by-side layout. The overlay drawer is
                // `edgesShown = false`, so its in-card shadow stays at 0;
                // the visible seam shadow comes from the drawer below.
                // Opaque at every offset: fading the fill with progress made
                // the card translucent while it moved (pp 2026-11-01).
                //
                // Shadow only the card shape, never the content. Before the
                // sidebar visual remodel the shadow lived here, with a note
                // that compositing the conversation into an animated shadow
                // layer repaints its text every frame; the remodel moved it
                // onto the translated card. b953's probe then measured the
                // drawer at ~50ms/frame (p50 across every transition).
                screenShape.fill(drawerCardBackground)
                    .shadow(color: .black.opacity(0.05), radius: 10, x: 0, y: 0)
                    .allowsHitTesting(false)
            }
            // No scrim on the card: both reference screenshots keep the
            // content surface at its undimmed value (249) at full and half
            // open, so the official scrim token is not applied here.
            .overlay {
                // [E] contentBorder alpha is binary: (fraction > 0) ? 1 : 0
                // (0x10105186c). The line follows the card's left outline —
                // top arc, straight edge, bottom arc (official drawerA).
                CardSeamLine(radius: SidebarDrawerScreenCorner.radius)
                    .stroke(edgeLineColor, lineWidth: 1 / max(displayScale, 1))
                    .opacity(progress > 0.001 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Ordinary offset still participates in descendant coordinates:
            // subpixel motion can round this 402-point column to 402 1/3 and
            // change paragraph wrapping. Keep the whole translation out of
            // layout, including every interpolated frame of the spring.
            .modifier(SidebarDrawerTranslation(x: revealWidth * progress).ignoredByLayout())
    }
}

/// [E] Official drawer `shade`: black over the drawer content at
/// (1 − offset/width) × 0.4. Fully open = no dimming; the reference
/// screenshots measure the sidebar at 243 (open) vs 203 (half open).
private struct SidebarDrawerSidebarShade: ViewModifier {
    let motion: SidebarDrawerMotion
    /// Probe A/B: shipping always shades (variant 3 removes it).
    var enabled: Bool = true

    @ViewBuilder func body(content: Content) -> some View {
        if enabled {
            content
                .overlay {
                    Color.black
                        .opacity(max(0, 1 - motion.progress) * 0.4)
                        .allowsHitTesting(false)
                }
        } else {
            content
        }
    }
}

/// Screen-space strip occupied by the visible card while the drawer is open.
private struct SidebarDrawerCloseArea: View {
    let motion: SidebarDrawerMotion
    let revealWidth: CGFloat

    var body: some View {
        // The strip only accepts taps at rest (`acceptsSidebarTouches`), where
        // the resting value equals `progress` (0 or 1). Reading it here keeps
        // pan samples from rebuilding the hit shape every frame; the 0.5 band
        // only exists while touches are already rejected.
        let region = SidebarDrawerCloseRegion(leadingEdge: revealWidth * motion.restingProgress)
        region.fill(.clear)
            .contentShape(.interaction, region)
    }
}

private enum DragDisposition {
    case horizontal
    case vertical
    case rejected
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Sidebar surface: #F3F3F0 light, #111111 dark (pixel samples from the
/// reference screenshots).
private var drawerSidebarBackground: Color {
#if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 17.0 / 255.0, alpha: 1)
            : UIColor(red: 243.0 / 255.0, green: 243.0 / 255.0,
                      blue: 240.0 / 255.0, alpha: 1)
    })
#elseif canImport(AppKit)
    Color(nsColor: .windowBackgroundColor)
#else
    Color.clear
#endif
}

/// Content card surface: #F9F9F7 light, #151515 dark (pixel samples).
private var drawerCardBackground: Color {
#if canImport(UIKit)
    Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(white: 21.0 / 255.0, alpha: 1)
            : UIColor(red: 249.0 / 255.0, green: 249.0 / 255.0,
                      blue: 247.0 / 255.0, alpha: 1)
    })
#elseif canImport(AppKit)
    Color(nsColor: .windowBackgroundColor)
#else
    Color.clear
#endif
}
