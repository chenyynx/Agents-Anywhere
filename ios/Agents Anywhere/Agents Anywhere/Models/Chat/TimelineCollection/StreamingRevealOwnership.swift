import Foundation

/// Which rows the renderer-owned reveal still owns.
///
/// The row stays on the streaming cell (and its content signature carries the
/// row in `revealingRowIDs`) from the first anchored batch until the cell
/// driver reports that the final run and fade finished. Removing the row is
/// what makes the next apply measure and configure the static body — the step
/// that installs the turn-action footer.
nonisolated struct StreamingRevealOwnership: Equatable {
    private(set) var activeRowIDs: Set<String> = []

    mutating func begin(_ rowID: String) {
        activeRowIDs.insert(rowID)
    }

    /// Returns true when the row was owned (the caller should refresh).
    @discardableResult
    mutating func finish(_ rowID: String) -> Bool {
        activeRowIDs.remove(rowID) != nil
    }

    func isActive(_ rowID: String) -> Bool {
        activeRowIDs.contains(rowID)
    }

    mutating func prune(keeping rowIDs: Set<String>) {
        activeRowIDs.formIntersection(rowIDs)
    }

    /// Stable order for the content signature hash.
    var signatureRowIDs: [String] {
        activeRowIDs.sorted()
    }
}
