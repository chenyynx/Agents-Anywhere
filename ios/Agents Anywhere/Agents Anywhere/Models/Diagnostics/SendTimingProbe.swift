import Foundation
import Observation

/// Send-timing probe for the `ios-send-timing-probe` diagnostic build.
///
/// Every hook only stamps a wall-clock timestamp: no `await`, no lock, and no
/// change to any existing flow, ordering or retry rule. Records are held per
/// session; a record is released from its session's "current" slot at turn end
/// and a tap that never produced a pending message is dropped after 60 seconds.
/// The whole store is bounded to 100 records, oldest evicted first.
///
/// Delete this file and its call sites together with the branch.
@MainActor @Observable
final class SendTimingProbe {
    static let shared = SendTimingProbe()

    /// One send's timeline. Each stamp is independent and first-write-wins, so
    /// repeated or late marks are idempotent.
    struct Record: Identifiable, Equatable {
        let id: String
        let sessionId: V2SessionID
        let preview: String
        var tapWall: Date
        var pendingAt: Date?
        var flushStart: Date?
        var flushEnd: Date?
        var httpStart: Date?
        var httpEnd: Date?
        var echoAt: Date?
        var stateRunningAt: Date?
        var firstActivityAt: Date?
        var firstAssistantTextAt: Date?
        var turnEndAt: Date?
        var pendingClientMessageID: String?

        /// A runtime state or a post-echo timeline item has been observed. The
        /// turn end is only stamped after this.
        var hasActivity: Bool { stateRunningAt != nil || firstActivityAt != nil }
        var isFinished: Bool { turnEndAt != nil }
    }

    /// Global cap; the oldest record is evicted first (including a record that
    /// still holds a session's current slot).
    private static let maximumRecords = 100
    /// A tap that never produced a pending message is an orphan after this.
    private static let orphanLifetime: TimeInterval = 60
    /// The runtime states the client counts as "the agent started".
    private static let runningStatuses: Set<V2RuntimeStatus> = [.running, .waiting, .pending, .error]

    private var records: [String: Record] = [:]
    private var insertionOrder: [String] = []
    private var currentBySession: [V2SessionID: String] = [:]
    private var recordIDByPending: [String: String] = [:]
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    // MARK: - Hooks

    /// The composer tap, before the send task starts. New Session (nil) is not
    /// measured.
    func markTap(sessionId: V2SessionID?, preview: String) {
        guard let sessionId, !sessionId.isEmpty else { return }
        dropExpiredOrphan(sessionId: sessionId)
        let record = Record(id: UUID().uuidString, sessionId: sessionId,
                            preview: Self.previewText(preview), tapWall: now())
        records[record.id] = record
        insertionOrder.append(record.id)
        currentBySession[sessionId] = record.id
        enforceLimit()
    }

    /// Binds the locally staged pending message to the session's current record.
    func markPending(sessionId: V2SessionID, clientMessageId: String) {
        guard let id = currentBySession[sessionId], var record = records[id] else { return }
        if record.pendingAt == nil { record.pendingAt = now() }
        if record.pendingClientMessageID == nil {
            record.pendingClientMessageID = clientMessageId
            recordIDByPending[clientMessageId] = id
        }
        records[id] = record
    }

    func markFlushStart(sessionId: V2SessionID) { stamp(\.flushStart, sessionId: sessionId) }
    func markFlushEnd(sessionId: V2SessionID) { stamp(\.flushEnd, sessionId: sessionId) }
    func markHTTPStart(sessionId: V2SessionID) { stamp(\.httpStart, sessionId: sessionId) }

    /// No-op unless the POST actually started, so a pre-POST failure cannot
    /// invent an HTTP window.
    func markHTTPEnd(sessionId: V2SessionID) { stamp(\.httpEnd, sessionId: sessionId, requiresHTTPStart: true) }

    /// The authoritative echo arrived: this is the frame the spinner stops on.
    func markEcho(clientMessageId: String) {
        guard let id = recordIDByPending[clientMessageId], var record = records[id],
              record.echoAt == nil else { return }
        record.echoAt = now()
        records[id] = record
    }

    func markStateRunning(sessionId: V2SessionID) {
        stamp(\.stateRunningAt, sessionId: sessionId, requiresPending: true)
    }

    func markFirstActivity(sessionId: V2SessionID) {
        stamp(\.firstActivityAt, sessionId: sessionId, requiresPending: true)
    }

    func markFirstAssistantText(sessionId: V2SessionID) {
        stamp(\.firstAssistantTextAt, sessionId: sessionId, requiresPending: true)
    }

    /// Releases the session's current record once a fresh idle/error state
    /// follows observed activity. Late calls are no-ops.
    func markTurnEnd(sessionId: V2SessionID) {
        guard let id = currentBySession[sessionId], var record = records[id],
              record.turnEndAt == nil, record.hasActivity else { return }
        record.turnEndAt = now()
        records[id] = record
        currentBySession[sessionId] = nil
    }

    /// Applies one session observation's reply facts to the current record.
    /// Reads only; nothing outside the probe is touched.
    func observe(sessionId: V2SessionID, data: V2SessionData) {
        guard let record = currentBySession[sessionId].flatMap({ records[$0] }) else { return }
        let fresh = data.liveStateIsFresh
        let status = data.state?.status ?? .unknown
        if fresh, Self.runningStatuses.contains(status), record.pendingClientMessageID != nil {
            markStateRunning(sessionId: sessionId)
        }
        // The echo is matched by clientMessageId: awaitingReplyID is already
        // cleared by the time the first reply activity lands.
        if let clientID = record.pendingClientMessageID,
           record.firstActivityAt == nil || record.firstAssistantTextAt == nil,
           let echo = data.items.first(where: { $0.role == .user && $0.source["clientMessageId"]?.stringValue == clientID }) {
            var activity = record.firstActivityAt != nil
            var assistantText = record.firstAssistantTextAt != nil
            for item in data.items where item.orderSeq > echo.orderSeq {
                if !activity, item.role != .user, item.type != .turnStart {
                    activity = true
                    markFirstActivity(sessionId: sessionId)
                }
                if !assistantText, item.role == .assistant, item.type == .message {
                    assistantText = true
                    markFirstAssistantText(sessionId: sessionId)
                }
                if activity, assistantText { break }
            }
        }
        if fresh, status == .idle || status == .error {
            markTurnEnd(sessionId: sessionId)
        }
    }

    // MARK: - Reading

    /// The newest record for a session. Finished records are retained for copy.
    func latest(for sessionId: V2SessionID) -> Record? {
        var index = insertionOrder.count - 1
        while index >= 0 {
            if let record = records[insertionOrder[index]], record.sessionId == sessionId { return record }
            index -= 1
        }
        return nil
    }

    /// One TSV line per record, oldest first, plus a `#` legend line naming the
    /// columns. Missing marks are `-`; all times are integer milliseconds and
    /// `epoch_ms` is the tap's wall-clock epoch, for server-log reconciliation.
    func copyText() -> String {
        dropAllExpiredOrphans()
        var lines = [Self.legend]
        for id in insertionOrder {
            if let record = records[id] { lines.append(Self.line(for: record)) }
        }
        return lines.joined(separator: "\n")
    }

    func clear() {
        records = [:]
        insertionOrder = []
        currentBySession = [:]
        recordIDByPending = [:]
    }

    // MARK: - Bookkeeping

    private func stamp(_ keyPath: WritableKeyPath<Record, Date?>, sessionId: V2SessionID,
                       requiresPending: Bool = false, requiresHTTPStart: Bool = false) {
        guard let id = currentBySession[sessionId], var record = records[id],
              record[keyPath: keyPath] == nil else { return }
        if requiresPending, record.pendingClientMessageID == nil { return }
        if requiresHTTPStart, record.httpStart == nil { return }
        record[keyPath: keyPath] = now()
        records[id] = record
    }

    private func dropExpiredOrphan(sessionId: V2SessionID) {
        guard let id = currentBySession[sessionId], let record = records[id],
              record.pendingClientMessageID == nil,
              record.tapWall < now().addingTimeInterval(-Self.orphanLifetime) else { return }
        remove(recordID: id)
    }

    private func dropAllExpiredOrphans() {
        let cutoff = now().addingTimeInterval(-Self.orphanLifetime)
        var expired: [String] = []
        for id in insertionOrder {
            if let record = records[id], record.pendingClientMessageID == nil, record.tapWall < cutoff {
                expired.append(id)
            }
        }
        for id in expired { remove(recordID: id) }
    }

    private func enforceLimit() {
        while insertionOrder.count > Self.maximumRecords, let oldest = insertionOrder.first {
            remove(recordID: oldest)
        }
    }

    private func remove(recordID: String) {
        if let record = records.removeValue(forKey: recordID) {
            if currentBySession[record.sessionId] == recordID { currentBySession[record.sessionId] = nil }
            if let clientID = record.pendingClientMessageID, recordIDByPending[clientID] == recordID {
                recordIDByPending[clientID] = nil
            }
        }
        insertionOrder.removeAll { $0 == recordID }
    }

    // MARK: - Formatting

    private static let legend = [
        "#", "epoch_ms", "session", "preview",
        "tap_to_pending_ms", "tap_to_send_ms", "flush_ms", "post_roundtrip_ms",
        "tap_to_echo_ms", "post_to_echo_ms", "tap_to_running_ms", "tap_to_first_ms",
        "tap_to_text_ms", "tap_to_end_ms"
    ].joined(separator: "\t")

    private static func line(for record: Record) -> String {
        let epoch = Int((record.tapWall.timeIntervalSince1970 * 1000).rounded())
        let fields = [
            String(epoch),
            record.sessionId,
            record.preview,
            milliseconds(record.pendingAt, since: record.tapWall),
            milliseconds(record.httpStart, since: record.tapWall),
            milliseconds(record.flushEnd, since: record.flushStart),
            milliseconds(record.httpEnd, since: record.httpStart),
            milliseconds(record.echoAt, since: record.tapWall),
            milliseconds(record.echoAt, since: record.httpEnd),
            milliseconds(record.stateRunningAt, since: record.tapWall),
            milliseconds(record.firstActivityAt, since: record.tapWall),
            milliseconds(record.firstAssistantTextAt, since: record.tapWall),
            milliseconds(record.turnEndAt, since: record.tapWall)
        ]
        return fields.joined(separator: "\t")
    }

    private static func milliseconds(_ end: Date?, since start: Date?) -> String {
        guard let end, let start else { return "-" }
        return String(Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    /// The message head, flattened so the TSV line stays one line.
    private static func previewText(_ text: String) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return String(flattened.prefix(12))
    }
}
