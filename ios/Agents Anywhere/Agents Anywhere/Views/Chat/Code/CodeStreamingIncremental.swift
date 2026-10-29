#if canImport(UIKit)
import Foundation

/// Phase 1 of the Code page's streaming rework: incremental parsing, block
/// view reuse and per-block height caching.
///
/// The official Code leaf keeps a document whose settled prefix is frozen and
/// only reparses the open tail (`StreamingMarkdownDocument.frozen/tailSource`,
/// `SessionLiveStreamingAssembler.documentsByBlockIndex`,
/// `MarkdownTextCellRow.leaves`; see
/// `EVIDENCE/round28-doris-followup/README.md`). This switch keeps the previous
/// full-document path one line away while the incremental path is verified on
/// device, and it is also the manual rollback if a document shape the parser
/// cannot key stably is discovered.
@MainActor
enum CodeStreamingIncremental {
    static var enabled = true
}

#if DEBUG
/// Build-cost counters for the Code page's live text path. They exist so the
/// simulator gate can assert that a streaming tick parses/converts/measures
/// only the new tail instead of the whole reply. DEBUG only: the counters are
/// plain MainActor state and are never read by production code.
@MainActor
enum CodePageBuildStats {
    static var parseBlocksCalls = 0
    static var convertCalls = 0
    static var blockViewCreations = 0
    static var textViewCreations = 0
    static var heightCacheHits = 0
    static var heightCacheMisses = 0
    static var fullRebuilds = 0
    static var incrementalUpdates = 0
    static var highlightApplies = 0
    static var highlightIncrementalApplies = 0

    static func reset() {
        parseBlocksCalls = 0
        convertCalls = 0
        blockViewCreations = 0
        textViewCreations = 0
        heightCacheHits = 0
        heightCacheMisses = 0
        fullRebuilds = 0
        incrementalUpdates = 0
        highlightApplies = 0
        highlightIncrementalApplies = 0
    }

    static var snapshot: [String: Int] {
        [
            "parseBlocksCalls": parseBlocksCalls,
            "convertCalls": convertCalls,
            "blockViewCreations": blockViewCreations,
            "textViewCreations": textViewCreations,
            "heightCacheHits": heightCacheHits,
            "heightCacheMisses": heightCacheMisses,
            "fullRebuilds": fullRebuilds,
            "incrementalUpdates": incrementalUpdates,
            "highlightApplies": highlightApplies,
            "highlightIncrementalApplies": highlightIncrementalApplies,
        ]
    }
}
#endif
#endif
