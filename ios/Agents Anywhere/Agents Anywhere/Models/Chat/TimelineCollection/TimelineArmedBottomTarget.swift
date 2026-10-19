import Foundation

/// The controller's persistent bottom intent, separate from the transient
/// scrolling command.
///
/// Two arming paths deliberately differ:
///
/// - **forced** — the bottom pill, `loadLatest`, an approval card disappearing,
///   or a window re-assert. These paths call `requestBottom()` unconditionally
///   today; they must not be filtered by `readerRestsAtBottom`/mode.
/// - **follow** — opening, sending, a new pending bubble. These arm only when
///   the reader rests at the bottom or is already returning/following; the
///   send path additionally stays out of the way of a presented interaction.
///
/// Once armed, every measured content-size change re-resolves the bottom
/// offset and pins there. A keyboard transition pauses the pin: the keyboard's
/// own frame-by-frame target owns the offset, and re-pinning inside the window
/// would move the page twice. User gestures, a presented approval, navigation
/// suspension and status-bar scroll-to-top disarm.
nonisolated struct TimelineArmedBottomTarget: Equatable {
    enum Source: Equatable {
        case forced
        case follow
    }

    private(set) var source: Source?
    private(set) var target: CGFloat?
    private(set) var keyboardTransitionActive = false

    var isArmed: Bool { source != nil }

    mutating func forceArm() {
        source = .forced
        target = nil
    }

    /// Returns true when the target is armed (including an existing forced
    /// arm, which a follow request never downgrades).
    @discardableResult
    mutating func armFollowing(readerRestsAtBottom: Bool,
                               mode: TimelineScrollState.Mode,
                               interactionPresented: Bool,
                               requiresNoInteraction: Bool) -> Bool {
        if source == .forced { return true }
        guard readerRestsAtBottom || mode != .reading else { return false }
        guard !(requiresNoInteraction && interactionPresented) else { return false }
        source = .follow
        target = nil
        return true
    }

    mutating func disarm() {
        source = nil
        target = nil
    }

    /// A reader gesture that comes to rest at the measured bottom re-arms the
    /// follow; a presented interaction does not.
    @discardableResult
    mutating func readerDidRestAtBottom(readerRestsAtBottom: Bool,
                                        interactionPresented: Bool) -> Bool {
        guard readerRestsAtBottom, !interactionPresented else { return false }
        if source == nil { source = .follow; target = nil }
        return true
    }

    /// Returning from a drawer: re-arm only if the reader still rests at the
    /// bottom and no approval is presented.
    @discardableResult
    mutating func navigationResumed(readerRestsAtBottom: Bool,
                                    interactionPresented: Bool) -> Bool {
        readerDidRestAtBottom(readerRestsAtBottom: readerRestsAtBottom,
                              interactionPresented: interactionPresented)
    }

    mutating func setKeyboardTransition(_ active: Bool) {
        keyboardTransitionActive = active
    }

    /// Re-resolves the bottom for a new content size. Returns nil when the
    /// target is not armed or the keyboard owns the offset.
    @discardableResult
    mutating func contentChanged(contentHeight: CGFloat,
                                 containerHeight: CGFloat,
                                 topInset: CGFloat,
                                 bottomInset: CGFloat) -> CGFloat? {
        guard isArmed, !keyboardTransitionActive else { return nil }
        let resolved = TimelineOffsetTarget.bottomOffset(contentHeight: contentHeight,
            containerHeight: containerHeight, topInset: topInset, bottomInset: bottomInset)
        target = resolved
        return resolved
    }
}
