import CoreGraphics

/// The official reducer's motion tag (`CANONICAL/05-layout-scroll.md` §6.3).
/// `easing`/`flying` are Mover springs, `dragging` and `coasting` are the
/// reader's own scroll.
nonisolated enum TimelineAnchorMotion: Equatable {
    case resting
    case easing
    case flying
    case dragging
    case coasting
}

/// The state the official reducer owns (`0x1019ddd30`): placement, motion,
/// the opening-landed latch and the catch-up flag. No offset is stored — the
/// target is always re-resolved from the placement.
nonisolated struct TimelineAnchorState: Equatable {
    var placement: TimelineAnchorPlacement = .end
    var motion: TimelineAnchorMotion = .resting
    var hasLanded = false
    var isFollowingCatchUp = false
}

/// What the driver should do after a reduction. Offset writes happen in one
/// place (`placeDirect`), or through the one Mover (`move`).
nonisolated enum TimelineAnchorAction: Equatable {
    case none
    /// Resolve the placement now and write inset + offset in the current
    /// update. A safe-area change arrives inside the system animation
    /// transaction (probe U1), so this inherits the keyboard animation
    /// without a `UIView.animate` of our own.
    case placeDirect
    /// Run the Mover toward the placement target. The driver chooses the
    /// ease/fly spring from the live distance and records `easing`/`flying`.
    case move
    /// Stop the Mover where it is.
    case halt
}

nonisolated struct TimelineAnchorReduction: Equatable {
    var state: TimelineAnchorState
    var action: TimelineAnchorAction
}

/// The reducer's inputs. The named cases are the nine official events that
/// are statically proven; the rest map AA's product/lifecycle edges onto the
/// same state machine instead of letting each one write the offset itself.
nonisolated enum TimelineAnchorEvent: Equatable {
    /// First laid-out viewport (official `viewportChanged`): the opening
    /// landing. Later ones are no-ops; window replacements use their own case.
    case viewportChanged

    /// A reader gesture began at this reading anchor.
    case readerBeganDragging(id: String, offsetIntoRow: CGFloat)

    /// The finger lifted; `atEnd` is the official bottom test taken at the
    /// lift instant. A coasting reader keeps their position until the
    /// deceleration ends.
    case readerLifted(willCoast: Bool, atEnd: Bool, id: String?, offsetIntoRow: CGFloat)

    /// Deceleration ended (official `coastingEnded`).
    case coastingEnded(atEnd: Bool, id: String?, offsetIntoRow: CGFloat)

    /// The page moved without a finger (official `scrolledWithoutAHand`).
    case scrolledWithoutAHand(atEnd: Bool, id: String?, offsetIntoRow: CGFloat)

    /// A user message is on its way (official `sending`). The model keeps no
    /// anchor pad, so the state itself does not change.
    case sending

    /// The sent row exists (official `sent(RowID)`): pin it to the top.
    case sent(id: String)

    /// An explicit return to the bottom (pill, load-latest, approval gone).
    /// Ignored while dragging and while already travelling to `.end`.
    case askedForEnd(animated: Bool)

    /// The reader asked for the top (status bar tap, official
    /// `askedForStart`): place the first row at the viewport top.
    case askedForStart(id: String)

    /// Keep the current reading anchor (official `askedToStay`).
    case askedToStay

    /// The Mover reached its target (official `arrived`).
    case arrived

    /// Measured content height changed (streaming, measurement, prepend).
    case contentChanged

    /// The SwiftUI safe area changed (keyboard, composer bar, rotation).
    case safeAreaChanged

    /// A whole-window replacement landed (opening trim, load-latest,
    /// recovery snapshot).
    case windowReplaced(readerTookOver: Bool)

    /// An approval/interaction card appeared or left.
    case interactionPresentedChanged(presented: Bool, id: String?, offsetIntoRow: CGFloat)

    /// The drawer hides or reveals the page.
    case navigationSuspendedChanged(suspended: Bool)
}

nonisolated enum TimelineAnchorReducer {
    /// The whole transition table is pure so the ordering rules can be pinned
    /// without a scroll view. `motion == .easing/.flying` is set by the driver
    /// when it actually starts the Mover; the reducer only decides intent.
    static func reduce(_ state: TimelineAnchorState,
                       _ event: TimelineAnchorEvent) -> TimelineAnchorReduction {
        var next = state
        var action: TimelineAnchorAction = .none

        switch event {
        case .viewportChanged:
            // The official first place happens once, after `hasLanded` flips
            // (`0x1019ee110 → 0x1019ddf70 → 0x1019df5f8`).
            guard !next.hasLanded else { break }
            next.hasLanded = true
            action = .placeDirect

        case .readerBeganDragging(let id, let offsetIntoRow):
            // Official `readerBeganDragging` (`0x101a3c980`): dragging, no
            // catch-up, and the placement is derived from what the reader
            // sees.
            next.motion = .dragging
            next.placement = .reading(id: id, offsetIntoRow: offsetIntoRow)
            next.isFollowingCatchUp = false
            action = .halt

        case .readerLifted(let willCoast, let atEnd, let id, let offsetIntoRow):
            next.motion = willCoast ? .coasting : .resting
            if atEnd {
                next.placement = .end
            } else if let id {
                next.placement = .reading(id: id, offsetIntoRow: offsetIntoRow)
            }
            action = .halt

        case .coastingEnded(let atEnd, let id, let offsetIntoRow),
             .scrolledWithoutAHand(let atEnd, let id, let offsetIntoRow):
            next.motion = .resting
            if atEnd {
                next.placement = .end
            } else if let id {
                next.placement = .reading(id: id, offsetIntoRow: offsetIntoRow)
            }

        case .sending:
            break

        case .sent(let id):
            next.placement = .row(id: id)
            next.motion = .resting
            action = .move

        case .askedForEnd(let animated):
            // Official `askedForEnd` is ignored while the finger owns the
            // page and while the page is already flying to `.end`.
            guard next.motion != .dragging else { break }
            if next.placement == .end,
               next.motion == .easing || next.motion == .flying {
                break
            }
            next.placement = .end
            action = animated ? .move : .placeDirect

        case .askedForStart(let id):
            // Official status-bar tap: placement becomes the first row at the
            // viewport top. A finger on the list owns it; the tap is ignored.
            guard next.motion != .dragging else { break }
            next.placement = .reading(id: id, offsetIntoRow: 0)
            next.isFollowingCatchUp = false
            action = .move

        case .askedToStay:
            break

        case .arrived:
            if next.motion == .easing || next.motion == .flying {
                next.motion = .resting
            }

        case .contentChanged:
            // The official target follows a growing `.end` automatically; a
            // reading anchor must not move.
            if next.placement == .end {
                action = .move
            }

        case .safeAreaChanged:
            // The inset changed inside the system animation transaction; a
            // running Mover must not fight it.
            if next.motion == .easing || next.motion == .flying {
                next.motion = .resting
            }
            action = .placeDirect

        case .windowReplaced(let readerTookOver):
            // A reader who has chosen a position is never moved by a window
            // change; everyone else lands at the newest rows without motion.
            if !readerTookOver {
                next.placement = .end
                action = .placeDirect
            }

        case .interactionPresentedChanged(let presented, let id, let offsetIntoRow):
            if presented {
                next.motion = .resting
                if let id {
                    next.placement = .reading(id: id, offsetIntoRow: offsetIntoRow)
                }
                action = .halt
            } else {
                next.placement = .end
                action = .move
            }

        case .navigationSuspendedChanged(let suspended):
            if suspended {
                next.motion = .resting
                action = .halt
            } else {
                action = .placeDirect
            }
        }

        // The catch-up flag is exactly "following the bottom", recomputed after
        // every transition so no call site can forget it.
        next.isFollowingCatchUp = next.placement == .end && next.motion != .dragging
        return TimelineAnchorReduction(state: next, action: action)
    }
}
