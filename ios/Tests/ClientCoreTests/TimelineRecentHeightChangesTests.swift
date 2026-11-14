import Foundation
import Testing
@testable import ClientCore

@Suite struct TimelineRecentHeightChangesTests {
    @Test func ignoresSubPixelChanges() {
        var changes = TimelineRecentHeightChanges()
        changes.note(itemID: "a", oldHeight: 38, newHeight: 38.4,
                     source: "selfMeasure", at: 1)
        #expect(changes.text(within: 1, now: 1.5) == nil)
    }

    @Test func keepsOnlyTheNewestFour() {
        var changes = TimelineRecentHeightChanges()
        for index in 0..<6 {
            changes.note(itemID: "row\(index)",
                         oldHeight: CGFloat(index) * 10,
                         newHeight: CGFloat(index) * 10 + 30,
                         source: "selfMeasure", at: Double(index))
        }
        let text = changes.text(within: 10, now: 6)
        let parts = text?.split(separator: ";") ?? []
        #expect(parts.count == 4)
        #expect(parts.first?.hasPrefix("row2|20.0->50.0|+30.0|selfMeasure") == true)
        #expect(parts.last?.hasPrefix("row5|50.0->80.0|+30.0|selfMeasure") == true)
    }

    @Test func dropsEntriesOutsideTheWindow() {
        var changes = TimelineRecentHeightChanges()
        changes.note(itemID: "old", oldHeight: 100, newHeight: 70,
                     source: "selfMeasure", at: 0)
        changes.note(itemID: "new", oldHeight: 38, newHeight: 68,
                     source: "selfMeasure", at: 9.8)
        #expect(changes.text(within: 0.5, now: 10)
                == "new|38.0->68.0|+30.0|selfMeasure")
    }

    @Test func keepsAShrinkAndAGrowthInOrder() {
        var changes = TimelineRecentHeightChanges()
        changes.note(itemID: "footer", oldHeight: 164, newHeight: 134,
                     source: "selfMeasure", at: 9.9)
        changes.note(itemID: "echo", oldHeight: 23, newHeight: 53,
                     source: "selfMeasure", at: 9.95)
        #expect(changes.text(within: 0.5, now: 10)
                == "footer|164.0->134.0|-30.0|selfMeasure;"
                + "echo|23.0->53.0|+30.0|selfMeasure")
    }
}
