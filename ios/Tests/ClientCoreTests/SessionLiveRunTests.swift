import Foundation
import Testing
@testable import ClientCore

/// The live observer must survive the view's task being cancelled on a tab
/// switch, run at most one loop at a time, and end with its owning model.
@Suite(.serialized) @MainActor
struct SessionLiveRunTests {
    @MainActor
    private final class Counter {
        var value = 0
        var cancelled = false
    }

    @Test func runsOneOperationAndRestartsAfterItEnds() async throws {
        let run = SessionLiveRun()
        let gate = TestGate()
        let counter = Counter()
        run.start {
            await MainActor.run { counter.value += 1 }
            await gate.wait()
        }
        run.start {
            await MainActor.run { counter.value += 100 }
        }
        await eventually { counter.value == 1 }
        #expect(run.isRunning)

        // The second start was ignored while the first loop was alive.
        try await Task.sleep(for: .milliseconds(20))
        #expect(counter.value == 1)

        gate.release()
        await eventually { !run.isRunning }

        // A finished run can start again (a retried open after a transient
        // repository end must not leave the page permanently detached).
        run.start {
            await MainActor.run { counter.value += 1 }
        }
        await eventually { counter.value == 2 && !run.isRunning }
    }

    @Test func releasingTheRunCancelsItsTask() async {
        let counter = Counter()
        do {
            let run = SessionLiveRun()
            run.start {
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {
                    await MainActor.run { counter.cancelled = true }
                }
            }
        }
        await eventually { counter.cancelled }
    }
}
