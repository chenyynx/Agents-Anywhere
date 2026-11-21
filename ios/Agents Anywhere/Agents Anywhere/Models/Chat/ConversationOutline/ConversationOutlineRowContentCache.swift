import Foundation

/// Reuses a row's ready-to-render content across body evaluations.
///
/// The sheet builds each row's content inside its `ForEach` closure, so every
/// scroll appearance and every one-second reload rebuilt rows that had not
/// changed: the outline probe measured 0.4–1.0 ms per build and 24–101 builds
/// per second while scrolling (pp 2026-11-21, `outline.frame`). Entries are
/// value types that change exactly when their text, status or attachment count
/// changes, so an equal entry can reuse its content untouched.
///
/// Search rows never enter the cache: their content is keyed by the hit
/// excerpt and highlight ranges, which change with every keystroke.
@MainActor
final class ConversationOutlineRowContentCache {
    private struct Slot {
        let entry: ConversationOutlineEntry
        let content: ConversationOutlineRowContent
    }

    private var slots: [V2TimelineItemID: Slot] = [:]

    /// The cached content for `entry`, building and retaining it on a miss.
    /// `make` receives the entry so the caller keeps its probe hook where a
    /// real build happens.
    func content(
        for entry: ConversationOutlineEntry,
        make: (ConversationOutlineEntry) -> ConversationOutlineRowContent
    ) -> ConversationOutlineRowContent {
        if let slot = slots[entry.id], slot.entry == entry {
            return slot.content
        }
        let content = make(entry)
        slots[entry.id] = Slot(entry: entry, content: content)
        return content
    }

    /// Drops rows that left the outline. Called after the entry list rebuilds
    /// so the table never outgrows the current rows.
    func retain(ids: Set<V2TimelineItemID>) {
        guard slots.count != ids.count || !slots.keys.allSatisfy(ids.contains) else { return }
        slots = slots.filter { ids.contains($0.key) }
    }

    /// Rows currently held; a test hook, the sheet never reads it.
    var count: Int { slots.count }
}
