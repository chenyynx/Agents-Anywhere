import Foundation

/// The merge rules a dashboard snapshot has always applied, extracted so the
/// in-memory repository (legacy path) and the local-database ingest share one
/// implementation. The rules:
///
/// - a held row wins only while its `updatedSeq` is strictly newer;
/// - `lastReadSeq` never goes backwards, and clears `unread` once it covers
///   the latest turn end;
/// - local pending rows (`local:` ids on a known connector) survive a snapshot
///   that does not mention them;
/// - the result is deduplicated by id and ordered by id (presentation sorts
///   separately);
/// - `reconcile` runs on every row merged from the snapshot (never on the
///   preserved local pending rows), exactly as before.
nonisolated enum DashboardMerge {
    static func apply(held: [V2SessionMeta],
                      incoming: [V2SessionMeta],
                      validConnectorIDs: Set<V2ConnectorID>,
                      reconcile: (V2SessionMeta) -> V2SessionMeta) -> [V2SessionMeta] {
        let current = Dictionary(uniqueKeysWithValues: held.map { ($0.id, $0) })
        let pending = held.filter {
            $0.id.hasPrefix("local:") && validConnectorIDs.contains($0.connectorId)
        }
        let merged = pending + incoming.map {
            merge(current[$0.id], $0, reconcile: reconcile)
        }
        return unique(merged)
    }

    /// The upsert path: merge the mentioned rows into the held list and keep
    /// every row the caller did not mention.
    static func upsert(held: [V2SessionMeta],
                       incoming: [V2SessionMeta],
                       reconcile: (V2SessionMeta) -> V2SessionMeta) -> [V2SessionMeta] {
        var values = Dictionary(uniqueKeysWithValues: held.map { ($0.id, $0) })
        for value in incoming {
            values[value.id] = merge(values[value.id], value, reconcile: reconcile)
        }
        return Array(values.values).sorted { $0.id < $1.id }
    }

    static func merge(_ current: V2SessionMeta?, _ incoming: V2SessionMeta,
                      reconcile: (V2SessionMeta) -> V2SessionMeta) -> V2SessionMeta {
        var value = current.map { $0.updatedSeq > incoming.updatedSeq ? $0 : incoming } ?? incoming
        value.lastReadSeq = max(current?.lastReadSeq ?? 0, incoming.lastReadSeq)
        if value.lastReadSeq >= value.latestTurnEndSeq { value.unread = false }
        return reconcile(value)
    }

    static func unique(_ values: [V2SessionMeta]) -> [V2SessionMeta] {
        var result: [String: V2SessionMeta] = [:]
        for value in values { result[value.id] = value }
        return Array(result.values).sorted { $0.id < $1.id }
    }
}
