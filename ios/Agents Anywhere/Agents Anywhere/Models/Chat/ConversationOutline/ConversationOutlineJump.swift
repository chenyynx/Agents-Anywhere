import Foundation

/// Where a tap wants to land: the outline row and the exact message inside it.
nonisolated struct ConversationOutlineJumpTarget: Equatable {
    let entryID: V2TimelineItemID
    let partID: V2TimelineItemID
}

/// The outline's jump lifecycle. Mirrors the official six-state machine
/// (`OutlineJump`): a tap is only accepted while idle, a second tap cannot
/// enqueue a second history request, and a target that is not in the loaded
/// window first asks for older history before it can land.
nonisolated enum ConversationOutlineJumpState: Equatable {
    case idle
    case chosen(ConversationOutlineJumpTarget)
    case waiting(ConversationOutlineJumpTarget)
    case asked(ConversationOutlineJumpTarget)
    case landing(ConversationOutlineJumpTarget)
    case askedAgain(ConversationOutlineJumpTarget)

    var target: ConversationOutlineJumpTarget? {
        switch self {
        case .idle: nil
        case let .chosen(target), let .waiting(target), let .asked(target),
             let .landing(target), let .askedAgain(target): target
        }
    }

    var isBusy: Bool { self != .idle }
}

nonisolated enum ConversationOutlineJumpEvent: Equatable {
    /// A row tap. Ignored unless the machine is idle.
    case choose(ConversationOutlineJumpTarget)
    /// The coordinator started resolving the target.
    case begin
    /// The target's row is already in the loaded window.
    case found
    /// The target is not loaded and older history exists.
    case missing
    /// Older history arrived; re-check the target.
    case historyLoaded
    /// No older history remains.
    case historyExhausted
    /// The scroll to the target completed.
    case landed
    /// The landed scroll could not place the target; ask for more history.
    case missingAgain
    case cancel
}

nonisolated enum ConversationOutlineJumpEffect: Equatable {
    case none
    /// Ask the session to load one older page.
    case loadOlder
    /// Scroll the timeline to this message id.
    case scroll(V2TimelineItemID)
}

nonisolated struct ConversationOutlineJumpMachine: Equatable {
    private(set) var state: ConversationOutlineJumpState = .idle

    @discardableResult
    mutating func handle(_ event: ConversationOutlineJumpEvent) -> ConversationOutlineJumpEffect {
        switch (state, event) {
        case (_, .cancel):
            state = .idle
            return .none

        case (.idle, let .choose(target)):
            state = .chosen(target)
            return .none

        case let (.chosen(target), .begin):
            state = .waiting(target)
            return .none

        case let (.waiting(target), .found):
            state = .idle
            return .scroll(target.partID)

        case let (.waiting(target), .missing):
            state = .asked(target)
            return .loadOlder

        case let (.asked(target), .historyLoaded):
            state = .landing(target)
            return .scroll(target.partID)

        case (.asked, .historyExhausted):
            state = .idle
            return .none

        case (.landing, .landed):
            state = .idle
            return .none

        case let (.landing(target), .missingAgain):
            state = .askedAgain(target)
            return .loadOlder

        case let (.askedAgain(target), .historyLoaded):
            state = .landing(target)
            return .scroll(target.partID)

        case (.askedAgain, .historyExhausted):
            state = .idle
            return .none

        default:
            // Everything else is a stale callback; the machine never re-enters
            // a state or fires a second request from it.
            return .none
        }
    }
}
