import Foundation
import Testing
@testable import ClientCore

@Suite("Conversation outline jump state machine")
struct ConversationOutlineJumpTests {
    private let target = ConversationOutlineJumpTarget(entryID: "e1", partID: "m2")

    @Test("a tap walks idle → chosen → waiting → missing → asked")
    func tapToAsked() {
        var machine = ConversationOutlineJumpMachine()
        #expect(machine.handle(.choose(target)) == .none)
        #expect(machine.state == .chosen(target))
        #expect(machine.handle(.begin) == .none)
        #expect(machine.state == .waiting(target))
        #expect(machine.handle(.missing) == .loadOlder)
        #expect(machine.state == .asked(target))
    }

    @Test("a loaded target lands immediately")
    func waitingToLanded() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        #expect(machine.handle(.found) == .scroll("m2"))
        #expect(machine.state == .idle)
    }

    @Test("history arrival scrolls, completion returns to idle")
    func askedToLanding() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        _ = machine.handle(.missing)
        #expect(machine.handle(.historyLoaded) == .scroll("m2"))
        #expect(machine.state == .landing(target))
        #expect(machine.handle(.landed) == .none)
        #expect(machine.state == .idle)
    }

    @Test("a second tap while busy is ignored")
    func duplicateTapDoesNotRequestAgain() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        _ = machine.handle(.missing)

        let other = ConversationOutlineJumpTarget(entryID: "e2", partID: "m9")
        #expect(machine.handle(.choose(other)) == .none)
        #expect(machine.state == .asked(target))
    }

    @Test("exhausted history abandons the jump")
    func exhaustedHistoryReturnsToIdle() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        _ = machine.handle(.missing)
        #expect(machine.handle(.historyExhausted) == .none)
        #expect(machine.state == .idle)
    }

    @Test("a landed scroll that missed asks for history once more")
    func landingToAskedAgain() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        _ = machine.handle(.missing)
        _ = machine.handle(.historyLoaded)
        #expect(machine.handle(.missingAgain) == .loadOlder)
        #expect(machine.state == .askedAgain(target))
        #expect(machine.handle(.historyLoaded) == .scroll("m2"))
        #expect(machine.state == .landing(target))
    }

    @Test("askedAgain with no more history returns to idle")
    func askedAgainExhausted() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        _ = machine.handle(.missing)
        _ = machine.handle(.historyLoaded)
        _ = machine.handle(.missingAgain)
        #expect(machine.handle(.historyExhausted) == .none)
        #expect(machine.state == .idle)
    }

    @Test("cancel clears any in-flight jump")
    func cancel() {
        var machine = ConversationOutlineJumpMachine()
        _ = machine.handle(.choose(target))
        _ = machine.handle(.begin)
        #expect(machine.handle(.cancel) == .none)
        #expect(machine.state == .idle)
        #expect(!machine.state.isBusy)
    }
}
