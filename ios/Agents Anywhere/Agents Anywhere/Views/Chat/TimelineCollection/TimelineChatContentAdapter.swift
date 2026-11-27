import SwiftUI
import UIKit
import QuartzCore
import Observation

/// Which edge the single `isLoadingHistory` flag belongs to. The two prompt
/// rows must not both show a spinner: an older-page read while the reader is
/// at the bottom would otherwise claim "loading newer records".
enum TimelineHistoryLoadDirection {
    case older
    case latest
}

/// Adapts one `SessionChatModel` projection to the collection timeline.
///
/// The SwiftUI timeline's body built groups, notices, pending bubbles and the
/// tail on every evaluation and let the scroll view measure them lazily. The
/// C4 container needs the same content as a stable top-level list (`TimelineItemIdentity`)
/// plus a signature per item, because heights are measured before apply. This
/// adapter is the only place that translation happens; `SessionChatModel` and
/// the row views stay unchanged.
///
/// It is not `@Observable` on purpose: the wrapper re-evaluates on the model's
/// own observable fields (`flushRevision`, pending, notices, queue) and calls
/// into the controller, which asks for `contentGeneration`. Rebuilding the
/// item list happens once per wrapper update.
@MainActor
final class TimelineChatContentAdapter: TimelineCollectionContentProviding {
    let model: SessionChatModel
    private let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    private let onFile: (String) -> Void
    /// Body-link routing for the Code rows; false means "let the system open".
    private let onOpenLink: (URL) -> Bool
    private let onSubAgent: (String) -> Void

    weak var controller: TimelineCollectionController?

    /// The Code page reports a collapsed tool row's tap here; the page owns the
    /// sheet (a cell-local `@State` would be rebuilt by every streaming
    /// reconfigure and could dismiss an open detail).
    var onCodeToolDetail: ((CodeToolDetailRequest) -> Void)?
    /// A settled `思考过程` row's tap; same page-level sheet as a tool detail.
    var onCodeThinkingDetail: ((CodeThinkingDetailRequest) -> Void)?
    /// The chat profile's step-group row tap; same page-level sheet.
    var onCodeStepGroupDetail: ((CodeStepGroupDetailRequest) -> Void)?
    /// The working row's text just appeared after a server-acknowledged send —
    /// the page turns this edge into the "message is in" haptic. Called
    /// asynchronously: the refresh that detects it runs inside a SwiftUI
    /// update, and publishing from there is a view-update mutation.
    var onWorkingTextShown: (() -> Void)?

    /// The representable marks the list stale once per SwiftUI update; reading
    /// the generation rebuilds the maps, and every later `item(at:)` /
    /// `contentSignature` call reads them without re-grouping.
    ///
    /// A SwiftUI update is not the same as a model change: the drawer's
    /// per-frame motion re-evaluates the page every frame, and a full
    /// `refresh()` costs 20–30 ms on a 354-row window (that was the drawer's
    /// 50 ms frame in the b953/b966 probe). Only the observable inputs this
    /// adapter consumes may start a rebuild.
    func prepareForUpdate() {
        let fingerprint = updateFingerprint()
        guard fingerprint != lastUpdateFingerprint else { return }
        lastUpdateFingerprint = fingerprint
        needsRefresh = true
    }

    /// Internal state changes (a reveal finishing, the working-status exit)
    /// do not move any model input but still need a rebuild.
    func forceRefresh() {
        lastUpdateFingerprint = nil
        needsRefresh = true
    }

    /// Whether the step sheet for group `id` opens at its newest step.
    ///
    /// Read at tap time, never captured when the cell was configured: the
    /// live-tail id and the running-turn set both move with the turn, while a
    /// configured cell keeps its snapshot — a cell configured mid-turn would
    /// otherwise keep opening at the bottom after the turn settled
    /// (review 2026-11-10).
    private func stepDetailStartsAtBottom(_ id: String) -> Bool {
        if id == chatLiveTailGroupID { return true }
        return model.isRunning && chatRunningTurnGroupIDs.contains(id)
    }

    var contentGeneration: Int {
        if needsRefresh {
            needsRefresh = false
            refresh()
        }
        return generation
    }
    private var needsRefresh = true
    private var lastUpdateFingerprint: Int?

    /// Freeze or resume the Code page's streaming reveal. Hidden pages keep
    /// receiving (and feeding their publishers) but the cursor stops where it
    /// stood; the switch back resumes from that point, which is what makes a
    /// returning tab replay the backlog instead of flashing it all at once.
    func setPageRevealVisible(_ visible: Bool) {
        guard pageRevealVisible != visible else { return }
        let wasVisible = pageRevealVisible
        pageRevealVisible = visible
        if !visible {
            codeRevealResuming = true
            // The model's window is authoritative at the hide edge. Rows that
            // already carry assistant text — even ones this adapter has not
            // sampled yet — are seen text; capturing them here keeps an
            // 18-message backlog from replaying on the next return
            // (pp 2026-11-27, 9698 chars). Rows that exist but are still empty
            // (turn just started, tool-only so far) are NOT seen text: the
            // reply that fills them arrives while away and must replay.
            for row in model.timeline.rows where StreamingRevealReplayPolicy.hasSeenText(
                isAssistantText: row.value.isAssistantText,
                textEmpty: row.value.displayText.isEmpty) {
                codeKnownRowIDs.insert(row.id)
            }
            // A page that was on screen has been "seen" even if its first
            // refresh has not run yet; a reply that appears while it is away
            // should still replay.
            if wasVisible { hasSampledCodeRevealWhileVisible = true }
        }
        let now = ProcessInfo.processInfo.systemUptime
        for rowID in Array(codeRevealCursors.keys) {
            guard var cursor = codeRevealCursors[rowID] else { continue }
            cursor.setVisible(visible, at: now)
            codeRevealCursors[rowID] = cursor
        }
        // The counts are from the last sample, not a new one: a resume's
        // backlog only becomes known when the first refresh samples it (the
        // `shell.tabs.reveal.pump` line carries that number).
        ClientDiagnosticsLog.shared.record(
            kind: "shell.tabs.reveal",
            sessionID: model.session.id,
            detail: ["visible": visible ? "1" : "0",
                     "cursors": String(codeRevealCursors.count),
                     "behind": String(codeRevealBehindRowIDs.count),
                     "backlog": String(codeRevealBacklog)])
    }

    /// Every observable input `refresh()` reads. The chat page's body reads
    /// the same set, so a re-evaluation caused by one of them changes this
    /// fingerprint; a re-evaluation caused by the drawer does not.
    private func updateFingerprint() -> Int {
        var hasher = Hasher()
        hasher.combine(model.timeline.flushRevision)
        hasher.combine(model.timeline.windowRevision)
        hasher.combine(model.timeline.rows.count)
        hasher.combine(model.responseRevision)
        hasher.combine(model.isRunning)
        // The drawn posing reads streaming (not raw in-flight): the stop tap
        // itself settles it (`stopRequested`), the ack flips `predictedIdle`
        // while `isRunning` is still true, and a fresh idle makes a late
        // `running` row stale (pp 2026-11-14).
        hasher.combine(model.isTranscriptStreaming)
        hasher.combine(model.session.runtime.isFresh)
        // `interruptedTurns` is cached until the next timeline apply, so this
        // hashes only the handful of markers, not the whole timeline. Keep the
        // exact b1166 fingerprint semantics: no rebuild can be missed.
        hasher.combine(model.interruptedTurns.map(\.anchorItemID).joined(separator: ","))
        hasher.combine(model.isAwaitingReply)
        hasher.combine(String(describing: model.orbActivity))
        hasher.combine(model.session.canLoadOlder)
        hasher.combine(model.session.hasNewerItems)
        hasher.combine(model.session.hasOlderItems)
        hasher.combine(model.session.localOlderAvailable)
        hasher.combine(model.session.isLoadingHistory)
        hasher.combine(model.session.metadata?.cwd)
        // The footer's durable turn-end fact can arrive on a session meta
        // frame with no row/state change (a settle sync seeding an old
        // session). Without it in the fingerprint the adapter keeps the old
        // build and the footer waits for an unrelated refresh.
        hasher.combine(model.session.metadata?.latestTurnId)
        hasher.combine(model.session.metadata?.latestTurnEndSeq)
        // The durable rule falls back offline; an online/offline transition
        // must rebuild even when no row or runtime state changed. Only the
        // boolean the build consumes is hashed — `.failed(String)` carries a
        // message that can change without changing the footer decision.
        let connectorOffline: Bool = {
            switch model.session.connection {
            case .offline, .failed: return true
            case .inactive, .connecting, .connected, .reconnecting: return false
            }
        }()
        hasher.combine(connectorOffline)
        hasher.combine(model.session.pendingMessages.count)
        hasher.combine(model.timeline.pendingMessages.count)
        hasher.combine(model.session.isSendQueuePaused)
        for pending in model.timeline.pendingMessages {
            hasher.combine(pending.id)
            hasher.combine(String(describing: pending.delivery))
        }
        for item in model.session.sendQueue.items {
            hasher.combine(item.id)
            hasher.combine(String(describing: item.state))
        }
        for notice in model.session.notices.notices {
            hasher.combine(notice.id)
            hasher.combine(notice.notice.revision)
        }
        return hasher.finalize()
    }
    private var generation = 0
    private var itemsValue: [TimelineListItem] = []
    private var itemsByID: [String: TimelineListItem] = [:]
    private var groupsByID: [String: ChatTimelineGroup] = [:]
    /// Runtime resolved once per refresh from the session metadata; every code
    /// group is built and rendered against this profile.
    private var codeProfile: CodeRuntimeProfile = .generic
    /// `CodeMessageBuilder` output for each code group, keyed by the group's
    /// explicit unit id (a message key or a span's tool-use id). Built once per
    /// refresh so `estimateKind` / `heightPolicy` do not re-run the builder for
    /// every layout pass.
    private var codeRowsByGroupID: [String: [CodeMessageRow]] = [:]
    /// The chat profile's step groups, keyed by the id their item carries.
    /// Empty in `.code` mode.
    private var stepGroupsByID: [String: TimelineStepGroup] = [:]
    /// The same step groups, published for the detail sheet: a sheet that is
    /// already open must keep updating while the turn streams (pp 2026-10-30).
    let liveStepGroups = TimelineLiveStepGroups()
    /// The chat profile's trailing step group while its turn is live. The
    /// working mark seats on this row (pp 2026-10-29: the dots always lead the
    /// last group, never a separate row below it).
    private var chatLiveTailGroupID: String?
    /// The one group this update draws the working mark on: the newest group
    /// the base pose rule would draw (the live tail, or the newest group with
    /// a running step). A running dispatched-subagent row settles only when a
    /// newer owner exists — otherwise it keeps the dots, because the
    /// standalone 「正在处理中」 row is suppressed while the turn has step
    /// groups and settling it would leave no working mark on screen
    /// (pp 2026-11-21).
    private var chatMarkOwnerGroupID: String?
    /// Last queue roster the handoff probe saw (diagnostics only).
    private var lastQueueProbeRoster: String?
    /// The groups of the actively streaming turn. Only these may animate a
    /// step that still reports `running`; a previous turn's stale snapshot
    /// must not (pp 2026-11-14), and a background subagent that outlived its
    /// turn must stay on the settled row when a new turn streams
    /// (pp 2026-11-19).
    private var chatRunningPoseGroupIDs: Set<String> = []
    /// The top-level items the interrupted-turn notices follow (the units
    /// that hold each stopped turn's last row). Empty when no stop is known
    /// for this session, or when the anchor rows are outside the window.
    private var chatInterruptedItemIDs: Set<String> = []
    /// Last interrupted-card anchors the diagnostics probe saw. The card's
    /// height is applied by the adapter apply that first knows the anchor;
    /// logging that moment separates "the marker apply drew it" from "a later,
    /// unrelated refresh dragged its height in" (device 2026-11-14).
    private var lastInterruptedCardProbeIDs: Set<String> = []
    /// The chat profile's step groups whose first row belongs to the turn in
    /// flight. Their detail sheet opens at the newest step even when the group
    /// is not the trailing unit (body text between two tool runs) or nothing
    /// is running (the gap between two steps) (pp 2026-11-10). Empty in
    /// `.code` mode.
    private var chatRunningTurnGroupIDs: Set<String> = []
    /// The selected rendering profile (pp 2026-10-29). `.code` keeps the
    /// official Code page; `.chat` renders one step-group live row.
    let renderMode: TimelineRenderMode
    /// The last message group of a live turn. It owns the transcript's single
    /// working status line; every other reasoning-only group is not rendered
    /// (device report 2026-10-23: two "Computing…" lines plus the tail orb).
    /// One streaming publisher per in-flight assistant text row. The publisher
    /// is fed with the row's full text on every refresh and dropped as soon as
    /// the row settles (CANONICAL/03-streaming.md §5.1: 0.1 s leading-edge
    /// throttle of whole snapshots, no chunk split).
    private var codeStreamingPublishers: [String: CodeStreamingPublisher] = [:]
    /// The last published snapshot of a row that just settled. It keeps the
    /// final text on screen until the persisted text covers it, so completion
    /// never shortens or jumps the row (official: the `isComplete` snapshot is
    /// published before the row is replaced, §6/§8).
    private var codeCompletedStreamingTexts: [String: String] = [:]
    /// When each completion snapshot was stored. The snapshot is a bridge
    /// until the persisted row catches up; a server that permanently returns
    /// a shorter prefix must not pin it forever (R19 review R2 P2-1).
    private var codeCompletedStreamingAt: [String: TimeInterval] = [:]
    private static let codeCompletedStreamingLifetime: TimeInterval = 2
    /// Official working-mark exit: 0.4 s group animation before the row is
    /// removed (CANONICAL/20-working-mark.md §6). The item stays in the list
    /// with `isRunning = false` for that window.
    private var workingStatusIsExiting = false
    private var workingStatusExitWorkItem: DispatchWorkItem?
    private var lastHasWorkingStatus = false
    /// The text gate at the last refresh. The row's visibility does not change
    /// when the send is acknowledged; only this flag does, and it is the
    /// send's "the server has it" signal (pp 2026-11-16).
    private var lastWorkingStatusShowsText = true
    private static let workingStatusExitDuration: TimeInterval = 0.4
    /// In-place exit flag for the mounted working row. See
    /// `WorkingStatusRowHost`: a reconfigure would reset `WorkingMarkView`.
    private let workingStatusExitState = WorkingStatusExitState()
    /// When the current working block appeared; the official verb rotation is
    /// anchored on it (the `.server` phase timing `0x102a85174`).
    private var workingStatusPhaseStart: Date?
    /// The live turn's thinking block: the row currently being watched, when
    /// this client first saw it running, and the closed summary once it
    /// settles. The official row measures the running tiers from the turn
    /// start and shows the closed label for 2 s from the block's own end
    /// (`0x102a88dfc`; R24 `live-thinking-timer.md`).
    private var liveThinkingRowID: String?
    private var liveThinkingObservedStart: Date?
    private var liveThinkingClosed: (id: String, endedAt: Date, seconds: Int)?
    private var tailNoticesByID: [String: SessionNoticeModel] = [:]
    private var pendingByID: [String: V2PendingMessage] = [:]
    private var rowToItem: [String: TimelineListItem] = [:]
    private var inlineNoticesByRow: [String: [SessionNoticeModel]] = [:]
    private var turnActions: [String: TimelineTurnAction] = [:]
    /// Stable open/closed boundary for the one-footer-per-turn rule; the
    /// runtime status alone flaps across tool steps (see `TurnFooterGate`).
    private var turnFooterGate = TurnFooterGate()
    private var signaturesByItem: [TimelineListItem: TimelineContentSignature] = [:]
    private var lastEntries: [TimelineContentEntry] = []
    private var typography: TimelineTypographySnapshot
    /// The Code page's official Markdown metrics (`CodePageTheme.markdownScale`:
    /// 17 pt body, 27.2 line height, 15 pt mono). Code rows are measured,
    /// keyed and drawn with this snapshot; the Chat rows keep the reader's
    /// scheme.
    private var codeTypography: TimelineTypographySnapshot
    private var isRefreshing = false
    /// Last width `heightKey` was asked for. `estimateKind` runs immediately
    /// after it in the layout's prepare loop, so this is the column the
    /// estimate must use without threading a width through the provider.
    private var lastWidth: CGFloat = 0
    /// Reuses the chat profile's units across stream ticks.
    private var chatGroupingCache = TimelineChatGroupingCache()
    /// The last grouping shape written to diagnostics. A live turn changes it
    /// often; logging only changes keeps the trail useful without flooding it.
    private var lastGroupingSignature: String?
    /// Cheap shape key for the grouping diagnostics. A stream tick rewrites
    /// one row's text, so the grouping output is rebuilt every tick while the
    /// rows/units/kind counts stay put. The full-window `validateUnits` sort
    /// and `groupingSummary` filter only run when the shape moves, or once a
    /// second so a row that changes unit without changing counts is still
    /// reported.
    private var lastDiagnosticsStructureKey = ""
    private var lastDiagnosticsAt: TimeInterval = 0
    /// Identity hash of the item list. The send-frame `timeline.rows.frame`
    /// log builds two Sets and diffs them; the identity scan is O(items) and
    /// allocation-free when nothing moved.
    private var lastItemsFrameHash: Int?

    /// The last compact row's state and the words the divider would draw,
    /// logged when it changes. A compaction leaves a handful of lines; a
    /// missing settled line means the client never applied the marker's
    /// update, while a settled line plus a stale label points at the renderer
    /// (pp 2026-11-15, b1230: 「正在压缩对话…」stayed after the compaction
    /// finished until the session was reopened).
    private var lastCompactRowProbe: String?

    /// The footers committed while the footer gate stood closed — i.e. while
    /// the latest turn was finished. A userless episode (a compaction
    /// continuation or the scheduled turn a background-task notification
    /// wakes) reopens the gate and suppresses the final commit, which used to
    /// drop the finished turn's footer for the whole episode (pp 2026-11-16:
    /// the bar blinked out whenever a background CI monitor completed).
    private var closedTurnActions: [String: TimelineTurnAction] = [:]

    /// The last turn-footer host set written to diagnostics. The action bar's
    /// presence is otherwise invisible in a log: a disappearance only shows up
    /// as a 30 pt content drop (`timeline.mover`), and the reason has to be
    /// inferred from `timeline.grouping` counts. One line per change names the
    /// groups that carry copy/share, so a report like pp's 2026-11-16 「压缩
    /// 之后复制/分享出现又消失」 is read directly instead of reconstructed.
    private var lastTurnFooterProbe: String?
    /// Last gate snapshot written by `recordFooterGateProbe`; the probe only
    /// logs a change.
    private var lastFooterGateProbe: String?
    /// Last `timeline.turn.footer.build` line; the probe only logs a change.
    private var lastFooterBuildProbe: String?
    /// Rows that were once seen as background dispatches while they stayed in
    /// the window. The claim is not stable on the wire: a card rebuilt from
    /// the transcript (or re-minted after a connector restart lost its
    /// in-memory task overlay) carries no `agents[*].isBackgrounded`, and the
    /// transcript's tool input may omit `runInBackground`; without this memory
    /// the exemption flips back and a still-running card counts as activity,
    /// withholding the finished turn's footer (pp 2026-11-24, sess_2zXT:
    /// four background agents, footer absent for ~1 min until a later
    /// publication carried the flag again). Monotonic for the row's window
    /// life; pruned when the row leaves the window.
    private var backgroundDispatchedItemIDs: Set<String> = []
    /// Per-group turn facts, keyed by the group's cheap row identity
    /// (`TimelineTurnActions.GroupFactsKey`). Only the group whose rows moved
    /// is walked again on a stream tick.
    private var groupFactsCache: [String: TimelineTurnActions.GroupTurnFacts] = [:]
    private var groupFactsKeys: [String: TimelineTurnActions.GroupFactsKey] = [:]
    private var groupFactsLatch: Set<String> = []
    /// Whether this refresh recomputed any group's facts (diagnostics).
    private var factsMissedThisRefresh = false
    /// The turn a covering idle state proved ended, kept until the durable
    /// ledger supersedes it or the session changes (`FooterStateSeal`). A row
    /// of this turn rewritten after the state can no longer withdraw the
    /// footer; a different turn never matches it. A running runtime withholds
    /// its effect, but the seal stays readable so the closed-state restore can
    /// tell a resume from a userless new turn.
    private var stateSealCommit: TimelineTurnActions.FooterStateSeal?
    private var stateSealSessionID: String?

    private func noteTurnFooterState(groups: [ChatTimelineGroup]) {
        // Hosts, in timeline order; the copy text itself is never logged.
        let hosts = groups.compactMap { actionBarCopyText(for: $0.id) == nil ? nil : $0.id }
        let probe = hosts.joined(separator: ",")
        guard probe != lastTurnFooterProbe else { return }
        lastTurnFooterProbe = probe
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.turn.footer",
            sessionID: model.session.id,
            detail: ["hosts": probe, "count": String(hosts.count)],
            dedupe: false)
    }

    /// Low-frequency footer-gate snapshot (pp 2026-11-18).
    ///
    /// A footer can leave the map while its rows stay put — the 2026-11-18
    /// send-window drop was decided entirely by the gate's inputs, and the
    /// exported log carried none of them. Only a change is written, so a
    /// normal session adds a handful of lines.
    private func recordFooterGateProbe(suppressLatest: Bool, pendingID: String?,
                                       pendingHasEcho: Bool, liveTurnGroupID: String?,
                                       latestUserRowID: String?,
                                       latestUserOrder: Int?,
                                       groups: [ChatTimelineGroup],
                                       gateLiveUserTurn: Bool,
                                       latchedBackgroundIDs: Set<String>) {
        let status = model.session.runtime.state?.status.rawValue ?? "nil"
        // `ignored` names the exempt active row (background hand-off /
        // sub-agent child / compaction) that `active` cannot show — the
        // 2026-11-23 fork stayed `running` yet sat in neither list before
        // this field existed. Both
        // lists are collected on every refresh, not only in a send window:
        // the 2026-11-24 missing footer was decided outside one, and without
        // the ids the log could only say "suppressed". The walk is bounded by
        // the groups after the last visible user bubble.
        let activeIDs = TimelineTurnActions.liveActivityRowIDs(
            groups: groups, latestUserRowID: latestUserRowID,
            latchedBackgroundIDs: latchedBackgroundIDs)
        let ignoredIDs = TimelineTurnActions.ignoredActivityRowIDs(
            groups: groups, latestUserRowID: latestUserRowID,
            latchedBackgroundIDs: latchedBackgroundIDs)
        let probe = [
            "suppress=\(suppressLatest ? 1 : 0)",
            "gate=\(gateLiveUserTurn ? 1 : 0)",
            "pending=\(pendingID == nil ? 0 : 1)",
            "echo=\(pendingHasEcho ? 1 : 0)",
            "running=\(model.isRunning ? 1 : 0)",
            "status=\(status)",
            "liveGroup=\(liveTurnGroupID == nil ? "nil" : "set")",
            "active=\(activeIDs.joined(separator: ","))",
            "ignored=\(ignoredIDs.joined(separator: ","))",
            "lastUser=\(latestUserRowID ?? "nil")",
            // The position makes a key regression (the steer correction that
            // caused the 2026-11-23 footer drop) visible without replaying
            // the timeline: a lower value than the previous line is the
            // correction, not a new turn.
            "lastUserOrder=\(latestUserOrder.map(String.init) ?? "nil")",
        ].joined(separator: " ")
        guard probe != lastFooterGateProbe else { return }
        lastFooterGateProbe = probe
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.footer.gate",
            sessionID: model.session.id,
            detail: ["state": probe],
            dedupe: false)
    }

    /// The footer build's own decision, one line per change (pp 2026-11-24).
    ///
    /// The gate probe names `suppressLatest`' inputs, but a footer can also be
    /// withheld by `build`'s activity gate (`hasActiveItems`) while the state
    /// looks trustworthy — the 2026-11-24 report had three refreshes with
    /// `suppress=0` and no footer, and the log could not name the blocking
    /// row. This line carries the coverage numbers that decide
    /// `runtimeStateKnown`, the active row ids, the host the bucket would have
    /// used, and whether the final commit wrote. Low frequency: only a change
    /// is recorded.
    private func noteFooterBuildReport(_ report: TimelineTurnActions.FooterBuildReport,
                                       suppressLatest: Bool,
                                       latestTurnOpen: Bool,
                                       coverage: TimelineTurnActions.FooterStateCoverage,
                                       stateExists: Bool,
                                       runtimeStateSeq: Int,
                                       connection: V2SessionConnectionState) {
        // The change key deliberately omits the raw sequence numbers: a
        // background subagent bumps `anyMax` on every child-row publish, and
        // including it would turn this "one line per change" probe into a
        // stream. The numbers still ride the written line, so the moment a
        // decision changes has the exact coverage that produced it.
        // `failed(String)` carries an associated message; the packed `state=`
        // value is split on spaces, so only the stable case label goes in.
        let connectionLabel: String = {
            switch connection {
            case .inactive: return "inactive"
            case .connecting: return "connecting"
            case .connected: return "connected"
            case .reconnecting: return "reconnecting"
            case .offline: return "offline"
            case .failed: return "failed"
            }
        }()
        let turnMatchLabel = report.latestTurnSeal.map { $0 ? "1" : "0" } ?? "nil"
        let decision = [
            "suppress=\(suppressLatest ? 1 : 0)",
            "gate=\(latestTurnOpen ? 1 : 0)",
            "running=\(model.isRunning ? 1 : 0)",
            "newer=\(model.session.hasNewerItems ? 1 : 0)",
            "fresh=\(model.session.runtime.isFresh ? 1 : 0)",
            "conn=\(connectionLabel)",
            "hasState=\(stateExists ? 1 : 0)",
            "coversMain=\(coverage.coversMainRows ? 1 : 0)",
            "active=\(report.activeItemIDs.joined(separator: ","))",
            "hasActive=\(report.hasActiveItems ? 1 : 0)",
            "end=\(report.endGroupID ?? "nil")",
            "replies=\(report.replyCount)",
            "changes=\(report.changeCount)",
            "commit=\(report.committed ? 1 : 0)",
            "facts=\(factsMissedThisRefresh ? "miss" : "hit")",
            "stateSeal=\(report.stateSealKept ? 1 : 0)",
            "latestTurn=\(report.latestTurnID ?? "nil")",
            "bucketTurn=\(report.bucketTurnID ?? "nil")",
            "turnMatch=\(turnMatchLabel)",
            "endSeq=\(report.latestTurnEndSeq)",
            "fallback=\(report.latestTurnSeal == nil ? 1 : 0)",
        ].joined(separator: " ")
        guard decision != lastFooterBuildProbe else { return }
        lastFooterBuildProbe = decision
        let probe = decision + " stateSeq=\(runtimeStateSeq)"
            + " mainMax=\(coverage.maxMainSeq) bgMax=\(coverage.maxBackgroundSeq)"
            + " anyMax=\(coverage.maxAnySeq)"
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.turn.footer.build",
            sessionID: model.session.id,
            detail: ["state": probe],
            dedupe: false)
    }

    private func noteCompactRowState() {
        // Same live-turn boundary as `liveTurnIsCompacting()`: the marker a
        // turn can still change sits after the last row that STARTS a visible
        // turn. A steering row is a user message but not a boundary, so the
        // scan must not stop at one.
        var compact: V2TimelineItem?
        for row in model.timeline.rows.reversed() {
            let item = row.value
            // Sub-agent child rows belong to their own transcript; the main
            // page's live state never reads them (pp 2026-11-16).
            if SubAgentProgress.parentItemID(item) != nil { continue }
            if item.startsVisibleTurn { break }
            if TimelineEntryPresentation.isCompactItem(item) { compact = item; break }
        }
        guard let item = compact else {
            // The marker left the live turn (a new prompt arrived): forget
            // the last line so the next compaction logs its own first state.
            lastCompactRowProbe = nil
            return
        }
        let state = item.raw["content"]?["state"]?.stringValue ?? "nil"
        let probe = "\(item.id)|\(item.status.rawValue)|\(state)|\(item.revision)"
        guard probe != lastCompactRowProbe else { return }
        lastCompactRowProbe = probe
        // The label is parsed only when the row's own state moved, not on
        // every stream refresh.
        let title = TimelineEntryPresentation(item: item,
                                              cwd: model.session.metadata?.cwd).title
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.compact.row",
            sessionID: model.session.id,
            detail: [
                "item": item.id,
                "status": item.status.rawValue,
                "state": state,
                "revision": String(item.revision),
                "title": title,
            ],
            dedupe: false)
    }

    /// What the last chat refresh built for each unit, aligned by index.
    /// The grouping cache proves the leading units unchanged; their built
    /// groups are still exact, so the refresh rebuilds only the tail — the
    /// per-message `CodeMessageBuilder.rows` projection was the remaining
    /// per-tick cost after incremental grouping (b1078 probe: refresh 7.1 ms,
    /// group 2.4, signature 0.5).
    private struct ChatUnitBuild {
        /// The group appended for this unit, nil when the unit rendered
        /// nothing (a missing row or a message with no blocks).
        var group: ChatTimelineGroup? = nil
        /// A message unit's block projection, reused verbatim.
        var messageRows: [CodeMessageRow]? = nil
    }
    private var lastChatUnits: [TimelineChatUnit] = []
    private var lastChatBuilds: [ChatUnitBuild] = []
    private var estimateCache: [String: CGFloat] = [:]

    // C4 renders the history prompts but leaves their pull/load state to C5;
    // the controller's pull machinery is already shared, so C5 only fills
    // these flags and closures from its history state.
    private var olderPullReady = false
    private var latestPullReady = false
    private var isLoadingOlder = false
    private var isLoadingLatest = false
    /// Set by the bridge for the in-flight history read. `refresh` uses it to
    /// decide which prompt owns the shared model flag.
    var historyLoadDirection: TimelineHistoryLoadDirection?
    private var keepsOlderPrompt = false
    var onLoadOlder: (() -> Void)?
    var onLoadLatest: (() -> Void)?

    /// Set by the bridge before `loadOlder()` starts. The next refresh that
    /// sees a new first row installs the absolute prepend target before the
    /// controller applies the snapshot, so the reader's anchor does not move.
    struct PendingHistoryRequest {
        let generation: Int
        let anchorRowID: String
        let beforeFirstRowID: String?
        let edge: TimelineHistoryLayout.Edge
        let createdAt: Date
    }
    var pendingHistoryRequest: PendingHistoryRequest?

    /// First timeline row of the first item, the value the prepend target
    /// compares against. The history prompt deliberately reports the first
    /// timeline row (not the prompt id); a prompt id would never change and
    /// the target would never install.
    var firstRowID: String? {
        itemsValue.first.flatMap { rowIDs(in: $0).first }
    }

    init(model: SessionChatModel,
         onAttachment: @escaping (V2AttachmentContent, UIImage?) -> Void,
         onFile: @escaping (String) -> Void,
         onOpenLink: @escaping (URL) -> Bool,
         onSubAgent: @escaping (String) -> Void,
         renderMode: TimelineRenderMode = .merged) {
        self.model = model
        self.onAttachment = onAttachment
        self.onFile = onFile
        self.onOpenLink = onOpenLink
        self.onSubAgent = onSubAgent
        self.renderMode = renderMode
        typography = Self.currentTypography()
        codeTypography = Self.currentTypography(scale: CodePageTheme.markdownScale)
        refresh()
        needsRefresh = false
    }

    var measurer: TimelineHostingHeightMeasurer {
        if let hostedMeasurer { return hostedMeasurer }
        let created = TimelineHostingHeightMeasurer { [weak self] itemID in
            guard let self, let item = self.item(forItemID: itemID) else { return AnyView(EmptyView()) }
            return self.rowView(for: item, width: 0)
        }
        hostedMeasurer = created
        return created
    }
    private var hostedMeasurer: TimelineHostingHeightMeasurer?

    func attach(_ controller: TimelineCollectionController) {
        self.controller = controller
    }

    // MARK: - Content providing

    var itemCount: Int { itemsValue.count }

    func item(at index: Int) -> TimelineListItem { itemsValue[index] }

    func contentSignature(for item: TimelineListItem) -> TimelineContentSignature {
        signaturesByItem[item] ?? makeSignature(for: item)
    }

    func heightKey(for item: TimelineListItem, width: CGFloat) -> TimelineHeightKey {
        lastWidth = width
        let scale = heightTypography(for: item)
        return TimelineHeightKey(itemID: item.itemID,
            contentRevision: heightContentRevision(for: item, width: width),
            width: width,
            dynamicType: scale.dynamicType,
            typographyRevision: scale.revision,
            layoutDirection: scale.layoutDirection)
    }

    /// Code message rows use the official Code metrics; every other row keeps
    /// the reader's Chat scheme.
    private func heightTypography(for item: TimelineListItem) -> TimelineTypographySnapshot {
        if case .group(let id) = item, groupsByID[id]?.explicitID != nil {
            return codeTypography
        }
        return typography
    }

    /// The height key's content revision follows what the row **draws**, not
    /// the wire bookkeeping. `revision`/`updatedSeq` still drive `reconfigure`
    /// (the cell must re-read new text), but the server also bumps them while
    /// reordering siblings and streaming without changing the drawn content;
    /// hashing them into the height key retired measured heights for no visual
    /// reason (probe 2026-10-23). The published streaming snapshot (and a
    /// completion snapshot the persisted text has not covered yet) is part of
    /// the drawn content, so it is included here.
    private struct CachedHeightRevision {
        let signature: Int
        let width: CGFloat
        let typography: Int
        let scale: Int
        let streaming: [String: String]?
        let value: Int
    }
    private var heightRevisionCache: [String: CachedHeightRevision] = [:]

    private func heightContentRevision(for item: TimelineListItem, width: CGFloat) -> Int {
        guard case .group(let id) = item, groupsByID[id]?.explicitID != nil else {
            return contentSignature(for: item).contentRevision
        }
        // `prepare` asks for every row's key on every layout pass; hashing the
        // whole message text there would put a per-frame O(text) cost on the
        // scroll path. The signature (cached per item) and the paced snapshot
        // decide whether the drawn content moved, so a settled row is a hit.
        let signature = contentSignature(for: item).contentRevision
        let quantized = TimelineHeightKey.quantize(width)
        // Code rows are measured with `codeTypography`; the Chat font setting
        // must not retire their measured heights.
        let typographyRevision = codeTypography.revision
        let scale = Int(((controller?.traitCollection.displayScale ?? 2) * 100).rounded())
        let streaming = codeStreamingTexts(for: item)
        if let cached = heightRevisionCache[item.itemID],
           cached.signature == signature,
           cached.width == quantized,
           cached.typography == typographyRevision,
           cached.scale == scale,
           cached.streaming == streaming?.textsByRowID {
            return cached.value
        }
        var hasher = TimelineStableHasher()
        hasher.combine(codeHeightDigest(rows: codeRowsByGroupID[id] ?? [],
                                        width: width,
                                        hasActionBar: actionBarCopyText(for: id) != nil,
                                        hasInterruptedNotice:
                                            interruptedNoticeExtraHeight(for: id) > 0))
        if let streaming {
            for rowID in streaming.textsByRowID.keys.sorted() {
                hasher.combine(rowID)
                hasher.combine(streaming.textsByRowID[rowID] ?? "")
            }
        }
        let value = hasher.revision
        heightRevisionCache[item.itemID] = CachedHeightRevision(
            signature: signature, width: quantized, typography: typographyRevision,
            scale: scale, streaming: streaming?.textsByRowID, value: value)
        return value
    }

    /// The official LoadOlderHeader is a 36 pt spinner row that exists only
    /// while a page loads; the idle sentinel draws nothing. Its height is a
    /// state constant, not a measurement — the row body is empty when idle,
    /// so a measurement never arrives and the old 44 pt estimate stayed in
    /// the cache forever (the status-bar scroll-to-top then stopped one
    /// footer height short of the first message, pp 2026-11-26).
    func layoutFixedHeight(for item: TimelineListItem) -> CGFloat? {
        guard case .olderPrompt = item else { return nil }
        return isLoadingOlder || isLoadingLatest ? 36 : 0
    }

    func estimateKind(for item: TimelineListItem) -> TimelineHeightEstimateKind {
        switch item {
        case .olderPrompt: return .olderPrompt
        case .latestPrompt: return .latestPrompt
        case .workingStatus: return .fixed(CodeWorkingStatusRow.estimatedHeight)
        case .tail:
            // An empty queue leaves exactly the spacer (12 pt, or 32 pt with
            // the status line). Declaring that as a fixed height lets the
            // layout take it in the same apply that removes the last queued
            // bubble; otherwise the row keeps the bubble's height until the
            // cell self-reports and the bottom drops a bubble late (device
            // 2026-11-14: the page jumped when a queued message was sent).
            if model.session.sendQueue.items.isEmpty {
                return .fixed(TimelineHeightEstimateKind.tail(
                    statusLine: tailStatusLineVisible).height)
            }
            return .tail(statusLine: tailStatusLineVisible)
        case .notice: return .row
        case .pending(let id):
            guard let pending = pendingByID[id] else { return .row }
            // The optimistic Code row has the same block shape a settled
            // message gets: one text bubble followed by its attachment grids.
            // Measuring it with `CodeRowHeightPlan` (not the Chat line/180 pt
            // estimate) keeps the first frame from jumping when the echo
            // replaces the pending row.
            var blocks: [CodeMessageRow.Block] = []
            if !pending.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                blocks.append(.text(id: id, text: pending.content))
            }
            let contents = pending.attachments.map(\.content)
            if !contents.isEmpty {
                blocks.append(.attachments(id: id, files: contents,
                                           clientMessageID: pending.id))
            }
            guard !blocks.isEmpty else { return .row }
            let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
            return .fixed(CodeMessageHeightMeasurer.height(
                rows: [CodeMessageRow(id: id, role: .user, blocks: blocks)],
                width: width,
                typography: codeTypography,
                traits: controller?.traitCollection,
                measured: false,
                pixelSize: attachmentPixelSize,
                attachmentIsFailed: { content in
                    pending.codeAttachmentState(for: content) == .failed
                }))
        case .group(let id):
            guard let group = groupsByID[id] else { return .row }
            // The compaction divider declares its exact height. The generic
            // text floor (44 pt) was 10 pt short of the drawn row, so every
            // fresh layout estimated, then corrected by 10 pt, and the anchor
            // followed the correction (pp 2026-11-15: 「压缩分割线会抖」,
            // `timeline.mover start delta 10.0` on every open).
            if compactGroupRow(id) != nil {
                return .fixed(CompactedDivider.estimatedHeight(
                    traits: controller?.traitCollection))
            }
            // The chat profile's step-group row is always one line; its live
            // text changes but never its height. A stopped turn adds the fixed
            // notice card under it.
            if stepGroupsByID[id] != nil {
                let extra = chatInterruptedItemIDs.contains(
                    TimelineListItem.group(id).itemID)
                    ? CodeStepGroupRowView.interruptedNoticeExtraHeight : 0
                return .fixed(CodeStepGroupRowView.estimatedHeight + extra)
            }
            // A Code message group has no folds: its estimate is the message's
            // body text plus one line per collapsed tool row (W7 §3.6 / §6).
            if group.explicitID != nil {
                return codeEstimateKind(for: item, groupID: id)
            }
            // No row expands in place on this page: every group draws its own
            // rows, so the estimate walks all of them.
            let rows = group.rows
            // The answered question card stacks a header, a question and an
            // answer — the generic one-line tool estimate (44 pt) is 52 pt
            // short of the ~96 pt card, so every realised card corrected the
            // layout under the reader and overlapped its neighbour (pp
            // 2026-11-21; log contentH grew in +52 steps). Ask the card for
            // its own arithmetic instead.
            if rows.count == 1, let row = rows.first,
               let answered = QuestionAnsweredModel(item: row.value) {
                let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
                var hasher = TimelineStableHasher()
                hasher.combine(contentSignature(for: item).contentRevision)
                hasher.combine(width)
                let cacheKey = hasher.revision
                if let cached = answeredCardEstimateCache[cacheKey] { return .fixed(cached) }
                // The card's group is self-margined: the view draws the Code
                // page's 5 pt top and bottom margins itself, so the cell has
                // to carry them too (pp 2026-11-22).
                let height = QuestionAnsweredCardView.estimatedHeight(
                    pairs: answered.pairs, width: width)
                    + 2 * CodePageTheme.rowMarginTop
                if answeredCardEstimateCache.count > 600 { answeredCardEstimateCache.removeAll() }
                answeredCardEstimateCache[cacheKey] = height
                return .fixed(height)
            }
            let cwd = model.session.metadata?.cwd
            var textRows: [TimelineHeightEstimate.TextRow] = []
            textRows.reserveCapacity(rows.count)
            for row in rows {
                // A reasoning / tool / marker / compact row is one line, not
                // body text. Counting the hidden payload would park a large
                // blank block above the row until the cell fit corrects it.
                let kind = row.entry(cwd: cwd).kind
                let oneLine: Bool
                switch kind {
                case .reasoning, .compact, .tool:
                    oneLine = true
                case .marker:
                    // `TimelineEntryPresentation` classifies a plain message as
                    // `.marker`; only a real marker row is one line.
                    oneLine = row.structure.type != .message
                case .artifact:
                    oneLine = false
                }
                textRows.append(TimelineHeightEstimate.TextRow(
                    text: oneLine ? "" : row.text,
                    attachmentCount: oneLine ? 0 : attachments(of: row.value).count))
            }
            return .text(textEstimate(for: item, rows: textRows, minimum: 44))
        }
    }

    /// The Code message group's estimate. It is only used while the group is
    /// still streaming: a settled group is measured exactly before apply
    /// (`measuredCodeGroupHeight`), so the row never corrects itself under the
    /// reader's finger.
    ///
    /// The arithmetic is `CodeRowHeightPlan`: the same paddings, scaled line
    /// box and row spacing the row view uses. `CodeMessageHeightMeasurer`
    /// answers with an already-measured component when one is cached and with
    /// the plain-text placeholder otherwise; it never hosts a view here, so
    /// the layout's prepare pass stays cheap. The old plain-text model took
    /// the unscaled 24 pt line box and wrapped long Bash commands, so every
    /// tool-only row arrived 2 pt too tall and long commands reserved hundreds
    /// of points the first fit had to give back (device report 2026-10-23).
    private func codeEstimateKind(for item: TimelineListItem,
                                  groupID: String) -> TimelineHeightEstimateKind {
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        let scale = Int(((controller?.traitCollection.displayScale ?? 2) * 100).rounded())
        var hasher = TimelineStableHasher()
        hasher.combine(contentSignature(for: item).contentRevision)
        hasher.combine(width)
        hasher.combine(typography.revision)
        hasher.combine(scale)
        let cacheKey = hasher.revision
        if let cached = codeEstimateCache[cacheKey] { return .fixed(cached) }
        let height = CodeMessageHeightMeasurer.height(
            rows: codeRowsByGroupID[groupID] ?? [],
            width: width,
            typography: typography,
            traits: controller?.traitCollection,
            measured: false,
            pixelSize: attachmentPixelSize)
        if codeEstimateCache.count > 600 { codeEstimateCache.removeAll() }
        codeEstimateCache[cacheKey] = height
        return .fixed(height)
    }
    private var codeEstimateCache: [Int: CGFloat] = [:]
    /// Answered question cards' exact pre-measure heights, keyed the same way
    /// as `codeEstimateCache` (content revision + width).
    private var answeredCardEstimateCache: [Int: CGFloat] = [:]

    /// The official `SessionRowHeightEstimator` (`0x10253d650`;
    /// `ClaudeCode/SessionRowHeightEstimator.swift`; formula in
    /// `EVIDENCE/est-r1/FINDINGS.md`):
    ///
    ///     width  = min(容器宽, 580)
    ///     lines  = Σ 每个块的显示行数（每块封顶 15）
    ///     height = max(lines × 行高 × 0.9, 44)
    ///
    /// Cheap by design — line widths come from `size(withAttributes:)`, never
    /// TextKit — and only serves a Code row no cell has measured yet. The
    /// structural `CodeRowHeightPlan` still wins whenever it has an answer.
    /// The tool branch's per-segment inner estimate is UNKNOWN; one line per
    /// segment is the conservative floor (block cap 15 applies).
    func officialEstimateHeight(for item: TimelineListItem, width: CGFloat) -> CGFloat? {
        officialEstimateHeight(for: item, width: width, drawnTexts: nil)
    }

    /// The same official estimate, fed with the text each block actually
    /// draws. A live row draws its published snapshot (or the retained
    /// completion snapshot), not the persisted fallback, so the first-frame
    /// seed must measure the drawn text (P1-5).
    private func officialEstimateHeight(for item: TimelineListItem, width: CGFloat,
                                        drawnTexts: [String: String]?) -> CGFloat? {
        guard case .group(let id) = item, groupsByID[id]?.explicitID != nil,
              let rows = codeRowsByGroupID[id], !rows.isEmpty, width > 0 else {
            return nil
        }
        let cappedWidth = min(width, TimelineHeightEstimate.officialWidthCap)
        let lineCap = TimelineHeightEstimate.officialLineCap
        let font = UIFont.systemFont(ofSize: max(1, codeTypography.body))
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var lines: CGFloat = 0
        // [I] The official estimator counts text lines; an attachment grid has
        // no line count. Adding the structural grid height keeps the seed from
        // parking a 150–288 pt block on a row whose first frame would then
        // collapse under the reader's finger.
        var attachmentHeight: CGFloat = 0
        var hasContent = false
        for row in rows {
            for block in row.blocks {
                switch block {
                case .reasoning:
                    continue
                case let .text(id, fallback):
                    let text = drawnTexts?[id] ?? fallback
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    hasContent = true
                    var blockLines: CGFloat = 0
                    for line in trimmed.split(separator: "\n",
                                               omittingEmptySubsequences: false) {
                        let lineWidth = (String(line) as NSString)
                            .size(withAttributes: attributes).width
                        blockLines += floor(lineWidth / cappedWidth) + 1
                    }
                    lines += min(blockLines, lineCap)
                case let .toolCalls(segments):
                    hasContent = true
                    lines += min(CGFloat(segments.count), lineCap)
                case let .attachments(_, files, _):
                    hasContent = true
                    attachmentHeight += CodeAttachmentLayout.blockHeights(
                        files: files, pixelSize: attachmentPixelSize).reduce(0, +)
                case .other:
                    hasContent = true
                    lines += 1
                }
            }
        }
        guard hasContent else { return nil }
        let lineHeight = max(1, codeTypography.body + codeTypography.lineSpacing)
        return TimelineHeightEstimate.officialEstimate(lines: lines, lineHeight: lineHeight)
            + attachmentHeight
    }

    /// Parsed Markdown for the Code row's first frame, keyed by the text digest
    /// plus the typography revision. The same blocks feed the row view
    /// (`CodeMessageRowView.preparedBlocks`) and the height measurer, so the
    /// first frame is neither blank nor a different parse than the one that
    /// was measured. Parsing is synchronous by design: the cell must have its
    /// blocks before it configures, and the measurer's controller never enters
    /// a window (so an async `.task` would not run there).
    private var preparedMarkdownCache: [String: [MarkdownBlockSnapshot]] = [:]

    private func preparedMarkdownBlocks(for text: String) -> [MarkdownBlockSnapshot]? {
        let key = "\(ChatMarkdownPrepared.key(for: text)):\(typography.revision)"
        if let cached = preparedMarkdownCache[key] { return cached }
        guard let blocks = CodeMessageHeightMeasurer.preparedBlocks(for: text) else {
            return nil
        }
        if preparedMarkdownCache.count > 128 {
            preparedMarkdownCache.removeAll(keepingCapacity: true)
        }
        preparedMarkdownCache[key] = blocks
        return blocks
    }

    /// The blocks for every assistant text block of one Code message, keyed by
    /// the text the row will draw (a live streaming snapshot wins over the
    /// persisted block text, exactly as `CodeMessageRowView.displayedText`
    /// resolves it).
    private func preparedTextBlocks(for rows: [CodeMessageRow],
                                    streaming: CodeStreamingText?)
        -> [String: [MarkdownBlockSnapshot]]? {
        var prepared: [String: [MarkdownBlockSnapshot]] = [:]
        for row in rows where row.role != .user {
            for block in row.blocks {
                guard case let .text(id, fallback) = block else { continue }
                let text = streaming?.text(for: id) ?? fallback
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                let key = ChatMarkdownPrepared.key(for: text)
                if prepared[key] != nil { continue }
                if let blocks = preparedMarkdownBlocks(for: text) {
                    prepared[key] = blocks
                }
            }
        }
        return prepared.isEmpty ? nil : prepared
    }

    /// The exact height of a settled Code group, measured before the snapshot
    /// applies. The controller needs this because the Code page hosts every
    /// message itself: the TextKit document path below is never offered a Code
    /// row, so without this hook the layout starts every group on an estimate
    /// and corrects it when the cell first becomes visible.
    ///
    /// Text blocks and the user bubble are measured by hosting the real
    /// `ChatMarkdownView` / `CodeUserBubble` (`CodeMessageHeightMeasurer`), so
    /// the stored height is the height the cell draws. A live group is
    /// skipped: hosting the growing text on every 0.1 s flush would be
    /// quadratic, and its estimate is only visible while the reader is
    /// watching the streaming row.
    /// Code message rows and standalone rows follow the official hosted-cell
    /// contract: the cell self-measures once and reports later content changes.
    /// Only the compaction divider keeps the legacy preferred-fit path.
    func usesCellReportedHeight(for item: TimelineListItem) -> Bool {
        if case .workingStatus = item { return true }
        guard case .group(let id) = item, let group = groupsByID[id] else { return false }
        // A standalone row draws the Code message / tool rows and the
        // turn-scoped footers, so its height follows content no estimate can
        // predict. Left on the legacy Chat preferred-fit path its first fit
        // latched `isMeasured` and nothing ever asked the cell again: a row
        // that outlived a shrink kept the old, taller frame and painted blank
        // space under its content until a scroll re-fit it (pp 2026-11-16:
        // 「中间空了一大截，滑一下就落下来」). The cell's own geometry report
        // is what keeps that class of row honest.
        if group.explicitID == nil, group.isStandaloneCompactDivider {
            // The compaction divider declares an exact fixed height and was
            // tuned on the preferred-height path; it keeps it.
            return false
        }
        return true
    }

    func measuredCodeGroupHeight(for item: TimelineListItem, width: CGFloat) -> CGFloat? {
        guard case .group(let id) = item,
              let group = groupsByID[id], group.explicitID != nil,
              let rows = codeRowsByGroupID[id] else { return nil }
        // A live Code group has no exact structural height: hosting the
        // growing body on every publish would be quadratic. A group still
        // drawing a retained completion snapshot is the same shape (the
        // persisted text does not cover what the row draws yet). Both answer
        // with the official line-count estimate, purely as the first-frame
        // seed (P1-5). A row that only finished its TextKit reveal keeps the
        // old contract and answers nil.
        if group.rows.contains(where: { $0.value.isStreamingText })
            || group.rows.contains(where: { codeCompletedStreamingTexts[$0.id] != nil })
            || group.rows.contains(where: { codePendingReplays[$0.id] != nil }) {
            // A settled message replaying after a return draws the revealed
            // prefix, not its persisted full text. Measuring the full text
            // here made the layout reserve 934 pt for a row the cell was about
            // to draw 40 pt tall, and the correction collapsed the list by
            // 894 pt on the way back (b1735 `timeline.row.height` 05:39:04).
            return streamingSeedHeight(for: item, groupID: id, width: width)
        }
        guard !group.rows.contains(where: { $0.isRevealing }) else {
            return nil
        }
        let hasActionBar = actionBarCopyText(for: id) != nil
        let noticeExtra = interruptedNoticeExtraHeight(for: id)
        let digest = codeHeightDigest(rows: rows, width: width,
                                      hasActionBar: hasActionBar,
                                      hasInterruptedNotice: noticeExtra > 0)
        if let cached = codeHeightCache[id], cached.digest == digest {
            return cached.height
        }
        let height = CodeMessageHeightMeasurer.height(
            rows: rows,
            width: width,
            typography: codeTypography,
            traits: controller?.traitCollection,
            measured: true,
            hasActionBar: hasActionBar,
            pixelSize: attachmentPixelSize) + noticeExtra
        codeHeightCache[id] = CachedCodeHeight(digest: digest, height: height)
        return height
    }

    /// First-frame seed for a live Code group (P1-5).
    ///
    /// The official estimator is `max(Σ lines × lineHeight × 0.9, 44)` over
    /// the first 4000 characters, capped at 580 pt wide and 15 lines per block
    /// (`EVIDENCE/est-r1/FINDINGS.md`, CANONICAL/05-layout-scroll.md §2). It is
    /// the value the official placeholder row shows before its one geometry
    /// report. `CodeProfileAutoRun`'s 461 probe recorded the first fit
    /// collapsing a streaming row 44 → 18 because the cell got no seed and
    /// fitted the pre-layout skeleton.
    ///
    /// This is a seed, not a measurement: for a never-displayed cell-reported
    /// row the controller records it in the `.provisional` tier
    /// (`measureSynchronously`) and the cell's first
    /// `preferredLayoutAttributesFitting` returns it instead of fitting the
    /// skeleton. If UIKit accepts that first fit, the same value becomes the
    /// row's first stored height; either way the next geometry report replaces
    /// it with the real cell fit (`applyMeasuredHeight`, changed-only).
    private func streamingSeedHeight(for item: TimelineListItem,
                                     groupID: String,
                                     width: CGFloat) -> CGFloat? {
        // Estimate the text the row draws right now. The revealed prefix, not
        // the publisher's full text: a seed from characters the cursor has not
        // painted yet would make the first fit too tall and the cell correct
        // downward, which is visible. A row with no sampled text falls back to
        // its persisted block text.
        var drawnTexts: [String: String] = [:]
        var hasPendingReplay = false
        for row in groupsByID[groupID]?.rows ?? [] {
            if codePendingReplays[row.id] != nil { hasPendingReplay = true }
            if let revealed = codeRevealedTexts[row.id] {
                // An empty prefix is a real drawn state for a pending replay;
                // keeping it stops the seed from sizing the row for the full
                // text the cursor has not painted yet.
                if !revealed.isEmpty || codePendingReplays[row.id] != nil {
                    drawnTexts[row.id] = revealed
                }
            } else if let completed = codeCompletedStreamingTexts[row.id] {
                drawnTexts[row.id] = completed
            }
        }
        guard let estimate = officialEstimateHeight(
            for: item, width: width,
            drawnTexts: drawnTexts.isEmpty ? nil : drawnTexts) else {
            // A pending replay can legitimately draw an empty prefix (the
            // message arrived while away and the lag window starts at 0). The
            // row exists but draws nothing yet: seed the official floor here.
            // Returning nil made the layout fall back to `estimateKind`, which
            // sizes the persisted full text — the 934 pt row that collapsed to
            // 40 pt on return (b1735 `timeline.row.height` 05:39:04).
            guard hasPendingReplay else {
                // No text yet: the official `.streamingText` row does not
                // exist before the first non-empty block
                // (CANONICAL/03-streaming.md §8.1).
                return nil
            }
            return TimelineHeightEstimate.officialMinimum
                + interruptedNoticeExtraHeight(for: groupID)
        }
        // A row that was measured before (reconnect/recovery re-streams the
        // same message) never seeds below the height the reader last saw.
        let previous = codeHeightCache[groupID]?.height ?? 0
        return max(estimate + interruptedNoticeExtraHeight(for: groupID), previous)
    }

    /// Height the interrupted-turn notice adds to a message row: the card plus
    /// the row stack's inter-block spacing. Zero outside the chat profile and
    /// away from the stopped turn's anchor.
    private func interruptedNoticeExtraHeight(for groupID: String) -> CGFloat {
        guard renderMode == .steps,
              chatInterruptedItemIDs.contains(
                TimelineListItem.group(groupID).itemID) else { return 0 }
        return ChatInterruptedNoticeCard.estimatedHeight + CodePageTheme.interMessageSpacing
    }

    private struct CachedCodeHeight {
        let digest: Int
        let height: CGFloat
    }
    private var codeHeightCache: [String: CachedCodeHeight] = [:]

    private func codeHeightDigest(rows: [CodeMessageRow],
                                  width: CGFloat,
                                  hasActionBar: Bool = false,
                                  hasInterruptedNotice: Bool = false) -> Int {
        var hasher = TimelineStableHasher()
        for row in rows {
            hasher.combine(row.role.rawValue)
            for block in row.blocks {
                switch block {
                case let .reasoning(_, text, status, _):
                    // The row's height is one fixed line; only "settled and
                    // non-empty" changes whether it exists at all.
                    hasher.combine(status == .done
                        && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 1 : 0)
                case let .text(_, text):
                    hasher.combine(1)
                    hasher.combine(text)
                case let .toolCalls(segments):
                    hasher.combine(2)
                    hasher.combine(segments.count)
                case let .attachments(_, files, clientMessageID):
                    // The drawn tile boxes depend on the resolved pixel sizes,
                    // so a preview that lands after the wire payload must
                    // retire the measured height.
                    hasher.combine(4)
                    for signature in attachmentSignatures(files, clientID: clientMessageID) {
                        hasher.combine(signature.id)
                        hasher.combine(signature.pixelWidth ?? 0)
                        hasher.combine(signature.pixelHeight ?? 0)
                    }
                case .other:
                    hasher.combine(3)
                }
            }
        }
        hasher.combine(TimelineHeightKey.quantize(width))
        hasher.combine(codeTypography.revision)
        let scale = controller?.traitCollection.displayScale ?? 2
        hasher.combine(Int((scale * 100).rounded()))
        hasher.combine(hasActionBar)
        hasher.combine(hasInterruptedNotice)
        return hasher.revision
    }

    /// The estimate is recomputed only when the row content, typography or
    /// column width changes. `prepare` asks for it for every row on every
    /// layout, so the cache key uses the already-computed content signature
    /// rather than walking the row text again.
    private func textEstimate(for item: TimelineListItem,
                              rows: [TimelineHeightEstimate.TextRow],
                              minimum: CGFloat) -> CGFloat {
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        var hasher = TimelineStableHasher()
        hasher.combine(contentSignature(for: item).contentRevision)
        hasher.combine(minimum)
        hasher.combine(typography.revision)
        hasher.combine(width)
        let cacheKey = "\(hasher.revision)"
        if let cached = estimateCache[cacheKey] { return cached }
        let height = TimelineHeightEstimate.height(rows: rows, width: width,
            bodySize: typography.body, lineSpacing: typography.lineSpacing,
            paragraphSpacing: typography.paragraphSpacing, minimum: minimum)
        estimateCache[cacheKey] = height
        return height
    }

    func heightPolicy(for item: TimelineListItem) -> TimelineRowHeightPolicy {
        switch item {
        case .tail: return .tail
        // Official Code rows never animate a height change; the old
        // `.interactive` policy eased notice/pending rows over 0.18 s.
        case .notice, .pending: return .measured
        case .group(let id):
            guard let group = groupsByID[id] else { return .measured }
            // A Code message row is measured before apply and owned by the
            // layout: every part of its height is known. Letting it self-size
            // made UIKit ask for preferred attributes on every scroll and
            // routed it through the interactive correction path.
            if group.explicitID != nil { return .measured }
            return groupHasInteractiveContent(group) ? .interactive : .measured
        case .olderPrompt, .latestPrompt, .workingStatus: return .measured
        }
    }

    /// Code message, notice and pending rows draw the official top/bottom
    /// 5 pt margins themselves, so the list must not add its historical 20 pt
    /// gap. Without the pair, a pending bubble sat 5 pt under the previous
    /// Code row and 25 pt above the next one (review 2026-10-23).
    func itemSpacing(after item: TimelineListItem) -> CGFloat {
        switch item {
        // A group answers for itself: message and step rows carry 5 pt row
        // margins and the compaction divider carries its own 16 pt padding,
        // so none of them also pay the list gap (see `listSpacing`).
        case .group(let id): return groupsByID[id]?.listSpacing ?? TimelineListMetrics.itemSpacing
        // The official paging sentinel adds no bottom gap (`paging` group
        // returns 0.0, CANONICAL/05-layout-scroll.md:149); the row above it
        // already carries its own margin.
        case .olderPrompt, .workingStatus, .notice, .pending: return 0
        default: return TimelineListMetrics.itemSpacing
        }
    }

    // MARK: - C5/M3 TextKit 2 assistant body

    private struct CachedAssistantDocument {
        let revision: Int
        let text: String
        let typographyRevision: Int
        let document: AssistantMarkdownDocument?
    }

    private var assistantDocuments: [String: CachedAssistantDocument] = [:]

    /// Streaming documents are rebuilt per revision but only parsed to the new
    /// tail; the cache keeps the measurement and the cell configuration in one
    /// apply from doing the work twice.
    private struct CachedStreamingDocument {
        let revision: Int
        let typographyRevision: Int
        let text: String
        let document: AssistantStreamingDocument?
    }
    private var streamingDocuments: [String: CachedStreamingDocument] = [:]
    private var streamingBuilders: [String: AssistantStreamingDocumentBuilder] = [:]
    /// Per-row reveal timelines. They live here, not in the cell, so scrolling
    /// a cell away and back does not restart the cursor.
    private var revealTimelines: [String: StreamingRevealTimeline] = [:]
    /// Per-row progress for the Code page's streaming text snapshots. The
    /// official Chat page's `RevealDriver` is owned by the content model and
    /// only advances while the page is on screen; this is its AA counterpart
    /// (CANONICAL/29 §18). Keyed by the wire row id, so a message with several
    /// live text rows keeps one cursor per block.
    private var codeRevealCursors: [String: StreamingRevealCursor] = [:]
    /// Revealed text per row for the current refresh. `codeStreamingTexts` is
    /// read several times in one pass (height key, signature, cell configure);
    /// sampling once per refresh keeps every read of the pass identical.
    private var codeRevealedTexts: [String: String] = [:]
    /// Rows whose cursor is still behind its text in this refresh.
    private var codeRevealBehindRowIDs: Set<String> = []
    /// Characters still owed across those rows (diagnostics + pump bound).
    private var codeRevealBacklog = 0
    /// Bumped whenever a row's revealed prefix changes. The streaming row's
    /// content signature uses it: a cursor advancing between publisher
    /// snapshots changes what is drawn even though `publishRevision` stands
    /// still, and without this the collection would skip the apply.
    private var codeRevealRevisions: [String: Int] = [:]
    /// True from the moment the page hides until a sample runs after it is
    /// visible again: rows first seen in this window replay their lag-budget
    /// tail even when they are already settled (a message that arrived while
    /// away; CANONICAL/29 §20).
    private var codeRevealResuming = false
    /// Row ids present at the last sample. A settled row that was already in
    /// the window before the page hid is **seen** text: it must not become a
    /// pending replay on return (pp 2026-11-27: 18 old messages replayed,
    /// backlog 9698).
    private var codeKnownRowIDs: Set<String> = []
    /// False until the adapter has sampled at least once with the page on
    /// screen. A page built while hidden shows its existing rows whole; only
    /// a page the reader actually saw can distinguish "new while away".
    private var hasSampledCodeRevealWhileVisible = false
    /// Settled assistant texts that first appeared while the page was off
    /// screen. They keep a reveal source until the cursor catches up; without
    /// this a message that finished during the switch has no publisher and
    /// would flash its whole body on return.
    private var codePendingReplays: [String: String] = [:]
    /// A hidden tab page freezes the reveal; a visible one advances it.
    private var pageRevealVisible = true
    /// Called once per refresh while the reveal is still behind: nothing else
    /// re-renders the page once the wire goes quiet, so the page pumps
    /// refreshes until the cursor catches up.
    var onRevealPending: (() -> Void)?

    var hasPendingReveal: Bool { !codeRevealBehindRowIDs.isEmpty }
    var revealBehindRowCount: Int { codeRevealBehindRowIDs.count }
    var revealBacklogCharacters: Int { codeRevealBacklog }
    /// First moment the renderer-owned cursor caught up. Kept briefly so the
    /// cell's final run and fade can finish before the static body takes over.
    private var revealCaughtUpAt: [String: TimeInterval] = [:]
    /// Rows whose renderer-owned reveal is still running. The cell driver
    /// clears this through `streamingRevealDidFinish` after the final fade;
    /// the signature includes it so the completion triggers one more apply
    /// (footer install + measured static height).
    private var rendererRevealOwnership = StreamingRevealOwnership()
    /// Rows whose stream contained a block the TextKit path cannot render stay
    /// on the hosting path for the rest of the turn. Flipping engines mid-stream
    /// would be a visible jump.
    private var streamingFallbacks: Set<String> = []
    /// Row ids whose wire row currently carries live streaming text. Fed by
    /// `updateCodeStreaming`, which already walks the rendered groups; the
    /// refresh used to scan every held row (~2,900) for this flag, 12.6 ms per
    /// stream tick on the 2026-11-25 probe.
    private var liveStreamingRowIDs: Set<String> = []

    /// The TextKit path only takes a static assistant message: one row, no
    /// fold, no inline notice, no attachments, no streaming. A turn footer is
    /// allowed when its height is a constant (M3.1 action row, M4.3 file
    /// summary). Any block the parser does not render still makes the whole
    /// row return nil.
    ///
    /// W7: the Code page hosts every message itself (`CodeMessageRowView` in
    /// the hosting cell), so the controller is never offered a TextKit
    /// document. The C3/M4 gates keep exercising this path through their own
    /// independent providers (`TimelineAutoRun`, `TextKitM4*AutoRun`); the
    /// machinery below stays compiled for the mixed-row phase.
    func assistantMarkdown(for item: TimelineListItem) -> AssistantMarkdownDocument? {
        nil
    }

    /// The streaming counterpart of `assistantMarkdown`. W7 hands the live
    /// body to `CodeMessageRowView` + W6's whole-snapshot publisher instead (no
    /// character reveal, full-text snapshots), so the TextKit streaming cell
    /// is not offered either.
    func assistantStreamingDocument(for item: TimelineListItem) -> AssistantStreamingDocument? {
        nil
    }

    func assistantStreamingReveal(for item: TimelineListItem) -> StreamingRevealState? {
        // Official gating: VoiceOver bypasses the pacing provider entirely and
        // Reduce Motion skips the mask driver; both show the text at once.
        guard isRevealEnabled else { return nil }
        guard let row = streamingRow(for: item),
              let cached = streamingDocuments[row.id],
              let document = cached.document else { return nil }
        let total = document.document.revealCharacterCount
        let now = ProcessInfo.processInfo.systemUptime
        var timeline = revealTimelines[row.id] ?? StreamingRevealTimeline()
        if timeline.total != total {
            timeline.retarget(total: total, at: now)
            revealTimelines[row.id] = timeline
        }
        return StreamingRevealState(
            timeline: timeline, total: total,
            isTextComplete: !row.value.isStreamingText)
    }

    /// Anchor the reveal cursor on the rendered character total. The official
    /// controller retargets when content changes; already-shown characters
    /// never move backwards.
    private func anchorRevealTimeline(for row: ChatTimelineRowModel,
                                      document: AssistantStreamingDocument) {
        guard isRevealEnabled else {
            revealTimelines.removeValue(forKey: row.id)
            revealCaughtUpAt.removeValue(forKey: row.id)
            rendererRevealOwnership.finish(row.id)
            return
        }
        let total = document.document.revealCharacterCount
        let now = ProcessInfo.processInfo.systemUptime
        var timeline = revealTimelines[row.id] ?? StreamingRevealTimeline()
        guard timeline.total != total else {
            if total > 0 { rendererRevealOwnership.begin(row.id) }
            return
        }
        timeline.retarget(total: total, at: now)
        revealTimelines[row.id] = timeline
        if total > 0 { rendererRevealOwnership.begin(row.id) }
        if timeline.shownThrough(at: now) >= total {
            revealCaughtUpAt[row.id] = revealCaughtUpAt[row.id] ?? now
        } else {
            revealCaughtUpAt.removeValue(forKey: row.id)
        }
    }

    /// A streaming assistant text row that the TextKit cell can own. The row
    /// stays eligible through the final reveal batch (`status == .done` with
    /// `isRevealing == true`), so committing does not flash through a fresh
    /// hosting view; once the reveal settles it hands over to `assistantMarkdown`.
    /// A row that stops streaming clears its builder; a row that gained an
    /// unsupported block keeps its fallback for the rest of the turn.
    private func streamingRow(for item: TimelineListItem) -> ChatTimelineRowModel? {
        guard case .group(let id) = item, let group = groupsByID[id],
              let row = group.rows.first else { return nil }
        let isAssistantMessage: Bool
        if case .message = row.value.content, row.value.role == .assistant {
            isAssistantMessage = true
        } else {
            isAssistantMessage = false
        }
        let now = ProcessInfo.processInfo.systemUptime
        // While the renderer-owned reveal still owns the row, a notice or a
        // footer arriving mid-stream must not switch engines: the full text
        // is already published, so the hosting path would show all of the
        // remaining characters at once. Hand off after the reveal settles.
        let holdsEngine = isRevealEnabled
            && rendererRevealOwnership.isActive(row.id)
        let admitted = TimelineStreamingEligibility.admits(
            isSingleRowGroup: group.kind == .single && group.rows.count == 1,
            isAssistantMessage: isAssistantMessage,
            isStreamingText: row.value.isStreamingText,
            isRevealing: row.isRevealing,
            isRevealPending: revealPending(for: row, at: now),
            textIsEmpty: row.text.isEmpty,
            hasInlineNotice: inlineNoticesByRow[row.id] != nil,
            hasAttachments: !attachments(of: row.value).isEmpty,
            isFallback: streamingFallbacks.contains(row.id),
            holdsEngineThroughDisqualifiers: holdsEngine)
        guard admitted else {
            // Only a row that left streaming (and finished both reveals)
            // discards its incremental state; a temporary notice/attachment
            // keeps it.
            if !row.value.isStreamingText && !row.isRevealing
                && !revealPending(for: row, at: now) {
                streamingDocuments.removeValue(forKey: row.id)
                streamingBuilders.removeValue(forKey: row.id)
                streamingFallbacks.remove(row.id)
                revealTimelines.removeValue(forKey: row.id)
                revealCaughtUpAt.removeValue(forKey: row.id)
                rendererRevealOwnership.finish(row.id)
            }
            return nil
        }
        // Once the TextKit reveal owns the row, the presentation publishes the
        // full received text and the cursor decides what is visible. The
        // adapter reads happen inside the SwiftUI update; switch on the next
        // runloop turn so the observable row is not mutated mid-update.
        if !row.rendererOwnedReveal {
            DispatchQueue.main.async {
                row.useRendererOwnedReveal()
            }
        }
        return row
    }

    /// VoiceOver and Reduce Motion both bypass the reveal (official: the
    /// pacing provider returns nil / the driver is not created).
    private var isRevealEnabled: Bool {
        !UIAccessibility.isVoiceOverRunning
            && !UIAccessibility.isReduceMotionEnabled
    }

    /// True while the renderer-owned cursor is still behind the received text,
    /// or during the short grace that lets the cell's final run fade out.
    private func revealPending(for row: ChatTimelineRowModel,
                               at now: TimeInterval) -> Bool {
        guard isRevealEnabled,
              rendererRevealOwnership.isActive(row.id) else { return false }
        guard let timeline = revealTimelines[row.id], timeline.total > 0 else {
            rendererRevealOwnership.finish(row.id)
            return false
        }
        if timeline.shownThrough(at: now) < timeline.total {
            revealCaughtUpAt.removeValue(forKey: row.id)
            return true
        }
        // The formula caught up; keep the row until the cell driver reports
        // that the final run and fade finished. The fallback bounds a driver
        // that never reports (its cell scrolled away).
        let caught = revealCaughtUpAt[row.id] ?? now
        revealCaughtUpAt[row.id] = caught
        if now - caught > 1.5 {
            rendererRevealOwnership.finish(row.id)
            return false
        }
        return true
    }

    /// The cell finished the final fade for this item's streaming row. Drop
    /// the reveal ownership so the next apply measures and configures the
    /// static body (which is what installs the copy/timestamp footer).
    func streamingRevealDidFinish(for item: TimelineListItem) {
        guard case .group(let id) = item, let group = groupsByID[id],
              let row = group.rows.first else { return }
        guard rendererRevealOwnership.finish(row.id) else { return }
        revealCaughtUpAt.removeValue(forKey: row.id)
        forceRefresh()
    }

    // MARK: - Turn action bar

    /// The Code page's turn action bar is a separate transcript row drawn inside
    /// the Code message row. A generic runtime is a plain chat session, not a
    /// Code page.
    private var usesCodeActionBar: Bool { codeProfile.family != .generic }

    /// The turn action bar is drawn inside the Code row (hosted cells do not
    /// receive an assistant footer). Only the group that ends a finished turn
    /// has an action; an empty copy text draws no bar.
    private func actionBarCopyText(for groupID: String) -> String? {
        guard usesCodeActionBar,
              let text = turnActions[groupID]?.copyText,
              !text.isEmpty else { return nil }
        return text
    }

    func measurementContent(for item: TimelineListItem) -> TimelineMeasurementContent {
        switch item {
        case .tail: return .tail
        case .notice, .pending: return .interactive
        case .group(let id):
            guard let group = groupsByID[id] else { return .markdown }
            return groupHasInteractiveContent(group) ? .interactive : .markdown
        case .olderPrompt, .latestPrompt, .workingStatus: return .plainText
        }
    }

    /// Width-less entry kept for the protocol and the offscreen measurer.
    func rowView(for item: TimelineListItem) -> AnyView {
        rowView(for: item, width: 0)
    }

    func rowView(for item: TimelineListItem, width: CGFloat) -> AnyView {
        switch item {
        case .olderPrompt:
            return AnyView(TimelineCollectionOlderPromptRow(
                isLoading: isLoadingOlder || isLoadingLatest))
        case .latestPrompt:
            return AnyView(TimelineCollectionLatestPromptRow(
                hasNewerItems: model.session.hasNewerItems,
                isLoading: isLoadingLatest || isLoadingOlder,
                pullReady: latestPullReady,
                onLoad: { [weak self] in self?.onLoadLatest?() }))
        case .workingStatus:
            // Official 0.4 s exit group animation: while the row is leaving,
            // it stays mounted with `isRunning = false`
            // (CANONICAL/20-working-mark.md §6). The flag goes through an
            // observable box so the mounted `WorkingMarkView` is updated in
            // place; a reconfigure would recreate it already exited.
            return AnyView(WorkingStatusRowHost(state: workingStatusExitState,
                                                usesChatWorkingStyle: renderMode == .steps))
        case .group(let id):
            guard let group = groupsByID[id] else { return AnyView(EmptyView()) }
            // The chat profile's step-group row: one line that follows the
            // group's current step while it runs and settles into the counts
            // summary.
            if let stepGroup = stepGroupsByID[id] {
                let cwd = model.session.metadata?.cwd
                let isLiveTail = id == chatLiveTailGroupID
                // Only the groups of the actively streaming turn may animate a
                // step that still reports `running`. A previous turn's group —
                // e.g. one holding a background subagent that outlives the
                // turn — must stay on its settled row (icon + sweep), never
                // re-draw the working mark when a new turn starts (pp
                // 2026-11-19: the icon flashed the dots and reverted).
                let allowsPose = chatRunningPoseGroupIDs.contains(stepGroup.id)
                // Probe for the intermittent "a stopped turn still drew the
                // working pose" report (device 2026-11-14, fixed then; kept as
                // a tripwire because it was layout-dependent). One diagnostics
                // line per group per window when the pose is drawn while the
                // turn is not streaming — the reader has that file only.
                if !model.isTranscriptStreaming,
                   stepGroup.showsRunningPose(
                        isLiveTail: isLiveTail,
                        isMarkOwner: id == chatMarkOwnerGroupID,
                        allowsRunningPose: allowsPose) {
                    ClientDiagnosticsLog.shared.record(
                        kind: "timeline.step.pose_after_stop",
                        sessionID: model.session.id,
                        detail: [
                            "group": stepGroup.id,
                            "liveTail": isLiveTail ? "1" : "0",
                            "allowsPose": allowsPose ? "1" : "0",
                            "fresh": model.session.runtime.isFresh ? "1" : "0",
                            "stopRequested": model.session.runtime.stopRequested ? "1" : "0",
                            "predictedIdle": model.session.runtime.predictedIdle ? "1" : "0",
                            "status": String(describing: model.session.runtime.state?.status),
                            "steps": String(stepGroup.steps.count),
                        ])
                }
                // A group from the running turn opens at its newest step too:
                // the gap between two steps has nothing running, and a group
                // that body text follows is still the turn's work
                // (pp 2026-11-10).
                return AnyView(CodeStepGroupRowView(group: stepGroup, cwd: cwd,
                                                    isLiveTail: isLiveTail,
                                                    isMarkOwner: id == chatMarkOwnerGroupID,
                                                    allowsRunningPose: allowsPose,
                                                    treatsRunningAsFailed: model.treatsRunningStepsAsFailed,
                                                    showsInterruptedNotice:
                                                        chatInterruptedItemIDs.contains(
                                                            TimelineListItem.group(stepGroup.id).itemID),
                                                    interruptedAgentName: model.agentName) { [weak self] in
                    self?.onCodeStepGroupDetail?(CodeStepGroupDetailRequest(
                        group: stepGroup,
                        startsAtBottom: self?.stepDetailStartsAtBottom(id) ?? false))
                })
            }
            // A message group (declared message id) renders through the Code
            // row; a single-row group is either an interaction target or a row
            // with no message key and keeps the existing renderer.
            if group.explicitID != nil {
                let streamingText = codeStreamingTexts(for: item)
                // Capture the model itself, not `self`: the escaping closures
                // live in the cell's hosted view and must not keep the
                // adapter (and its controller) alive.
                let chatModel = model
                return AnyView(CodeMessageRowView(
                    group: group,
                    profile: codeProfile,
                    cwd: model.session.metadata?.cwd,
                    streaming: streamingText,
                    typography: codeTypography,
                    columnWidth: width,
                    turnActionCopyText: actionBarCopyText(for: id),
                    showsInterruptedNotice: renderMode == .steps
                        && chatInterruptedItemIDs.contains(
                            TimelineListItem.group(group.id).itemID),
                    interruptedAgentName: model.agentName,
                    onToolDetail: { [weak self] request in
                        self?.onCodeToolDetail?(request)
                    },
                    onThinkingDetail: { [weak self] request in
                        var request = request
                        // The live detail follows the tail like the step sheet:
                        // the turn is running and this row belongs to it.
                        let lastUserOrder = chatModel.session.timeline.last {
                            $0.value.startsVisibleTurn
                        }?.value.orderSeq
                        if let lastUserOrder,
                           let row = chatModel.session.timeline.first(where: { $0.id == request.id }) {
                            request.startsAtBottom = chatModel.isRunning
                                && row.value.orderSeq > lastUserOrder
                        }
                        self?.onCodeThinkingDetail?(request)
                    },
                    attachmentResolver: { contents, clientID in
                        chatModel.session.attachmentPreviews.resolve(contents,
                                                                     clientID: clientID)
                    },
                    attachmentState: { _ in .complete },
                    loadThumbnail: { file in
                        try await chatModel.thumbnail(for: file)
                    },
                    onAttachment: onAttachment,
                    onOpenLink: onOpenLink))
            }
            // A group with no declared message key is one standalone row
            // (compaction divider, marker, artifact, interaction anchor). The
            // Code-side fallback draws it; the retired Chat group container —
            // whose only caller this was — is gone.
            return AnyView(CodeStandaloneRowView(
                group: group,
                chat: model,
                profile: codeProfile,
                onAttachment: onAttachment,
                onFile: onFile,
                onOpenLink: onOpenLink,
                inlineNotices: group.rows.flatMap { inlineNoticesByRow[$0.id] ?? [] },
                showsInterruptedNotice:
                    chatInterruptedItemIDs.contains(
                        TimelineListItem.group(group.id).itemID),
                onToolDetail: { [weak self] request in
                    self?.onCodeToolDetail?(request)
                },
                onThinkingDetail: { [weak self] request in
                    self?.onCodeThinkingDetail?(request)
                }))
        case .notice(let id):
            guard let notice = tailNoticesByID[id] else { return AnyView(EmptyView()) }
            // The same row margins as a Code message row: these rows report 0
            // list gap, so their own margins are the whole inter-row gap.
            return AnyView(SessionInteractionCard(item: notice, chat: model)
                .padding(.vertical, CodePageTheme.rowMarginTop))
        case .pending(let id):
            guard let pending = pendingByID[id] else { return AnyView(EmptyView()) }
            return AnyView(PendingMessageRow(pending: pending, chat: model,
                onAttachment: onAttachment,
                onDismiss: { [weak self] in self?.model.session.dismissPendingMessage(id: id) },
                onRetry: { [weak self] in
                    guard let self else { return }
                    Task { await self.model.retryPendingMessage(pending) }
                })
                .padding(.vertical, CodePageTheme.rowMarginTop))
        case .tail:
            return AnyView(TimelineCollectionTailRow(model: model,
                                                     onAttachment: onAttachment,
                                                     showsStatusLine: tailStatusLineVisible))
        }
    }

    // MARK: - Code streaming (W6 publisher)

    /// The published text per live row of this message, plus the last
    /// completed snapshot while the persisted text has not covered it yet.
    ///
    /// The official row publishes a whole snapshot per block on the 0.1 s
    /// leading-edge throttle (CANONICAL/03-streaming.md §5.1); a message with
    /// several live text rows therefore has one snapshot per row. Keying by
    /// row id is why this is a map and not "the group's last streaming row"
    /// (P2-11); `CodeMessageRowView.displayedText` substitutes only the block
    /// whose id matches.
    func codeStreamingTexts(for item: TimelineListItem) -> CodeStreamingText? {
        guard case .group(let id) = item, let group = groupsByID[id] else { return nil }
        var texts: [String: String] = [:]
        for row in group.rows {
            // The revealed prefix was sampled once in `updateCodeStreaming`;
            // this pass must reuse it so the height key, the signature and
            // the cell all draw the same characters. A pending replay keeps
            // its (possibly empty) prefix: falling back to the persisted full
            // text would flash the whole answer before the first character is
            // revealed.
            if let revealed = codeRevealedTexts[row.id],
               !revealed.isEmpty || codePendingReplays[row.id] != nil {
                texts[row.id] = revealed
            }
        }
        return texts.isEmpty ? nil : CodeStreamingText(textsByRowID: texts)
    }

    /// Feeds every in-flight assistant text row of a Code message group into
    /// its publisher and completes the ones that settled. Called once per
    /// refresh, which the wrapper triggers on every stream flush
    /// (`flushRevision`).
    ///
    /// The rows switch to renderer-owned reveal before feeding: the Chat
    /// page's batching (a 0.24 s reveal that withholds the last glyph) belongs
    /// to the reveal renderer, which the Code page does not use. With the row
    /// publishing its full received text, W6's 0.1 s leading-edge throttle is
    /// the data pacing layer; the per-row `StreamingRevealCursor` is the
    /// drawing layer on top (official progress paced, frozen off screen).
    /// The switch is deferred one runloop turn because `row` is observable and
    /// this refresh runs inside a SwiftUI update (same rule as the retired
    /// `streamingRow` path); the next flush then feeds the full text.
    private func updateCodeStreaming(groups: [ChatTimelineGroup]) {
        let now = CACurrentMediaTime()
        var rowsByID: [String: ChatTimelineRowModel] = [:]
        // Only explicit-key groups own the paced reveal; a standalone group is
        // drawn by `CodeStandaloneRowView` (its own pacing), so it must not be
        // switched to renderer-owned reveal.
        for group in groups where group.explicitID != nil {
            // Reasoning is drawn as the turn's single working row, not as
            // body text; feeding it through the publisher used to reconfigure
            // the whole Code row every 0.1 s for an invisible string.
            //
            // It still goes through the shared presentation flush, though, and
            // its legacy reveal batch moves `nextBatchAt` one Chat interval
            // (0.24 s + a frame) forward on every reasoning delta. That gate
            // paces the *whole* timeline, so the Code page's message text was
            // published once per 0.26 s (~6 lines at the fast model's rate)
            // even though its own rows are renderer-owned. Mark reasoning rows
            // renderer-owned too: the Code page never draws them as reveal
            // text, so nothing visible loses its animation.
            for row in group.rows where row.value.isReasoning
                && !row.rendererOwnedReveal {
                DispatchQueue.main.async {
                    row.useRendererOwnedReveal()
                }
            }
            for row in group.rows where !row.value.isReasoning
                && rowsByID[row.id] == nil {
                rowsByID[row.id] = row
            }
        }
        var liveStreaming: Set<String> = []
        for (rowID, row) in rowsByID {
            if row.value.isStreamingText {
                liveStreaming.insert(rowID)
                // A row that streams again must not keep an old completion
                // snapshot or a pending tail replay; the live publisher is
                // the only source now.
                codeCompletedStreamingTexts.removeValue(forKey: rowID)
                codeCompletedStreamingAt.removeValue(forKey: rowID)
                codePendingReplays.removeValue(forKey: rowID)
                if !row.rendererOwnedReveal {
                    DispatchQueue.main.async {
                        row.useRendererOwnedReveal()
                    }
                }
                var publisher = codeStreamingPublishers[rowID] ?? CodeStreamingPublisher()
                // Feed the received full text, not `row.text`: the legacy
                // reveal batches `row.text` with the final glyph withheld, and
                // the first flush used to publish that truncated text until
                // the next frame (P2-10). The official assembler snapshot is
                // the block's full text (CANONICAL/03-streaming.md §4.2).
                _ = publisher.receive(fullText: row.value.displayText, at: now)
                codeStreamingPublishers[rowID] = publisher
            } else if let publisher = codeStreamingPublishers[rowID] {
                // The row settled: publish the completion snapshot, then keep
                // it on screen until the persisted text covers it. The old
                // code dropped the snapshot, so the row jumped from the last
                // throttled text to the persisted full text (P1-2).
                // `complete()` is exempt from the 0.1 s throttle (§5.1).
                var completed = publisher
                // A hidden page's refreshes are parked, so the publisher may
                // never have received the text that arrived while it was off
                // screen. Feed the final text before completing: otherwise the
                // completion snapshot is a stale prefix, and the replay would
                // start from text that never reached the screen.
                _ = completed.receive(fullText: row.value.displayText, at: now)
                if let snapshot = completed.complete(at: now), !snapshot.text.isEmpty {
                    codeCompletedStreamingTexts[rowID] = snapshot.text
                    codeCompletedStreamingAt[rowID] = now
                }
                codeStreamingPublishers.removeValue(forKey: rowID)
            }
        }
        liveStreamingRowIDs = liveStreaming
        // A row that left the timeline (history page swap, recovery) stops
        // being fed immediately.
        codeStreamingPublishers = codeStreamingPublishers.filter { rowsByID[$0.key] != nil }
        codeRevealCursors = codeRevealCursors.filter { rowsByID[$0.key] != nil }
        codeRevealRevisions = codeRevealRevisions.filter { rowsByID[$0.key] != nil }
        codePendingReplays = codePendingReplays.filter { rowsByID[$0.key] != nil }
        sampleCodeReveal(rowsByID: rowsByID, now: ProcessInfo.processInfo.systemUptime)
        resolveCompletedStreamingTexts(rowsByID: rowsByID)
    }

    /// Sample every live text row's reveal cursor once per refresh and cache
    /// the revealed prefix `codeStreamingTexts` returns for the rest of the
    /// pass. While the page is hidden the clock is frozen, so the prefix does
    /// not move; on return it continues from the frozen count at the official
    /// 320/640 characters-per-second pacing.
    private func sampleCodeReveal(rowsByID: [String: ChatTimelineRowModel],
                                  now: TimeInterval) {
        var revealed: [String: String] = [:]
        revealed.reserveCapacity(rowsByID.count)
        var behind: Set<String> = []
        var backlog = 0
        let revealEnabled = isRevealEnabled
        // A row first seen in this window arrived while the page was off
        // screen; its older text paints at once and only the lag-budget tail
        // replays (official `longestLagSeconds` bound; CANONICAL/29 §20). The
        // flag survives hidden samples and is cleared by the first sample
        // taken with the page visible again.
        let resuming = codeRevealResuming || !pageRevealVisible
        for (rowID, row) in rowsByID {
            let source: String
            if let publisher = codeStreamingPublishers[rowID],
               !publisher.publishedText.isEmpty {
                source = publisher.publishedText
                codePendingReplays.removeValue(forKey: rowID)
            } else if let completed = codeCompletedStreamingTexts[rowID] {
                source = completed
            } else if let pending = codePendingReplays[rowID] {
                // The server can still be persisting the settled message;
                // follow the newest text while the replay is running.
                let latest = row.value.displayText
                let text = latest.isEmpty ? pending : latest
                if text != pending { codePendingReplays[rowID] = text }
                source = text
            } else if StreamingRevealReplayPolicy.shouldReplay(
                          isAssistantText: row.value.isAssistantText,
                          hasSampledVisible: hasSampledCodeRevealWhileVisible,
                          isKnownRow: codeKnownRowIDs.contains(rowID),
                          hasCursor: codeRevealCursors[rowID] != nil,
                          isResuming: resuming,
                          textEmpty: row.value.displayText.isEmpty) {
                // This message first appeared while the page was off screen
                // and is already settled (the turn finished during the
                // switch). It has no publisher, so the full text becomes the
                // replay source; without this it would flash whole on return.
                // A row that was already in the window before the hide is
                // seen text and must never enter this branch.
                source = row.value.displayText
                codePendingReplays[rowID] = source
            } else {
                continue
            }
            // VoiceOver and Reduce Motion bypass the reveal entirely
            // (official: the pacing provider returns nil / no driver), so
            // those readers always draw the full received snapshot.
            guard revealEnabled else {
                codeRevealCursors.removeValue(forKey: rowID)
                codePendingReplays.removeValue(forKey: rowID)
                revealed[rowID] = source
                continue
            }
            let firstSight = codeRevealCursors[rowID] == nil
            var cursor = codeRevealCursors[rowID] ?? StreamingRevealCursor()
            if firstSight, resuming {
                cursor.startFromTail(total: source.count, at: now)
            }
            if cursor.isVisible != pageRevealVisible {
                cursor.setVisible(pageRevealVisible, at: now)
            }
            let count = cursor.revealedCount(total: source.count, at: now)
            codeRevealCursors[rowID] = cursor
            let revealedText = count >= source.count
                ? source : String(source.prefix(count))
            if codeRevealedTexts[rowID] != revealedText {
                codeRevealRevisions[rowID, default: 0] &+= 1
            }
            revealed[rowID] = revealedText
            if count < source.count {
                behind.insert(rowID)
                backlog += source.count - count
            } else if codePendingReplays[rowID] != nil {
                // Caught up; the persisted text can take over next pass.
                codePendingReplays.removeValue(forKey: rowID)
            }
        }
        codeRevealedTexts = revealed
        codeRevealBehindRowIDs = behind
        codeRevealBacklog = backlog
        // The completion cue waits on this: a replay still draining must finish
        // on screen before the haptic can announce the turn (b1731 log: pump
        // backlog 297 → completion pulses 1.2 s later).
        model.setRevealPending(!behind.isEmpty)
        // Union, not replace: a row seen once stays "seen" even after it
        // leaves and re-enters the window, so a history scroll cannot make an
        // old message look new on the next tab return. Only rows with actual
        // assistant text count — an empty turn placeholder must stay
        // replay-eligible when its reply lands later.
        for row in rowsByID.values where StreamingRevealReplayPolicy.hasSeenText(
            isAssistantText: row.value.isAssistantText,
            textEmpty: row.value.displayText.isEmpty) {
            codeKnownRowIDs.insert(row.id)
        }
        if pageRevealVisible {
            hasSampledCodeRevealWhileVisible = true
            codeRevealResuming = false
        }
        if !behind.isEmpty { onRevealPending?() }
    }

    /// Drops a completion snapshot once the persisted text can replace it.
    ///
    /// "Covered" means the persisted text is at least as long and extends the
    /// snapshot. A non-empty divergence means the server replaced the text, so
    /// keeping the snapshot would show stale text. While the persisted text is
    /// empty or a strict prefix of the snapshot (it still lags the stream), the
    /// snapshot stays on screen, so completion never shortens the row.
    private func resolveCompletedStreamingTexts(
        rowsByID: [String: ChatTimelineRowModel]
    ) {
        let cutoff = CACurrentMediaTime() - Self.codeCompletedStreamingLifetime
        // A snapshot whose reveal is still replaying outlives the normal
        // two-second bridge: dropping it here would jump the row to the full
        // persisted text mid-replay (a return from a hidden tab can replay for
        // several seconds).
        codeCompletedStreamingAt = codeCompletedStreamingAt.filter { rowID, at in
            at > cutoff || codeRevealBehindRowIDs.contains(rowID)
        }
        codeCompletedStreamingTexts = codeCompletedStreamingTexts.filter { rowID, text in
            guard codeCompletedStreamingAt[rowID] != nil,
                  let row = rowsByID[rowID] else { return false }
            let persisted = row.value.displayText
            if persisted.isEmpty { return true }
            // A row whose reveal is still replaying keeps its snapshot even
            // when the persisted text already covers it: swapping to the full
            // text now would jump over the characters the cursor owes.
            let revealing = codeRevealBehindRowIDs.contains(rowID)
            if text.hasPrefix(persisted) { return text.count > persisted.count || revealing }
            if persisted.hasPrefix(text) { return persisted.count < text.count || revealing }
            return false
        }
        // Keep the timestamp table in step with the text table.
        codeCompletedStreamingAt = codeCompletedStreamingAt.filter {
            codeCompletedStreamingTexts[$0.key] != nil
        }
    }

    func rowIDs(in item: TimelineListItem) -> [String] {
        switch item {
        case .group(let id):
            return groupsByID[id]?.rows.map(\.id) ?? [id]
        case .notice(let id): return [id]
        case .pending(let id): return [id]
        case .workingStatus: return ["working:status"]
        case .tail: return ["tail"]
        case .olderPrompt:
            // `historyLayout.firstRowID` is the first *timeline row*, not the
            // prompt item (the SwiftUI path uses `timeline.rows.first?.id`).
            // A prompt id here would make C5's loadOlder guard drop the anchor.
            return model.timeline.rows.first.map { [$0.id] } ?? []
        case .latestPrompt: return []
        }
    }

    /// The rows that actually belong to this item's own content. Unlike
    /// `rowIDs(in:)`, the older prompt does not alias the first timeline row:
    /// that alias is useful for the prepend's first-row check, but it would
    /// make the projected anchor match the prompt at y=0 and scroll the page
    /// to the newly loaded top.
    func anchorRowIDs(in item: TimelineListItem) -> [String] {
        TimelineHistoryAnchorRows.rows(for: item, physicalRows: rowIDs(in: item))
    }

    func item(containingRow rowID: String) -> TimelineListItem? {
        rowToItem[rowID]
    }

    /// The durable order of the row under the viewport top. History paging
    /// hands this to the projection so the in-memory window stays around the
    /// reader instead of one end.
    func orderSeq(forRowID rowID: String) -> Int? {
        if let row = model.timeline.rows.first(where: { $0.id == rowID }) {
            return row.value.orderSeq
        }
        // Code groups expose derived row ids (`steps:<span>`), not wire ids.
        // The history anchor can land on one after a live re-pin; resolve it
        // through the built groups so the durable order is still available.
        for group in groupsByID.values {
            if let row = group.rows.first(where: { $0.id == rowID }) {
                return row.value.orderSeq
            }
        }
        return nil
    }

    func interactionState() -> TimelineLayoutInteractionState {
        var state = TimelineLayoutInteractionState()
        state.streamingItemIDs = streamingItemIDs()
        return state
    }

    func applyTypography(_ snapshot: TimelineTypographySnapshot) {
        let nextCode = Self.typography(
            dynamicType: snapshot.dynamicType,
            layoutDirection: snapshot.layoutDirection,
            boldText: snapshot.boldText,
            scale: CodePageTheme.markdownScale)
        guard snapshot != typography || nextCode != codeTypography else { return }
        typography = snapshot
        codeTypography = nextCode
        // Every height key changes; a new generation makes the controller
        // re-read the cache with the new scale instead of keeping fixed frames.
        generation &+= 1
    }

    // MARK: - Probe (probe builds only)

#if AA_TIMELINE_PROBE
    /// A one-line identity for the probe report. The item id alone is opaque
    /// on a phone screenshot; the preview and the block counts let the reader
    /// match a report line to the row they see.
    func probeDescribe(_ item: TimelineListItem) -> String {
        switch item {
        case .group(let id):
            guard let group = groupsByID[id] else { return "missing group \(id)" }
            guard group.explicitID != nil else {
                return "group kind=\(group.kind) rows=\(group.rows.count)"
            }
            let rows = codeRowsByGroupID[id] ?? []
            var textBlocks = 0
            var toolBlocks = 0
            var segments = 0
            var others = 0
            var preview = ""
            for row in rows {
                for block in row.blocks {
                    switch block {
                    case .reasoning:
                        continue
                    case let .text(_, text):
                        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            continue
                        }
                        textBlocks += 1
                        if preview.isEmpty {
                            preview = text.replacingOccurrences(of: "\n", with: " ")
                        }
                    case let .toolCalls(blockSegments):
                        toolBlocks += 1
                        segments += blockSegments.count
                    case .attachments:
                        others += 1
                    case .other:
                        others += 1
                    }
                }
            }
            return "code rows=\(rows.count) text=\(textBlocks) toolBlocks=\(toolBlocks) "
                + "segs=\(segments) other=\(others) preview=\"\(preview.prefix(36))\""
        case .workingStatus: return "workingStatus"
        case .pending: return "pending"
        case .notice: return "notice"
        case .tail: return "tail"
        case .olderPrompt: return "olderPrompt"
        case .latestPrompt: return "latestPrompt"
        }
    }

    /// `est` is what the layout reserves (the structural plan); `exact` is the
    /// same plan with the text blocks measured by the renderer. A visible
    /// cell's fit should match `exact` within the parity gap; a gap between
    /// the two is the cost of using the streaming text model.
    func probeBreakdown(_ item: TimelineListItem) -> String? {
        guard case .group(let id) = item,
              groupsByID[id]?.explicitID != nil else { return nil }
        let rows = codeRowsByGroupID[id] ?? []
        let width = TimelineHeightKey.quantize(lastWidth > 0 ? lastWidth : 361)
        var textBlocks = 0
        var toolBlocks = 0
        var segments = 0
        var others = 0
        for row in rows {
            for block in row.blocks {
                switch block {
                case .reasoning:
                    continue
                case let .text(_, text):
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        textBlocks += 1
                    }
                case let .toolCalls(blockSegments):
                    toolBlocks += 1
                    segments += blockSegments.count
                case .attachments:
                    others += 1
                case .other:
                    others += 1
                }
            }
        }
        let estimate = estimateKind(for: item).height
        let exact = CodeMessageHeightMeasurer.height(
            rows: rows,
            width: width, typography: typography,
            traits: controller?.traitCollection, measured: true,
            pixelSize: attachmentPixelSize)
        return "est=\(probeFormat(estimate)) exact=\(probeFormat(exact)) "
            + "textBlocks=\(textBlocks) toolBlocks=\(toolBlocks) segs=\(segments) "
            + "other=\(others) rows=\(rows.count)"
    }

    private func probeFormat(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
#endif

    // MARK: - Refresh

    private func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        controller?.diagnosticSessionID = model.session.id
#if AA_TIMELINE_PROBE
        let probeRefreshStart = CACurrentMediaTime()
        let probeHadHistoryRequest = pendingHistoryRequest != nil
        defer {
            TimelineProbeStore.shared.noteStage(
                "adapter.refresh", seconds: CACurrentMediaTime() - probeRefreshStart)
        }
#endif

        // Capture the prepend origin before any map is replaced. A history
        // page can merge the anchor's group; after the merge, the old row no
        // longer resolves to an item that still has layout attributes.
        let pendingHistoryOrigin = pendingHistoryRequest.flatMap { request in
            controller?.historyLayout(anchorRowID: request.anchorRowID, edge: request.edge)
        }
        let loadingHistory = model.session.isLoadingHistory
        switch historyLoadDirection {
        case .some(.older):
            isLoadingOlder = loadingHistory
            isLoadingLatest = false
        case .some(.latest):
            isLoadingOlder = false
            isLoadingLatest = loadingHistory
        case .none:
            // Fallback for paths that did not declare a direction: keep the
            // old both-edges behaviour rather than hiding a real spinner.
            isLoadingOlder = loadingHistory
            isLoadingLatest = loadingHistory
        }
        let notices = model.session.notices.notices
        let visibleNotices = notices.filter { $0.isVisible && !$0.blocks(model.session.id) }
        let interactionTargets = Set(notices.filter(\.isVisible).compactMap(\.timelineTargetID))
        // A session-blocking card is drawn in the composer dock, so its row
        // does not need a transcript row of its own: it merges into the
        // running step group like any other step (pp 2026-11-16). Only a
        // non-blocking (inline) card still needs the standalone anchor row.
        let standaloneTargets = Set(notices.filter {
            $0.isVisible && !$0.blocks(model.session.id)
        }.compactMap(\.timelineTargetID))
        // W7: the timeline is the Code page. One planner unit = one group: a
        // message row keeps its declared id (`nativeMessageId ?? itemId`), and
        // a cross-message tool run keeps the first tool's `tool_use` id, so a
        // later serial call grows the same item instead of renaming it and
        // dropping its height/scroll state.
        let profile = model.session.metadata.map { CodeRuntimeProfile(meta: $0) } ?? .generic
        let codeGroups: [ChatTimelineGroup]
        let chatUnits: [TimelineChatUnit]
        var codeRowsByGroupID: [String: [CodeMessageRow]] = [:]
        /// The last user prompt's order: every step group after it belongs to
        /// the turn that is still live. The standalone working row and the
        /// live mark only ever consider this turn's groups — an old turn's
        /// summary must never carry the mark.
        var chatLastUserOrder = Int.min
        var chatLiveTurnHasSteps = false
        /// The strict last unit is a steering user message. The turn's working
        /// mark belongs at the tail, below the solid steer bubble: the group
        /// above it settles (`TimelineChatLiveTail`), and this flag suppresses
        /// the "a live turn with steps already has its mark" gate so the
        /// standalone `正在处理中` row takes the mark (pp 2026-11-17).
        var lastUnitIsSteeringRow = false
        // One row index serves the live-turn scan and the group build. The
        // steps branch used to build the same ~1,700-entry map twice per
        // refresh.
        var rowsByID: [String: ChatTimelineRowModel] = [:]
        if renderMode == .steps {
            // The chat profile groups chronologically: one step-group row per
            // run of thinking/tool steps, one message row per body run. It
            // never merges across messages the way the Code planner does.
            codeGroups = []
#if AA_TIMELINE_PROBE
            let probeGroupStart = CACurrentMediaTime()
#endif
            // Incremental: a stream tick replaces the tail, so the units
            // before the change are reused (see TimelineChatGroupingCache).
            let timelineRows = model.timeline.rows.map(\.value)
            chatUnits = chatGroupingCache.units(
                items: timelineRows,
                profile: profile,
                interactionTargets: interactionTargets,
                standaloneTargets: standaloneTargets,
                cwd: model.session.metadata?.cwd)
            // The validator sorts the whole window and the summary filters
            // it; a stream tick changes one row's text without changing any
            // count here. Run both when the shape moves, or at most once a
            // second so a row that changes unit without changing counts is
            // still reported. `timeline.grouping` keeps its own signature
            // check inside the gate.
            var stepGroupCount = 0
            var messageUnitCount = 0
            var standaloneCount = 0
            for unit in chatUnits {
                switch unit {
                case .stepGroup: stepGroupCount += 1
                case .message: messageUnitCount += 1
                case .standalone: standaloneCount += 1
                }
            }
            let diagnosticsKey = "\(timelineRows.count)|\(chatUnits.count)"
                + "|\(stepGroupCount)|\(messageUnitCount)|\(standaloneCount)"
                + "|\(chatUnits.first?.id ?? "-")|\(chatUnits.last?.id ?? "-")"
            let diagnosticsNow = CACurrentMediaTime()
            if diagnosticsKey != lastDiagnosticsStructureKey
                || diagnosticsNow - lastDiagnosticsAt >= 1 {
                lastDiagnosticsStructureKey = diagnosticsKey
                lastDiagnosticsAt = diagnosticsNow
                TimelineDiagnostics.validateUnits(
                    sessionID: model.session.id,
                    rows: timelineRows,
                    units: chatUnits)
                let grouping = TimelineDiagnostics.groupingSummary(
                    rows: timelineRows, units: chatUnits)
                let groupingSignature = grouping.keys.sorted()
                    .map { "\($0)=\(grouping[$0] ?? "")" }
                    .joined(separator: "&")
                if groupingSignature != lastGroupingSignature {
                    lastGroupingSignature = groupingSignature
                    ClientDiagnosticsLog.shared.record(
                        kind: "timeline.grouping",
                        sessionID: model.session.id,
                        detail: grouping,
                        dedupe: false)
                }
            }
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteStage(
                "adapter.group", seconds: CACurrentMediaTime() - probeGroupStart)
#endif
            for row in model.timeline.rows {
                if rowsByID[row.id] == nil { rowsByID[row.id] = row }
                if row.value.startsVisibleTurn {
                    chatLastUserOrder = max(chatLastUserOrder, row.value.orderSeq)
                }
            }
            let turnGroupIDs = TimelineRunningTurnStepGroups.ids(
                units: chatUnits,
                orderSeq: { rowsByID[$0]?.value.orderSeq },
                lastUserOrder: chatLastUserOrder)
            chatLiveTurnHasSteps = !turnGroupIDs.isEmpty
            lastUnitIsSteeringRow = {
                guard let last = chatUnits.last else { return false }
                if case let .message(_, rowIDs) = last {
                    let rows = rowIDs.compactMap { rowsByID[$0] }
                    return !rows.isEmpty && rows.allSatisfy {
                        $0.value.role == .user && !$0.value.startsVisibleTurn
                    }
                }
                return false
            }()
            // Only while the runtime reports the turn running. The optimistic
            // send window still has the previous turn's rows after the last
            // prompt; admitting it would open settled groups at the bottom
            // (review 2026-11-10).
            chatRunningTurnGroupIDs = model.isRunning ? turnGroupIDs : []
        } else {
            chatRunningTurnGroupIDs = []
            chatUnits = []
            codeGroups = TimelineGrouping.codeGroups(model.timeline.rows,
                                                     profile: profile,
                                                     interactionTargets: interactionTargets,
                                                     standaloneTargets: standaloneTargets)
            for group in codeGroups {
                guard let explicitID = group.explicitID else { continue }
                let rows = CodeMessageBuilder.rows(for: group.rows.map(\.value), profile: profile)
                guard !rows.isEmpty else { continue }
                codeRowsByGroupID[explicitID] = rows
            }
        }
        // Chat profile (pp 2026-10-29, device observation): the dots never
        // leave the group row while the turn runs — there is no standalone
        // working row once the live turn has a step group, not even between
        // steps or before the first body text. Only a live turn with no steps
        // yet shows the standalone row.
        // The tail's queue bubble already shows the in-flight spinner. In the
        // chat profile a standalone working row next to it is a second copy
        // of the same fact, and stacking the two adds the working row's
        // height on the send-success frame (+49, device 2026-11-14). Once the
        // queue empties the working row takes the bubble's place in the same
        // apply, so the swap stays height-neutral.
        // Send-frame visibility (pp 2026-11-16): the pending bubble and the
        // standalone working row must enter the same apply. The bubble comes
        // from the presentation's own tick; when the working row ran ahead,
        // its +38 follow started first and the 53 pt bubble joined mid-flight
        // (probe `timeline.rows.frame`). Waiting for the published row makes
        // one +91 follow — the page scrolls once and the tool row is already
        // in place. The bubble's old spinner is gone, so this row is the
        // send's only progress signal.
        // A steer is not a send frame: while it waits (dashed bubble) the turn
        // is still working on its own step group, and the reader wants no
        // 「正在处理中」 row until the message is actually read. After the echo
        // the strict-last-unit rule below puts the row under the settled
        // bubble (pp 2026-11-17: the row used to be absent, then the tail went
        // blank for 1–2 s after the dash turned solid).
        let openPending = model.session.pendingMessages.filter {
            !$0.isSteer
                && ($0.delivery == .sending || $0.delivery == .accepted || $0.delivery == .confirmed)
        }
        let publishedPendingIDs = Set(model.timeline.pendingMessages.map(\.id))
        // The session clears its record when the echo confirms; the
        // presentation retires the bubble one refresh later. In that gap
        // `openPending` is empty while the old turn's steps are still after
        // the last presented user row, so the working row dropped for a frame
        // and came back with the echo — −38 then +38 scrolls (pp 2026-11-16,
        // b1285: 22:44:16.105 / 16.142). The presentation's pending row keeps
        // the send frame anchored across the gap.
        let anchorPendingIDs = SendFramePresentation.anchorPendingIDs(
            sessionIDs: openPending.map(\.id),
            // A steering message never anchors the working row: it belongs to
            // the running turn and only counts once it has been read.
            presentedIDs: model.timeline.pendingMessages
                .filter { !$0.isSteer }.map(\.id))
        var echoedPendingIDs: Set<String> = []
        if let latest = openPending.last,
           latest.delivery != .sending, !publishedPendingIDs.contains(latest.id) {
            // The echo retires the pending row from the presentation on the
            // same transition; its timeline row is the published send frame.
            echoedPendingIDs = Set(model.timeline.rows.compactMap { row -> String? in
                guard row.value.role == .user else { return nil }
                return row.value.source["clientMessageId"]?.stringValue
            }.filter { $0 == latest.id })
        }
        let runtimeIsInFlight = model.session.runtime.state?.status.isTurnInFlight == true
        let hasWorkingStatus = SendFramePresentation.showsWorkingRow(
            placeholderVisible: model.isAwaitingReply,
            pendingIDs: anchorPendingIDs,
            publishedPendingIDs: publishedPendingIDs,
            echoedPendingIDs: echoedPendingIDs,
            isStepsProfile: renderMode == .steps,
            // A pending send already starts the next turn: the step groups
            // after the last *echoed* user row belong to the previous turn,
            // and counting them here deferred the working row past the echo —
            // a second +38 scroll ~1.1 s after the bubble (pp 2026-11-16,
            // b1284 log: bubble +53 at 22:22:11.170, row +38.3 at 12.327).
            // The anchor spans the pending→echo gap as well, or the row drops
            // for one refresh and returns with the echo.
            hasLiveSteps: chatLiveTurnHasSteps && anchorPendingIDs.isEmpty
                && !lastUnitIsSteeringRow,
            queueCount: model.session.sendQueue.items.count)
        let workingStatusShowsText = SendFramePresentation.showsWorkingRowText(
            latestDelivery: openPending.last?.delivery,
            runtimeIsInFlight: runtimeIsInFlight)
        // The official mark's pose follows the live turn's last event
        // (`SessionDisplay.liveTurnMark`). Keep the last pose while the row
        // plays its exit, so the exit animates the sprite that was on screen.
        if hasWorkingStatus {
            workingStatusExitState.markBody = liveWorkingMarkBody()
            workingStatusExitState.showsText = workingStatusShowsText
            // A new working block anchors its own verb phase; the first block
            // after launch starts now.
            if workingStatusPhaseStart == nil || !lastHasWorkingStatus {
                workingStatusPhaseStart = Date()
            }
            let phase = liveWorkingStatusPhase(startedAt: workingStatusPhaseStart ?? Date())
            if workingStatusExitState.phase != phase {
                workingStatusExitState.phase = phase
            }
        }
        // Official working-mark exit: when the turn's status disappears the
        // row is not deleted instantly. It stays mounted for the 0.4 s
        // scale/opacity group animation with `isRunning = false`
        // (CANONICAL/20-working-mark.md §6), then leaves on its own refresh.
        if hasWorkingStatus {
            cancelWorkingStatusExit()
        } else if renderMode == .steps {
            // The chat profile moves the one mark onto the step group's row in
            // the same update; keeping the old row mounted for its 0.4 s exit
            // would draw two marks at once.
            cancelWorkingStatusExit()
        } else if lastHasWorkingStatus, !workingStatusIsExiting {
            beginWorkingStatusExit()
        }
        if hasWorkingStatus != lastHasWorkingStatus
            || (hasWorkingStatus && workingStatusShowsText != lastWorkingStatusShowsText) {
            // Which gate decided the standalone working row, and whether the
            // send is acknowledged yet: this trail is the only record of the
            // "half second with no working row after a send" report
            // (device 2026-11-14) and of the ack turning the mark into text.
            let submitting = model.session.pendingMessages.contains {
                $0.delivery == .sending || $0.delivery == .accepted
            }
            ClientDiagnosticsLog.shared.record(
                kind: "timeline.working.row",
                sessionID: model.session.id,
                detail: [
                    "has": hasWorkingStatus ? "1" : "0",
                    "workingText": workingStatusShowsText ? "1" : "0",
                    "submitting": submitting ? "1" : "0",
                    "awaiting": model.session.awaitingReplyID != nil ? "1" : "0",
                    "queue": String(model.session.sendQueue.items.count),
                    "liveSteps": chatLiveTurnHasSteps ? "1" : "0",
                    "running": model.isRunning ? "1" : "0",
                    "fresh": model.session.runtime.isFresh ? "1" : "0",
                    "status": String(describing: model.session.runtime.state?.status),
                ],
                dedupe: false)
        }
        if hasWorkingStatus, workingStatusShowsText, !lastWorkingStatusShowsText {
            // The text just appeared — the send is confirmed enough to start
            // work (a running runtime proves the message reached the backend,
            // even when the HTTP ack is still in flight). Hand the page one
            // edge for its confirmation haptic; deferred out of the update
            // that computed it (see `onWorkingTextShown`).
            DispatchQueue.main.async { [weak self] in self?.onWorkingTextShown?() }
        }
        lastHasWorkingStatus = hasWorkingStatus
        lastWorkingStatusShowsText = workingStatusShowsText
        let showsWorkingStatus = hasWorkingStatus
            || (renderMode != .steps && workingStatusIsExiting)
        var groups: [ChatTimelineGroup] = []
        var stepGroupsByID: [String: TimelineStepGroup] = [:]
        if renderMode == .steps {
            groups.reserveCapacity(chatUnits.count)
            var lastStepGroupID: String?
            // Units the cache carried over unchanged are rebuilt from last
            // refresh's values instead of re-projecting their rows. The three
            // arrays all come from the same cache call; the min is only a
            // bounds guard so no future path can index past either.
            let reusableUnits = min(chatGroupingCache.reusableUnitCount,
                                    lastChatUnits.count,
                                    lastChatBuilds.count,
                                    chatUnits.count)
            var builds: [ChatUnitBuild] = []
            builds.reserveCapacity(chatUnits.count)
#if AA_TIMELINE_PROBE
            let probeBuildGroupsStart = CACurrentMediaTime()
#endif
            for (index, unit) in chatUnits.enumerated() {
                if index < reusableUnits {
                    let build = lastChatBuilds[index]
                    switch unit {
                    case let .stepGroup(stepGroup, _):
                        if let group = build.group {
                            stepGroupsByID[stepGroup.id] = stepGroup
                            if let first = group.rows.first,
                               first.value.orderSeq > chatLastUserOrder {
                                lastStepGroupID = stepGroup.id
                            }
                            groups.append(group)
                        }
                    case let .message(key, _):
                        if let rowsBuilt = build.messageRows {
                            codeRowsByGroupID[key] = rowsBuilt
                        }
                        if let group = build.group { groups.append(group) }
                    case .standalone:
                        if let group = build.group { groups.append(group) }
                    }
                    builds.append(build)
                    continue
                }
                var build = ChatUnitBuild()
                switch unit {
                case let .stepGroup(stepGroup, rowIDs):
                    let rows = rowIDs.compactMap { rowsByID[$0] }
                    guard !rows.isEmpty else { builds.append(build); continue }
                    stepGroupsByID[stepGroup.id] = stepGroup
                    if let first = rows.first, first.value.orderSeq > chatLastUserOrder {
                        lastStepGroupID = stepGroup.id
                    }
                    let group = ChatTimelineGroup(kind: .tools, rows: rows,
                                                  explicitID: stepGroup.id)
                    groups.append(group)
                    build.group = group
                case let .message(key, rowIDs):
                    let rows = rowIDs.compactMap { rowsByID[$0] }
                    guard !rows.isEmpty else { builds.append(build); continue }
                    let rowsBuilt = CodeMessageBuilder.rows(for: rows.map(\.value),
                                                            profile: profile)
                    guard !rowsBuilt.isEmpty else { builds.append(build); continue }
                    codeRowsByGroupID[key] = rowsBuilt
                    let group = ChatTimelineGroup(kind: .single, rows: rows,
                                                  explicitID: key)
                    groups.append(group)
                    build.group = group
                    build.messageRows = rowsBuilt
                case let .standalone(rowID):
                    guard let row = rowsByID[rowID] else { builds.append(build); continue }
                    // Keyless on purpose: the standalone renderer carries the
                    // interaction cards, turn footer and interrupted notice.
                    //
                    // An interaction anchor is self-margined: its card docks
                    // directly below, so the list's legacy 20 pt gap would read
                    // as a blank band under the anchor row. The Code profile's
                    // `codeGroups` already marks it; this chat-profile build
                    // used to drop the flag, which is why the question card
                    // still sat 20 pt low on b1270 (pp 2026-11-16).
                    let group = ChatTimelineGroup(
                        kind: .single, rows: [row],
                        isInteractionAnchor: interactionTargets.contains(rowID))
                    groups.append(group)
                    build.group = group
                }
                builds.append(build)
            }
            lastChatUnits = chatUnits
            lastChatBuilds = builds
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteStage(
                "adapter.buildGroups", seconds: CACurrentMediaTime() - probeBuildGroupsStart)
#endif
            // The dots stay on the trailing group for the whole live turn
            // (pp's device observation) — but only while that group is the
            // turn's strict last unit. A steering row takes the mark away:
            // the SDK reads a steer at a tool boundary, so the group above it
            // is done, and the standalone 「正在处理中」 row draws the mark
            // under the solid steer bubble instead (pp 2026-11-17: keeping
            // the group live across the steer row drew two working rows,
            // device 23:50:39).
            let lastUnitIsStepGroup = TimelineChatLiveTail.stepGroupOwnsMark(chatUnits)
            // The live tail exists only while the turn really streams. The
            // optimistic send window is deliberately excluded: it used to
            // keep the dots on the previous turn's group, which is what made
            // an interrupted row flash back to running the moment a new
            // message was sent (pp 2026-11-10), and the same window re-opened
            // on the stop ack before the idle frames landed (pp 2026-11-14).
            let turnStreaming = model.isTranscriptStreaming
            // A local outgoing message is still on screen (sending, accepted
            // or awaiting its echo). Every group above it belongs to the
            // previous turn, so none may inherit the new turn's mark while the
            // runtime already reports running — that is the send-time flash
            // (pp 2026-11-14). The new turn's own rows animate from their own
            // running steps.
            // A steer rides the turn already running; treating it as the next
            // turn's pending send settled the live step group into its
            // summary the moment it was sent (pp 2026-11-17).
            let hasPendingSend = model.session.pendingMessages.contains { !$0.isSteer }
                || model.timeline.pendingMessages.contains { !$0.isSteer }
            let turnActive = turnStreaming && !hasPendingSend
            // A fresh idle — or the accepted stop's optimistic idle — proves
            // every still-`running` step snapshot is stale. Only the groups of
            // the actively streaming turn may animate. The pending-send window
            // and a previous turn's groups are excluded, so a background
            // subagent that outlived its turn never re-draws the working mark
            // when a new message starts streaming (pp 2026-11-19).
            //
            // A steering row takes the mark away from the groups above it: the
            // standalone 「正在处理中」 row owns it, and a group with a running
            // background dispatch would otherwise draw a second mark the same
            // frame (the 2026-11-18 two-working-rows bug; the live tail gate
            // already excludes the group, this keeps the pose set aligned).
            chatRunningPoseGroupIDs = (turnActive && !lastUnitIsSteeringRow)
                ? chatRunningTurnGroupIDs : []
            // While the turn streams, a failed tool in the group is not
            // residue — the agent moves on and the row must keep the live
            // pose through the next gap (pp 2026-11-10: a mid-turn ⚠️ settled
            // the row while the turn still ran). A stopped turn falls back to
            // the residue rule, so an interrupted group cannot regain it.
            let lastStepGroup = lastStepGroupID.flatMap { stepGroupsByID[$0] }
            let canCarryLiveMark = lastStepGroup?
                .canCarryLiveMark(turnIsRunning: turnActive) ?? false
            chatLiveTailGroupID = (turnActive && lastUnitIsStepGroup && canCarryLiveMark)
                ? lastStepGroupID : nil
            // The newest group the base pose rule draws on. Rule A only lets a
            // running dispatched-subagent row settle when this owner is newer,
            // so the turn never loses its working mark (pp 2026-11-21).
            var markOwner: String?
            for unit in chatUnits {
                guard case let .stepGroup(markGroup, _) = unit else { continue }
                if markGroup.id == chatLiveTailGroupID
                    || (markGroup.isRunning
                        && chatRunningPoseGroupIDs.contains(markGroup.id)) {
                    markOwner = markGroup.id
                }
            }
            chatMarkOwnerGroupID = markOwner
        } else {
            chatLiveTailGroupID = nil
            chatMarkOwnerGroupID = nil
            groups.reserveCapacity(codeGroups.count)
            for group in codeGroups {
                guard let explicitID = group.explicitID else {
                    groups.append(group)
                    continue
                }
                guard let rows = codeRowsByGroupID[explicitID] else { continue }
                let hasVisibleBlock = rows.contains { row in
                    row.blocks.contains { block in
                        switch block {
                        case let .reasoning(_, text, status, _):
                            return status == .done
                                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case let .text(_, text):
                            // An empty text block renders nothing; it must not
                            // keep a group (or a 44 pt estimate) alive.
                            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        case .toolCalls, .other, .attachments:
                            return true
                        }
                    }
                }
                // `codeGroups` already drops a message whose only rows are calls
                // the runtime skips; this guard keeps a message whose only block
                // is reasoning (or no visible block) from becoming an empty item.
                guard hasVisibleBlock else { continue }
                groups.append(group)
            }
        }
        // While a working status row narrates the turn, the compaction marker
        // draws nothing (round31 §5: the official transcript has one working
        // row, not a second progress line). Dropping the group keeps its
        // height, list gap and turn-action participation out of the layout
        // entirely. With no working row (the chat profile keeps it on a
        // stepped turn's group) the marker stays and carries the progress
        // label itself.
        if showsWorkingStatus {
            groups.removeAll { group in
                guard group.explicitID == nil, group.rows.count == 1,
                      let row = group.rows.first else { return false }
                return TimelineEntryPresentation.isCompactItem(row.value)
                    && TimelineEntryPresentation.isActiveCompactItem(row.value)
            }
        }
#if AA_TIMELINE_PROBE
        let probeIndexStart = CACurrentMediaTime()
#endif
        // The routing set only exists for notices. Most streaming refreshes
        // carry none, and building it cost a ~2,900-row set on every tick.
#if AA_TIMELINE_PROBE
        let probeNoticesStart = CACurrentMediaTime()
#endif
        let tailNotices: [SessionNoticeModel]
        if notices.isEmpty {
            tailNotices = []
        } else {
            let timelineRowIDs = Set(model.timeline.rows.map(\.id))
            tailNotices = SessionNoticeRouting.tailNotices(
                notices, sessionID: model.session.id,
                timelineRowIDs: timelineRowIDs)
        }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.notices", seconds: CACurrentMediaTime() - probeNoticesStart)
#endif
        // The presentation retires a pending row one refresh after its echo
        // row publishes; hiding it as soon as the echo row is on screen keeps
        // one message from drawing as two bubbles (dashed + settled) for a
        // frame (pp 2026-11-17). The queue row already uses the same rule.
        //
        // Only pending records need the echo set. Most live refreshes carry
        // none, and building it scanned every window row (2,900+) with a JSON
        // field probe on each stream tick.
#if AA_TIMELINE_PROBE
        let probeEchoStart = CACurrentMediaTime()
#endif
        let pendingRecords = model.timeline.pendingMessages
        let pending: [V2PendingMessage]
        if pendingRecords.isEmpty {
            pending = []
        } else {
            let echoedClientIDs = Set(model.timeline.rows.compactMap { row -> String? in
                guard row.value.role == .user else { return nil }
                return row.value.source["clientMessageId"]?.stringValue
            })
            pending = pendingRecords.filter { !echoedClientIDs.contains($0.id) }
        }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.echo", seconds: CACurrentMediaTime() - probeEchoStart)
#endif
        let identity = TimelineItemIdentity.build(
            hasOlderPrompt: model.session.canLoadOlder || keepsOlderPrompt,
            groupIDs: groups.map(\.id),
            hasWorkingStatus: showsWorkingStatus,
            noticeIDs: tailNotices.map(\.id),
            pendingIDs: pending.map(\.id))

        var groupsByID: [String: ChatTimelineGroup] = [:]
        for group in groups where groupsByID[group.id] == nil { groupsByID[group.id] = group }
        var tailNoticesByID: [String: SessionNoticeModel] = [:]
        for notice in tailNotices where tailNoticesByID[notice.id] == nil {
            tailNoticesByID[notice.id] = notice
        }
        var pendingByID: [String: V2PendingMessage] = [:]
        for message in pending where pendingByID[message.id] == nil {
            pendingByID[message.id] = message
        }
#if AA_TIMELINE_PROBE
        let probeRowMapStart = CACurrentMediaTime()
#endif
        var rowToItem: [String: TimelineListItem] = [:]
        for group in groups {
            let item = TimelineListItem.group(group.id)
            for row in group.rows where rowToItem[row.id] == nil {
                rowToItem[row.id] = item
            }
        }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.rowmap", seconds: CACurrentMediaTime() - probeRowMapStart)
#endif
        // The interrupted-turn notice is a footer of the unit that carries the
        // stopped turn's last row (a message group when there is a partial
        // answer, otherwise the step group). A cold open can recover the
        // marker from the runtime state's interrupt source.
        model.noteAuthoritativeInterruptIfNeeded()
        chatInterruptedItemIDs = Set(model.interruptedTurns.compactMap {
            rowToItem[$0.anchorItemID]?.itemID
        })
        let newCardAnchors = chatInterruptedItemIDs.subtracting(lastInterruptedCardProbeIDs)
        if !newCardAnchors.isEmpty {
            let viewport = controller?.viewport
            ClientDiagnosticsLog.shared.record(
                kind: "timeline.interrupt.card",
                sessionID: model.session.id,
                detail: [
                    "anchors": newCardAnchors.sorted().joined(separator: ","),
                    "offsetY": String(format: "%.1f", viewport?.offsetY ?? -1),
                    "contentH": String(format: "%.1f", viewport?.contentHeight ?? -1),
                    "tailH": {
                        guard let height = controller?.tailCellHeight() else { return "-1" }
                        return String(format: "%.1f", height)
                    }(),
                    "fresh": model.session.runtime.isFresh ? "1" : "0",
                    "stopRequested": model.session.runtime.stopRequested ? "1" : "0",
                    "predictedIdle": model.session.runtime.predictedIdle ? "1" : "0",
                    "status": String(describing: model.session.runtime.state?.status),
                ],
                dedupe: false)
        }
        lastInterruptedCardProbeIDs = chatInterruptedItemIDs
        var inlineNoticesByRow: [String: [SessionNoticeModel]] = [:]
        for notice in visibleNotices where notice.notice.type == "interaction" {
            guard let target = notice.timelineTargetID else { continue }
            inlineNoticesByRow[target, default: []].append(notice)
        }
        // The one-footer-per-turn rule waits for the turn to close. The
        // runtime status alone flaps across tool steps, so the gate keys on
        // the turn's opening user message and the authoritative end count.
        // A `confirmed` record is retained by the presentation until its echo
        // row publishes; it is still the new turn in that gap. Dropping it
        // here made the gate fall back to the previous user row, suppress the
        // previous footer for one refresh, and start the send's bottom follow
        // 30 pt low (pp 2026-11-15).
        let submittingPendingID = model.timeline.pendingMessages.last {
            !$0.isSteer && TimelineTurnActions.opensTurn($0.delivery)
        }?.id
        let latestUserRow = model.timeline.rows.last(where: {
            $0.value.startsVisibleTurn
        })
        let latestUserRowID = latestUserRow?.id
        // A background dispatch can lose its flag on a later publication (a
        // transcript rebuild, or a card re-minted after a connector restart
        // lost its in-memory task overlay). Remember every row that ever
        // proved it was a background hand-off for as long as it stays in the
        // window, so the exemption cannot flip back and turn a still-running
        // card into "activity" (pp 2026-11-24, sess_2zXT: the finished turn's
        // footer stayed hidden for ~1 min with four background agents, then
        // returned when a later publication carried the flag again). The fold
        // is a pure function so `swift test` covers its wiring; the adapter
        // itself is outside the ClientCore target.
        // A pending bubble whose echo row is already in the timeline is no
        // longer opening a new turn; it must not force the previous turn's
        // commit or the new turn's footer.
        let submittingPendingHasEcho = submittingPendingID.map { id in
            model.timeline.rows.contains { row in
                row.value.role == .user
                    && row.value.source["clientMessageId"]?.stringValue == id
            }
        } ?? false
        let latestTurnOpen = turnFooterGate.update(
            userKey: submittingPendingID ?? latestUserRowID,
            runtimeIsRunning: model.isRunning,
            authoritativeTurnEnds: model.session.runtime.authoritativeTurnEnds,
            // A command compaction opens a turn on the wire with no user
            // bubble, so the finished turn before it would read as "still
            // running" and lose its footer for the whole compaction
            // (pp 2026-11-15: copy/share disappeared and the page jumped
            // twice by the 30 pt action bar).
            isCompacting: liveTurnIsCompacting(),
            // A key that moves backwards is a row correcting its role (the
            // steer echo's `user` → `steeringUserMessage` revision), not a
            // new turn. Pending records have no position.
            userKeyOrder: submittingPendingID == nil
                ? latestUserRow?.value.orderSeq
                : nil)
        // The live user turn's bucket keeps the bubble-only split so a
        // queued-send turn-id flap cannot commit a footer mid-turn. Only that
        // trailing bucket is live: everything before it is finished history
        // and still splits on the wire's ids. Suppressing the ids for the
        // whole build re-merged each finished turn with the scheduled turn
        // that followed it, so every send and every turn end toggled six
        // copy/share bars (pp 2026-11-16, b1279: footer hosts 94↔88).
        // A session view can open with cached rows before the live runtime
        // state arrives; "state unknown" is not "not running". Committing the
        // latest bucket on that refresh stamps a streaming reply with a footer
        // and seeds the closed snapshot with it, so the running state's
        // userless restore keeps it for the whole turn (pp 2026-11-23 22:04,
        // build 1541: gate closed at `status=nil`, hosts 103→104 at
        // 22:04:10.204, gone only after the next view rebuild). A state that
        // exists but predates the current live facts (background, socket
        // loss, recovery) is equally untrusted; `isFresh` is the model's
        // current-live-facts gate. Offline/failed has no live read to wait
        // for, so the last known layout wins there.
        let connectorOffline: Bool = {
            switch model.session.connection {
            case .offline, .failed: return true
            case .inactive, .connecting, .connected, .reconnecting: return false
            }
        }()
        // One pass for the latch and the coverage watermarks; both read the
        // same rows with the same per-row JSON probes (2026-11-25 probe:
        // 12 ms per stream tick in `adapter.index`).
#if AA_TIMELINE_PROBE
        let probeFooterStart = CACurrentMediaTime()
#endif
        let footerScan = TimelineTurnActions.footerScan(
            rows: model.timeline.rows.lazy.map(\.value),
            existing: backgroundDispatchedItemIDs,
            stateSeq: model.session.runtime.state?.updatedSeq ?? 0)
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.footer", seconds: CACurrentMediaTime() - probeFooterStart)
#endif
        backgroundDispatchedItemIDs = footerScan.latchedBackgroundIDs
        let runtimeState = model.session.runtime.state
        // A stale state still seals when it was written after the newest row
        // that can move the main turn; a main row newer than the state is
        // activity it never saw. Sub-agent child rows and the background
        // hand-off card itself are excluded: a background child keeps
        // streaming *and* its card is republished on every step long after the
        // main turn's idle state, so counting either made every switch into a
        // session with background agents pay the 1–2 s live-read wait again
        // (pp 2026-11-24: the footer stayed hidden until the sync, and the
        // only rows newer than the idle state were the child rows and the
        // card of the running background agent). The latch covers a card
        // whose wire flag was dropped by a later publication.
        let coverage = footerScan.coverage
        // `footerRuntimeStateIsTrustworthy` already handles the missing state
        // and the fresh state; only the stale-state coverage decision lives
        // here.
        let stateCoversRows = coverage.coversMainRows
        let runtimeStateKnown = TimelineTurnActions.footerRuntimeStateIsTrustworthy(
            stateExists: runtimeState != nil,
            isFresh: model.session.runtime.isFresh,
            connectorOffline: connectorOffline,
            stateCoversRows: stateCoversRows)
        let suppressLatest = TimelineTurnActions.suppressesLatest(
            latestTurnOpen: latestTurnOpen,
            runtimeIsRunning: model.isRunning,
            hasNewerItems: model.session.hasNewerItems,
            runtimeStateKnown: runtimeStateKnown)
        let liveTurnGroupID = TimelineTurnActions.resolveLiveTurnGroupID(
            isLiveUserTurn: turnFooterGate.isLiveUserTurn,
            hasUnEchoedPending: submittingPendingID != nil && !submittingPendingHasEcho,
            latestUserRowID: latestUserRowID,
            groups: groups,
            latchedBackgroundIDs: backgroundDispatchedItemIDs)
        recordFooterGateProbe(suppressLatest: suppressLatest,
                              pendingID: submittingPendingID,
                              pendingHasEcho: submittingPendingHasEcho,
                              liveTurnGroupID: liveTurnGroupID,
                              latestUserRowID: latestUserRowID,
                              latestUserOrder: latestUserRow?.value.orderSeq,
                              groups: groups,
                              gateLiveUserTurn: turnFooterGate.isLiveUserTurn,
                              latchedBackgroundIDs: backgroundDispatchedItemIDs)
#if AA_TIMELINE_PROBE
        let probeTurnActionsStart = CACurrentMediaTime()
#endif
        // Per-group facts memo (`GroupFactsKey`). A stream tick rewrites one
        // group's rows; every other group reuses last refresh's walk, which is
        // where `adapter.index.turnActions` spent 4.7 ms (b1625, 301 items).
        // The latch changes the facts' exclusions, so a latch change drops the
        // whole table.
        if groupFactsLatch != backgroundDispatchedItemIDs {
            ClientDiagnosticsLog.shared.record(
                kind: "timeline.turnfacts.reset",
                sessionID: model.session.id,
                detail: ["cleared": String(groupFactsCache.count),
                         "latch": String(backgroundDispatchedItemIDs.count)],
                dedupe: false)
            groupFactsCache.removeAll(keepingCapacity: true)
            groupFactsKeys.removeAll(keepingCapacity: true)
            groupFactsLatch = backgroundDispatchedItemIDs
        }
        factsMissedThisRefresh = false
        let factsLatch = backgroundDispatchedItemIDs
        let groupFactsProvider: (ChatTimelineGroup) -> TimelineTurnActions.GroupTurnFacts = {
            [weak self] group in
            guard let self else {
                return TimelineTurnActions.groupFacts(
                    for: group, latchedBackgroundIDs: factsLatch)
            }
            let key = TimelineTurnActions.GroupFactsKey(group: group)
            if self.groupFactsKeys[group.id] == key, let cached = self.groupFactsCache[group.id] {
#if AA_TIMELINE_PROBE
                TimelineProbeStore.shared.noteStage("turnActions.memo.hit", seconds: 0)
#endif
                return cached
            }
            self.factsMissedThisRefresh = true
#if AA_TIMELINE_PROBE
            TimelineProbeStore.shared.noteStage("turnActions.memo.miss", seconds: 0)
#endif
            let facts = TimelineTurnActions.groupFacts(
                for: group, latchedBackgroundIDs: self.backgroundDispatchedItemIDs)
            self.groupFactsKeys[group.id] = key
            self.groupFactsCache[group.id] = facts
            if self.groupFactsCache.count > groups.count * 2 {
                self.groupFactsCache = self.groupFactsCache.filter { groupsByID[$0.key] != nil }
                self.groupFactsKeys = self.groupFactsKeys.filter { groupsByID[$0.key] != nil }
            }
            return facts
        }
        if stateSealSessionID != model.session.id {
            stateSealCommit = nil
            stateSealSessionID = model.session.id
        }
        // A running runtime is not a reason to drop the seal: `suppressLatest`
        // already withholds the commit while the gate is open, and the seal is
        // still needed to tell a userless *new* turn from the same turn
        // resuming after an idle flap (see the restore guard below). The
        // durable ledger id and a session change are the only clearers.
        var footerReport: TimelineTurnActions.FooterBuildReport?
        var turnActions = TimelineTurnActions.build(
            groups: groups,
            // The gate's authoritative end count is the primary boundary, but
            // a turn that ended without a captured transition must not keep
            // its footer suppressed until the next user message (device
            // 2026-11-15: the copy/share buttons only appeared after the
            // reader sent the following message). A confirmed idle overrides
            // the open gate; a running tool step still suppresses, so the
            // footer cannot hop between reply segments.
            suppressLatest: suppressLatest,
            // Only an outgoing bubble that has not been echoed starts a new
            // turn for the previous footer. A confirmed record held by the
            // presentation until its echo row publishes is not a new turn.
            hasPendingUserMessage: !model.session.hasNewerItems
                && submittingPendingID != nil && !submittingPendingHasEcho,
            // A turn that no user bubble opened — a compaction command turn,
            // a scheduled reader turn, the wake-up a completed background task
            // sends — has only its declared turn id as a boundary. Without it
            // the previous turn's footer slides onto the new turn's reply
            // (pp 2026-11-16 10:05:54: host msg_577ba3bc → msg_1e1de664 with
            // the footer count unchanged). Only the live user turn keeps the
            // bubble-only split; history still splits, or the same wake-up
            // turn re-merges on every send (same day 11:09–11:25).
            liveTurnGroupID: liveTurnGroupID,
            // Once a card proved it was a background dispatch, a later
            // rewrite that drops the flag must not turn it back into activity
            // (see `backgroundDispatchedItemIDs`).
            latchedBackgroundIDs: backgroundDispatchedItemIDs,
            // The session's durable turn-end fact. When the server/connector
            // declare the ended turn's id, a matching last bucket is over
            // regardless of state freshness; nil keeps the runtime-state rule.
            latestTurnId: model.session.metadata?.latestTurnId,
            latestTurnEndSeq: model.session.metadata?.latestTurnEndSeq ?? 0,
            // A dropped socket can leave rows newer than the session meta;
            // the contract must not suppress the last known footer offline.
            connectorOffline: connectorOffline,
            // A state written after every visible main row, on an idle
            // runtime, already proves the bucket ended: the durable id is
            // only late (the Server records it behind the timeline fence).
            // Without this the footer appeared 0.4–1.2 s after the reply
            // finished even though `timeline.state` was already idle with
            // coversMain=1 (pp 2026-11-24 23:52:52 → 23:52:53.65).
            stateCoversMain: coverage.coversMainRows,
            // An older page's trailing bucket is cut by the window, not by
            // its turn end; the durable watermark cannot prove it complete.
            hasNewerItems: model.session.hasNewerItems,
            // Memoized per-group row facts (see `groupFactsProvider` above).
            facts: groupFactsProvider,
            // The turn this session's covering idle state already proved
            // over. A row of that same turn rewritten afterwards must not
            // withdraw the footer while the ledger id is still in flight (the
            // 30 pt blink at 2026-11-25 10:28:49.96); a different turn can
            // never match the id.
            stateSeal: stateSealCommit,
            // A step group renders as one line (CodeStepGroupRowView) and draws
            // no footer; keying a turn action to it made the footer vanish and
            // hop to the next group (device 2026-10-31 05:40: the compact
            // divider lost its footer by 91 pt when the next step arrived).
            footerHostEligible: { stepGroupsByID[$0.id] == nil },
            report: { report in
                footerReport = report
                // The state proved a turn over: remember the turn, not the
                // host (rows of the same turn may still move the footer's
                // hosting group, while a different turn must never match it).
                // A durable ledger answer clears the seal; an outgoing bubble
                // is not this proof — it does not depend on rows the state has
                // seen. See `nextStateSeal`.
                self.stateSealCommit = TimelineTurnActions.nextStateSeal(
                    previous: self.stateSealCommit, report: report)
                // One line per change: the decision inputs plus what the last
                // bucket actually held. With the gate probe it turns a missing
                // footer into a diagnosis instead of a row-count guess.
                self.noteFooterBuildReport(
                    report,
                    suppressLatest: suppressLatest,
                    latestTurnOpen: latestTurnOpen,
                    coverage: coverage,
                    stateExists: runtimeState != nil,
                    runtimeStateSeq: runtimeState?.updatedSeq ?? 0,
                    connection: self.model.session.connection)
            })
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.turnActions", seconds: CACurrentMediaTime() - probeTurnActionsStart)
#endif
        // A userless episode must not take the finished turn's footer away:
        // the build suppresses the latest bucket, but the bucket on screen is
        // already finished, so the closed state's footers stay. Browsing an
        // older page keeps its own rule (`hasNewerItems` suppresses the
        // latest bucket by design).
        if latestTurnOpen {
            // A userless episode is not always a *new* turn: a runtime that
            // reports idle between tool steps and then running again resumes
            // the same turn, and the gate's authoritative end clears its user
            // anchor either way. Restoring the closed footer onto a bucket
            // that is actively running *that same declared turn* would put the
            // finished footer back on the live reply (the 2026-11-23 22:04
            // class). A scheduled wake or a compaction carries a different
            // turn id (or none), so its finished footer still restores.
            let sealedOrLedgerTurnID = stateSealCommit?.turnID
                ?? footerReport?.latestTurnID
            let isResumingTheSealedTurn = TimelineTurnActions.restoreWouldCoverAResumingTurn(
                hasActiveItems: footerReport?.hasActiveItems == true,
                bucketTurnID: footerReport?.bucketTurnID,
                sealedOrLedgerTurnID: sealedOrLedgerTurnID)
            if turnFooterGate.isUserlessEpisode, !model.session.hasNewerItems,
               !isResumingTheSealedTurn {
                turnActions = TimelineTurnActions.restoringFinishedFooters(
                    turnActions, from: closedTurnActions,
                    groupIDs: Set(groupsByID.keys))
            }
        } else if !model.session.hasNewerItems, runtimeStateKnown,
                  !model.timeline.rows.isEmpty {
            // Only the newest page, with a trusted runtime state and actual
            // rows, is a complete map of finished footers. Browsing older
            // history suppresses the latest bucket; an unknown state may have
            // withheld a running turn that is not finished; an empty first
            // tick (session.open) has no footers at all. Capturing any of them
            // would overwrite the map with one the restore path later trusts
            // (review 2026-11-23; the state-unknown case reproduced on build
            // 1541 at 22:04).
            closedTurnActions = turnActions
        }

        self.groupsByID = groupsByID
        self.codeProfile = profile
        self.codeRowsByGroupID = codeRowsByGroupID
        self.stepGroupsByID = stepGroupsByID
        liveStepGroups.publish(stepGroupsByID)
        codeHeightCache = codeHeightCache.filter { codeRowsByGroupID[$0.key] != nil }
        // The cache is keyed by `TimelineListItem.itemID` ("g:<group id>");
        // `groupsByID` is keyed by the bare group id. Strip the prefix or the
        // filter clears the cache on every refresh (the O(text) rehash this
        // cache exists to avoid).
        heightRevisionCache = heightRevisionCache.filter { key, _ in
            guard key.hasPrefix("g:") else { return false }
            return groupsByID[String(key.dropFirst(2))] != nil
        }
        self.tailNoticesByID = tailNoticesByID
        self.pendingByID = pendingByID
        self.rowToItem = rowToItem
        self.inlineNoticesByRow = inlineNoticesByRow
        self.turnActions = turnActions
        noteCompactRowState()
        noteTurnFooterState(groups: groups)
        // Feed the publishers from the rows' full text before any
        // signature/measurement pass reads `codeStreamingText`.
#if AA_TIMELINE_PROBE
        let probeStreamingStart = CACurrentMediaTime()
#endif
        updateCodeStreaming(groups: groups)
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index.streaming", seconds: CACurrentMediaTime() - probeStreamingStart)
#endif
        // Parsed documents are keyed by row id; drop rows that left the
        // timeline so a long session does not retain old replies.
        assistantDocuments = assistantDocuments.filter { rowToItem[$0.key] != nil }
        let streamingNow = ProcessInfo.processInfo.systemUptime
        // Only ownership needs the full present set. When nothing is owned —
        // the Code page's normal state — the ~2,900-row id set is dead work on
        // every stream tick.
        if !rendererRevealOwnership.activeRowIDs.isEmpty {
            rendererRevealOwnership.prune(keeping: Set(model.timeline.rows.map(\.id)))
        }
        for rowID in Array(rendererRevealOwnership.activeRowIDs) {
            guard let timeline = revealTimelines[rowID], timeline.total > 0 else { continue }
            if timeline.shownThrough(at: streamingNow) < timeline.total {
                revealCaughtUpAt.removeValue(forKey: rowID)
                continue
            }
            let caught = revealCaughtUpAt[rowID] ?? streamingNow
            revealCaughtUpAt[rowID] = caught
            if streamingNow - caught > 1.5 { rendererRevealOwnership.finish(rowID) }
        }
        // Same set the full scan used to build, from the sources that already
        // know it: live wire text rows (fed above), owned rows, publishers,
        // and reveal cursors still behind their received text.
        var streamingRowIDs = liveStreamingRowIDs
        streamingRowIDs.formUnion(rendererRevealOwnership.activeRowIDs)
        streamingRowIDs.formUnion(codeStreamingPublishers.keys)
        for (rowID, timeline) in revealTimelines
        where timeline.total > 0 && timeline.shownThrough(at: streamingNow) < timeline.total {
            streamingRowIDs.insert(rowID)
        }
        streamingDocuments = streamingDocuments.filter { streamingRowIDs.contains($0.key) }
        streamingBuilders = streamingBuilders.filter { streamingRowIDs.contains($0.key) }
        streamingFallbacks.formIntersection(streamingRowIDs)
        revealTimelines = revealTimelines.filter { streamingRowIDs.contains($0.key) }
        revealCaughtUpAt = revealCaughtUpAt.filter { streamingRowIDs.contains($0.key) }

        var itemsByID: [String: TimelineListItem] = [:]
        for item in identity.items { itemsByID[item.itemID] = item }
        self.itemsByID = itemsByID
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.index", seconds: CACurrentMediaTime() - probeIndexStart)
#endif

        var signatures: [TimelineListItem: TimelineContentSignature] = [:]
        var entries: [TimelineContentEntry] = []
        entries.reserveCapacity(identity.items.count)
#if AA_TIMELINE_PROBE
        let probeSignatureStart = CACurrentMediaTime()
#endif
        for item in identity.items {
            let signature = makeSignature(for: item)
            signatures[item] = signature
            entries.append(TimelineContentEntry(item: item, signature: signature))
        }
#if AA_TIMELINE_PROBE
        TimelineProbeStore.shared.noteStage(
            "adapter.signature", seconds: CACurrentMediaTime() - probeSignatureStart)
#endif
        // Send-frame probe (pp 2026-11-16): the standalone working row and the
        // pending bubble come from two sources — `session.pendingMessages`
        // (synchronous) and the presentation's `pendingMessages` (published on
        // its own tick). Whichever lands in a later apply grows the content
        // inside the running follow, so it never gets its own entrance: one
        // send reads "bubble lands, working row follows", the next reads
        // "working row already there". One line per item-set change names the
        // order and the two sources; read it beside `timeline.mover`.
        // The frame log needs two Sets and their diff. Its trigger is an
        // identity move, so hash the ordered ids first (allocation-free) and
        // build the Sets only when the hash moved this refresh.
        var itemsFrameHasher = Hasher()
        itemsFrameHasher.combine(identity.items.count)
        for item in identity.items { itemsFrameHasher.combine(item.itemID) }
        let nextItemsFrameHash = itemsFrameHasher.finalize()
        if nextItemsFrameHash != lastItemsFrameHash {
            lastItemsFrameHash = nextItemsFrameHash
            let previousItemIDs = Set(itemsValue.map(\.itemID))
            let nextItemIDs = Set(identity.items.map(\.itemID))
            if previousItemIDs != nextItemIDs {
                ClientDiagnosticsLog.shared.record(
                    kind: "timeline.rows.frame",
                    sessionID: model.session.id,
                    detail: [
                        "added": identity.items.map(\.itemID)
                            .filter { !previousItemIDs.contains($0) }.joined(separator: ","),
                        "removed": itemsValue.map(\.itemID)
                            .filter { !nextItemIDs.contains($0) }.joined(separator: ","),
                        "items": String(identity.items.count),
                        "working": model.isAwaitingReply ? "1" : "0",
                        "workingText": workingStatusShowsText ? "1" : "0",
                        "pendingSession": model.session.pendingMessages.map(\.id).joined(separator: ","),
                        "pendingTimeline": model.timeline.pendingMessages.map(\.id).joined(separator: ","),
                        "awaiting": model.session.awaitingReplyID != nil ? "1" : "0",
                        "queue": String(model.session.sendQueue.items.count),
                        "running": model.isRunning ? "1" : "0",
                        "status": String(describing: model.session.runtime.state?.status),
                    ],
                    dedupe: false)
            }
        }
        itemsValue = identity.items
        signaturesByItem = signatures
        if estimateCache.count > 256 { estimateCache.removeAll(keepingCapacity: true) }
        let contentChanged = entries != lastEntries
        // A history page that actually prepended rows installs its absolute
        // target before `reloadFromContent` reads this generation and applies
        // the snapshot. A page that returned nothing is dropped on timeout.
        // Only a changed snapshot will produce the update that consumes the
        // owed target; firing on an unchanged refresh would leave it behind.
        if let request = pendingHistoryRequest {
            // The controller's history-paging mode gives up after 15 s; while
            // it owns the request the marker must outlive that bound, or a
            // slow page (device report 2026-10-31 13:46: a local page took
            // 7.0 s) loses its reading anchor before it arrives and is applied
            // as an ordinary prepend with no offset correction. The legacy
            // path without a paging controller keeps the short marker.
            let markerTimeout: TimeInterval = controller?.historyPaging == true ? 20 : 5
            if Date.now.timeIntervalSince(request.createdAt) >= markerTimeout {
                pendingHistoryRequest = nil
                // The owed target belongs to a page that never arrived; drop
                // it so a later unrelated update cannot consume it.
                controller?.cancelHistoryRequest()
            } else if contentChanged, let first = identity.items.first,
                      rowIDs(in: first).first != request.beforeFirstRowID {
                pendingHistoryRequest = nil
#if AA_TIMELINE_PROBE
                TimelineProbeStore.shared.noteHistory(
                    "adapter page detected ms=\(Int(((CACurrentMediaTime() - probeRefreshStart) * 1000).rounded())) "
                    + "n=\(identity.items.count) first=\(rowIDs(in: first).first ?? "-") "
                    + "oldFirst=\(request.beforeFirstRowID) hist=\(controller?.historyPaging == true ? 1 : 0)")
#endif
                if controller?.historyPaging == true {
                    // v2: the driver owns the reading anchor; the apply only
                    // needs to know that this snapshot carries the page.
                    controller?.noteHistoryPageArriving(
                        firstRowID: rowIDs(in: first).first)
                } else if let origin = pendingHistoryOrigin {
                    _ = controller?.beginHistoryRequest(generation: request.generation,
                        anchorRowID: request.anchorRowID, edge: request.edge,
                        newItems: identity.items, origin: origin)
                }
            }
        }
        if contentChanged {
            lastEntries = entries
            generation &+= 1
        }
#if AA_TIMELINE_PROBE
        if probeHadHistoryRequest || controller?.historyPaging == true {
            TimelineProbeStore.shared.noteHistory(
                "adapter refresh ms=\(Int(((CACurrentMediaTime() - probeRefreshStart) * 1000).rounded())) "
                + "changed=\(contentChanged ? 1 : 0) n=\(identity.items.count) "
                + "first=\(identity.items.first.flatMap { rowIDs(in: $0).first } ?? "-") "
                + "hist=\(controller?.historyPaging == true ? 1 : 0) "
                + "pending=\(pendingHistoryRequest != nil ? 1 : 0)")
        }
#endif
#if DEBUG
        if identity.hasDuplicates {
            // Data defect: the first occurrence renders. One line, ids only.
            let duplicates = identity.duplicateGroupIDs + identity.duplicateNoticeIDs + identity.duplicatePendingIDs
            NSLog("timeline duplicates: %@", duplicates.joined(separator: ","))
        }
#endif
        noteQueueHandoffIfNeeded()
    }

    /// Viewport numbers are logged with `-1` when unmeasured. A NaN can slip
    /// through a viewport mid-rebuild and must not read as a real size
    /// (device 2026-11-21: `contentH=nan` on a session switch).
    private func viewportLogValue(_ value: CGFloat?) -> String {
        guard let value, value.isFinite else { return "-1" }
        return String(format: "%.1f", value)
    }

    /// Diagnostic probe for the queued-send handoff (device 2026-11-14).
    ///
    /// The page moved and a settled row looked active exactly when a queued
    /// message was sent. One line per queue roster change, carrying the
    /// viewport numbers, the working-status gates and every step group the
    /// drawn pose would animate — the next occurrence can then be read
    /// instead of guessed.
    private func noteQueueHandoffIfNeeded() {
        let roster = model.session.sendQueue.items
            .map { "\($0.id):\($0.state)" }.joined(separator: ",")
        guard roster != lastQueueProbeRoster else { return }
        let previous = lastQueueProbeRoster
        lastQueueProbeRoster = roster
        let viewport = controller?.viewport
        let posing = stepGroupsByID.values.filter {
            $0.showsRunningPose(
                isLiveTail: $0.id == chatLiveTailGroupID,
                isMarkOwner: $0.id == chatMarkOwnerGroupID,
                allowsRunningPose: chatRunningPoseGroupIDs.contains($0.id))
        }
        ClientDiagnosticsLog.shared.record(
            kind: "timeline.queue.handoff",
            sessionID: model.session.id,
            detail: [
                "from": previous ?? "none",
                "to": roster.isEmpty ? "empty" : roster,
                "head": model.session.sendQueue.head.map { "\($0.id):\($0.state)" } ?? "none",
                "echo": {
                    guard let head = model.session.sendQueue.head else { return "none" }
                    let present = model.timeline.rows.contains { row in
                        row.value.role == .user
                            && row.value.source["clientMessageId"]?.stringValue == head.id
                    }
                    return present ? "1" : "0"
                }(),
                "tailH": {
                    guard let controller,
                          let height = controller.tailCellHeight() else { return "-1" }
                    return String(format: "%.1f", height)
                }(),
                "working": lastHasWorkingStatus ? "1" : "0",
                "offsetY": viewportLogValue(viewport?.offsetY),
                "contentH": viewportLogValue(viewport?.contentHeight),
                "visibleH": viewportLogValue(viewport?.visibleHeight),
                "atBottom": {
                    guard let viewport, viewport.isMeasured else { return "0" }
                    return viewport.visibleBottom >= viewport.contentHeight - 1 ? "1" : "0"
                }(),
                "running": model.isRunning ? "1" : "0",
                "streaming": model.isTranscriptStreaming ? "1" : "0",
                "placeholder": model.isAwaitingReply ? "1" : "0",
                "statusLine": tailStatusLineVisible ? "1" : "0",
                "fresh": model.session.runtime.isFresh ? "1" : "0",
                "stopRequested": model.session.runtime.stopRequested ? "1" : "0",
                "predictedIdle": model.session.runtime.predictedIdle ? "1" : "0",
                "status": String(describing: model.session.runtime.state?.status),
                "liveTail": chatLiveTailGroupID ?? "none",
                "posing": posing.map(\.id).joined(separator: ","),
                "posingRunning": posing.filter(\.isRunning).map(\.id).joined(separator: ","),
            ])
    }

    // MARK: - Working status exit

    /// Starts the official 0.4 s exit. The item stays in the identity, so the
    /// diffable snapshot does not delete the cell, and the observable flag
    /// updates the mounted row in place (no reconfigure).
    private func beginWorkingStatusExit() {
        workingStatusIsExiting = true
        workingStatusExitWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.finishWorkingStatusExit()
        }
        workingStatusExitWorkItem = work
        // `beginWorkingStatusExit` runs inside the SwiftUI update that reads
        // the model. Mutating an `@Observable` a mounted view reads must wait
        // for the next runloop turn (the same rule as
        // `useRendererOwnedReveal`); the 0.4 s removal starts from that same
        // turn so the animation and the removal stay aligned.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.workingStatusIsExiting else { return }
            // The mounted row sees the false edge without a reconfigure, so
            // `WorkingMarkView` keeps its identity and plays the 0.4 s group.
            if self.workingStatusExitState.isRunning {
                self.workingStatusExitState.isRunning = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.workingStatusExitDuration,
                                          execute: work)
        }
    }

    /// A new turn's status takes over while the old mark is leaving (or the
    /// adapter is done with it): drop the pending removal and keep the row
    /// running. The observable flip restarts the flipbook in place; nil exit
    /// animation makes the mark snap back (no reconfigure). Also deferred for
    /// the same mid-update rule.
    private func cancelWorkingStatusExit() {
        workingStatusExitWorkItem?.cancel()
        workingStatusExitWorkItem = nil
        workingStatusIsExiting = false
        // Normal path: the finished exit already reset the flag. Only a turn
        // that starts inside the 0.4 s window finds it false; flip it on the
        // next runloop turn (the same mid-update rule).
        guard !workingStatusExitState.isRunning else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.workingStatusIsExiting else { return }
            if !self.workingStatusExitState.isRunning {
                self.workingStatusExitState.isRunning = true
            }
        }
    }

    /// Main-thread timer callback. A new turn may have started in the window
    /// (the SwiftUI update that shows it has not run yet); clearing the flag
    /// and refreshing makes that refresh keep the row as running. For a real
    /// exit the refresh drops the item from the identity and the controller
    /// applies the deletion. Timer cleanup: a page that left the foreground
    /// applies deferred (the controller parks the snapshot) — no view is
    /// touched off-screen; a rebuilt list creates a new adapter, and the weak
    /// self makes this closure a no-op.
    private func finishWorkingStatusExit() {
        workingStatusExitWorkItem = nil
        guard workingStatusIsExiting else { return }
        workingStatusIsExiting = false
        // The next working block anchors its own verb phase.
        workingStatusPhaseStart = nil
        forceRefresh()
        controller?.reloadFromContent()
        // Do NOT flip `isRunning` back here: the deletion apply can be parked
        // behind an in-flight snapshot, and the still-mounted, fully faded
        // mark would pop back to scale 1 for a frame. `cancelWorkingStatusExit`
        // is the only reset point, when a new turn actually takes over.
    }

    /// Resolves an itemID (`"g:…"` / `"n:…"` / `"p:…"`); the reader anchor is
    /// captured in this space, so restoring must not go through the bare-row
    /// `rowToItem` map.
    func item(forItemID itemID: String) -> TimelineListItem? {
        itemsByID[itemID]
    }

    // MARK: - Signatures

    private func makeSignature(for item: TimelineListItem) -> TimelineContentSignature {
        switch item {
        case .olderPrompt:
            return .olderPrompt(pullReady: olderPullReady, isLoading: isLoadingOlder,
                                keepsPrompt: keepsOlderPrompt, hasOlderItems: model.session.canLoadOlder)
        case .latestPrompt:
            return .latestPrompt(pullReady: latestPullReady, isLoading: isLoadingLatest,
                                 hasNewerItems: model.session.hasNewerItems)
        case .workingStatus:
            // Stable on purpose: the official 0.4 s exit (§6) is delivered to
            // the mounted row through the `@Observable` state box. A signature
            // change would reconfigure the cell, rebuild its hosting
            // configuration and reset `WorkingMarkView`, so the freshly
            // mounted stopped mark would never play the exit.
            return .workingStatus
        case .notice(let id):
            guard let notice = tailNoticesByID[id] else {
                return .notice(id: id, status: .unknown, revision: 0)
            }
            return .notice(id: id, status: notice.notice.status, revision: notice.notice.revision)
        case .pending(let id):
            guard let pending = pendingByID[id] else {
                return .pending(id: id, attachments: [], deliveryState: 0)
            }
            return .pending(id: id,
                            attachments: attachmentSignatures(
                                pending.attachments.map(\.content), clientID: pending.id),
                            deliveryState: Self.pendingDeliveryState(pending.delivery))
        case .tail:
            return .tail(tailSignature())
        case .group(let id):
            guard let group = groupsByID[id] else { return .group(Self.emptyGroupSignature) }
            return .group(groupSignature(group))
        }
    }

    /// A stable token for the pending send's lifecycle. Only a state that
    /// changes what the row draws matters: a failed upload turns its
    /// document into an `ArtifactPreviewCard`, which changes the height.
    private static func pendingDeliveryState(_ delivery: V2PendingMessage.Delivery) -> Int {
        switch delivery {
        // `.sending` and `.accepted` draw the same spinner; they do not
        // change the layout and must not re-key the row.
        case .sending, .accepted: return 0
        case .confirmed: return 1
        case .uncertain: return 2
        case .rejected: return 3
        }
    }

    private static func groupContextRevision(cwd: String?,
                                             profile: CodeRuntimeProfile) -> Int {
        var hasher = TimelineStableHasher()
        hasher.combine(cwd ?? "")
        hasher.combine(profile.family.rawValue)
        hasher.combine(profile.subagentShape.rawValue)
        hasher.combine(profile.toolRowRole.rawValue)
        return hasher.revision
    }

    /// The standalone compaction divider group: one marker row, no explicit
    /// message key. It draws the divider and nothing turn-scoped.
    private func compactGroupRow(_ id: String) -> ChatTimelineRowModel? {
        guard let group = groupsByID[id], group.isStandaloneCompactDivider else { return nil }
        return group.rows[0]
    }

    private func groupSignature(_ group: ChatTimelineGroup) -> TimelineGroupContentSignature {
        // The chat profile's step row draws the live step's text, so its
        // signature follows the drawn line (not the wire revision, which the
        // Code path deliberately avoids hashing per frame).
        if let stepGroup = stepGroupsByID[group.id] {
            return stepGroupSignature(stepGroup)
        }
        // The compaction divider draws one label: no turn action, suppression
        // or notice reaches it. The generic signature hashed the turn state,
        // so every turn-status change re-keyed the row and forced a fresh
        // estimate→measure pass — the divider moved on its own with the anchor
        // following (pp 2026-11-15). Sign only the marker row itself.
        if let row = compactGroupRow(group.id) {
            return TimelineGroupContentSignature(
                rows: [TimelineRowContentSignature(id: row.id,
                                                   revision: row.value.revision,
                                                   updatedSeq: row.value.updatedSeq)],
                inlineNotices: [],
                attachments: [],
                turnAction: nil,
                turnSuppression: TimelineTurnSuppression(
                    isRunning: false, hasNewerItems: false,
                    hasPendingUserMessage: false))
        }
        // The Code row renders only its rows and those rows' attachments. The
        // generic signature also hashes the turn action, suppression and
        // inline notices; none of them reach `CodeMessageRowView`, and hashing
        // the turn state re-keyed every group when a turn ended (probe
        // 2026-10-23: one apply reconfigured 192 rows, dropping every measured
        // height). Keep the Code signature to what the row draws. The working
        // status is its own row now, so it is not signed here either.
        if group.explicitID != nil {
            // The official data layer publishes whole snapshots on the 0.1 s
            // leading-edge throttle (CANONICAL/03-streaming.md §5.1); a row is
            // reconfigured by that publish, not by every wire frame. The
            // server reserves a new `revision` for every stream frame
            // (`server/agent_server/services/timeline_write_buffer.py:393-438`),
            // so signing `revision/updatedSeq` on a live row forced a
            // full-table apply + reconfigure per network frame (P1-2). A live
            // row is signed by its published text instead; every row that is
            // not streaming keeps the wire signature untouched, so non-Code
            // and settled rows do not change their refresh semantics.
            var signatureRows = group.rows.map { row -> TimelineRowContentSignature in
                    // Reasoning streams a new wire revision per delta, but the
                    // row is invisible until it settles. Sign it by its
                    // rendered state so a thinking run does not reconfigure
                    // the whole Code row every network frame.
                    if row.value.isReasoning {
                        return TimelineRowContentSignature(
                            id: row.id,
                            revision: row.value.status == .done ? 1 : 0,
                            updatedSeq: 0)
                    }
                    if row.value.isStreamingText,
                       let publisher = codeStreamingPublishers[row.id] {
                        // The publisher's own counter changes exactly when a
                        // new snapshot is produced; hashing the full text here
                        // repeated that O(n) work on every refresh (R6 P1-1).
                        // The reveal revision moves when the drawn prefix
                        // advances between snapshots (the replay after a tab
                        // returns would otherwise never repaint).
                        return TimelineRowContentSignature(
                            id: row.id,
                            revision: publisher.publishRevision
                                &* 1_000_003 &+ (codeRevealRevisions[row.id] ?? 0),
                            updatedSeq: 0)
                    }
                    if let completed = codeCompletedStreamingTexts[row.id] {
                        // The settled row still draws the completion snapshot
                        // until the persisted text covers it (P1-2), so that
                        // snapshot is its drawn content. `-1` marks the state
                        // as "completed snapshot" so it can never collide with
                        // the row's wire signature. The reveal revision is
                        // folded in for the same reason as the live branch.
                        return TimelineRowContentSignature(
                            id: row.id,
                            revision: Self.publishedTextRevision(completed)
                                &* 1_000_003 &+ (codeRevealRevisions[row.id] ?? 0),
                            updatedSeq: -1)
                    }
                    if codePendingReplays[row.id] != nil {
                        // A message that arrived while the tab was hidden is
                        // settling up its tail replay; the drawn prefix moves
                        // even though the wire row is already done. `-2`
                        // cannot collide with a wire revision or the
                        // completed-snapshot marker above.
                        return TimelineRowContentSignature(
                            id: row.id,
                            revision: Self.publishedTextRevision(row.value.displayText)
                                &* 1_000_003 &+ (codeRevealRevisions[row.id] ?? 0),
                            updatedSeq: -2)
                    }
                    return TimelineRowContentSignature(id: row.id,
                                                       revision: row.value.revision,
                                                       updatedSeq: row.value.updatedSeq)
            }
            // The interrupted notice is part of this row's drawn height; a
            // synthetic row makes the collection reconfigure when it appears
            // even though the wire rows did not change.
            if renderMode == .steps,
               chatInterruptedItemIDs.contains(TimelineListItem.group(group.id).itemID) {
                signatureRows.append(TimelineRowContentSignature(
                    id: group.id + ":interrupted", revision: 1, updatedSeq: 0))
            }
            return TimelineGroupContentSignature(
                rows: signatureRows,
                revealingRowIDs: [],
                inlineNotices: [],
                attachments: codeAttachmentPreviews(group),
                turnAction: nil,
                turnSuppression: TimelineTurnSuppression(
                    isRunning: false, hasNewerItems: false, hasPendingUserMessage: false),
                contextRevision: Self.groupContextRevision(
                    cwd: model.session.metadata?.cwd, profile: codeProfile),
                hasActionBar: actionBarCopyText(for: group.id) != nil)
        }
        var rows: [TimelineRowContentSignature] = []
        rows.reserveCapacity(group.rows.count)
        var revealingRowIDs: [String] = []
        var inlineNotices: [TimelineInlineNoticeSignature] = []
        var attachmentPreviews: [TimelineAttachmentPreviewSignature] = []
        for row in group.rows {
            rows.append(TimelineRowContentSignature(id: row.id, revision: row.value.revision,
                                                   updatedSeq: row.value.updatedSeq))
            if row.isRevealing || rendererRevealOwnership.isActive(row.id) {
                revealingRowIDs.append(row.id)
            }
            for notice in inlineNoticesByRow[row.id] ?? [] {
                inlineNotices.append(TimelineInlineNoticeSignature(id: notice.id,
                    status: notice.notice.status, revision: notice.notice.revision))
            }
            let rowAttachments = attachments(of: row.value)
            if !rowAttachments.isEmpty {
                // Match the row renderer: an optimistic echo without wire
                // attachments falls back to the local store keyed by
                // `clientMessageId`. Resolving with nil here would sign a
                // different file list than the cell draws.
                let clientID = row.value.source["clientMessageId"]?.stringValue
                attachmentPreviews.append(contentsOf:
                    attachmentSignatures(rowAttachments, clientID: clientID))
            }
        }
        let action = turnActions[group.id]
        return TimelineGroupContentSignature(
            rows: rows,
            revealingRowIDs: revealingRowIDs,
            inlineNotices: inlineNotices,
            attachments: attachmentPreviews,
            turnAction: action.map {
                TimelineTurnActionSignature(
                    replyIDs: $0.replies.map(\.id),
                    changeIDs: $0.changes.map(\.id),
                    startsMidTurn: $0.startsMidTurn,
                    replyRevisions: $0.replies.map { $0.value.revision },
                    changeRevisions: $0.changes.map { $0.value.revision })
            },
            turnSuppression: TimelineTurnSuppression(
                isRunning: model.isRunning,
                hasNewerItems: model.session.hasNewerItems,
                hasPendingUserMessage: !model.session.hasNewerItems
                    && (model.timeline.pendingMessages.contains { !$0.isSteer }
                        || model.session.pendingMessages.contains { !$0.isSteer })))
    }

    /// The chat profile's step-group signature: the drawn live line while it
    /// runs, the settled counts once it stops. Hashing the drawn line (not the
    /// full thinking text) keeps the per-refresh cost on the tail only.
    private func stepGroupSignature(_ group: TimelineStepGroup) -> TimelineGroupContentSignature {
        var rows: [TimelineRowContentSignature] = []
        // The trailing group keeps the live pose (mark + current step text)
        // for the whole live turn, even between steps; the signature must
        // follow that drawn state, not only the running steps.
        let isLiveTail = group.id == chatLiveTailGroupID
        let showsLivePose = group.showsRunningPose(
            isLiveTail: isLiveTail,
            isMarkOwner: group.id == chatMarkOwnerGroupID,
            allowsRunningPose: chatRunningPoseGroupIDs.contains(group.id))
        if let live = group.liveStep, showsLivePose {
            var hasher = TimelineStableHasher()
            hasher.combine(live.id)
            hasher.combine(live.status.rawValue)
            switch live {
            case .thinking:
                hasher.combine(live.liveThinkingLine ?? "")
            case let .tool(call):
                hasher.combine(call.name)
                hasher.combine(call.status == .running ? 1 : 0)
            }
            rows.append(TimelineRowContentSignature(id: live.id,
                                                    revision: hasher.revision,
                                                    updatedSeq: 0))
        }
        // The group already carries the summary computed when it was built
        // (same steps, same cwd). Recomputing it here ran one
        // `CodeToolLabelPlan` per step on every refresh (35k calls in a
        // 77 s probe window).
        let summary = group.summary
        var settled = TimelineStableHasher()
        settled.combine(group.steps.count)
        settled.combine(group.hasFailure ? 1 : 0)
        settled.combine(chatInterruptedItemIDs.contains(
            TimelineListItem.group(group.id).itemID) ? 1 : 0)
        settled.combine(summary.thinkingCount)
        settled.combine(summary.readFiles)
        settled.combine(summary.ranCommands)
        settled.combine(summary.editedFiles)
        settled.combine(summary.toolCount)
        // The agent phrase flips present tense while a dispatch runs and back
        // when it settles; without the counts the row never reconfigures and
        // stays on 「正在运行」 after the subagent returns (pp 2026-11-18).
        settled.combine(summary.agentCount)
        settled.combine(summary.activeAgentCount)
        rows.append(TimelineRowContentSignature(id: group.id + ":settled",
                                                revision: settled.revision,
                                                updatedSeq: 0))
        return TimelineGroupContentSignature(
            rows: rows,
            revealingRowIDs: [],
            inlineNotices: [],
            attachments: [],
            turnAction: nil,
            turnSuppression: TimelineTurnSuppression(
                isRunning: false, hasNewerItems: false, hasPendingUserMessage: false))
    }

    /// Signature component of a live row: it changes only when the publisher's
    /// on-screen text changes, i.e. at most once per 0.1 s publish
    /// (CANONICAL/03-streaming.md §5.1), not once per wire revision.
    private static func publishedTextRevision(_ text: String) -> Int {
        var hasher = TimelineStableHasher()
        hasher.combine(text)
        return hasher.revision
    }

    private func tailSignature() -> TimelineTailContentSignature {
        TimelineTailContentSignature(
            queue: model.session.sendQueue.items.map {
                TimelineQueueEntrySignature(id: $0.id, state: String(describing: $0.state))
            },
            isAwaitingReply: model.isAwaitingReply,
            orbActivity: String(describing: model.orbActivity),
            hasNewerItems: model.session.hasNewerItems,
            statusLineVisible: tailStatusLineVisible)
    }

    /// The working status is its own transcript row (`CodeWorkingStatusRow`)
    /// now, so the Code tail must not draw a second indicator.
    private var tailStatusLineVisible: Bool { false }

    /// The official live-turn pose. Only the tail after the last visible-turn
    /// start can hold the running block; a steering row sits inside the turn
    /// and must not cut the walk, so the boundary is `startsVisibleTurn`.
    private func liveWorkingMarkBody() -> WorkingMarkBody {
        // An optimistic user message is newer than every presented row: the
        // official predicate would see it as the last message of the trailing
        // assistant run and find no tool call. Without this the mark would
        // keep the previous turn's pose while the new turn is still waiting.
        // A steer does not open a new turn: it must keep the running tool's
        // pose instead of forcing the neutral think mark (pp 2026-11-17).
        guard !model.timeline.pendingMessages.contains(where: { !$0.isSteer })
        else { return .think }
        var tail: [CodeWorkingMarkRow] = []
        for row in model.timeline.rows.reversed() {
            let item = row.value
            // A sub-agent's running tools must not pose the main page's mark.
            if SubAgentProgress.parentItemID(item) != nil { continue }
            if item.startsVisibleTurn { break }
            // A steering row is a user message INSIDE the live turn. The
            // pose builder treats every user row as a boundary, so drop it
            // here rather than let it cut the turn's tail.
            if item.role == .user { continue }
            tail.append(CodeWorkingMarkRow(
                role: item.role,
                isReasoning: item.isReasoning,
                isActive: item.status.isActive,
                toolName: TimelineEntryPresentation.isToolKindItem(item)
                    ? CodeToolCall.wireName(for: item) : nil))
        }
        return CodeWorkingMarkPose.body(rows: Array(tail.reversed()))
    }

    /// The official working-row phase. An active compaction wins, then the
    /// pre-agent connection window, then the rotating verbs. The official
    /// `.server` payload is not displayed (`0x102a8507c` discards it).
    private func liveWorkingStatusPhase(startedAt: Date) -> CodeWorkingStatusPhase {
        if liveTurnIsCompacting() { return .compacting }
        // "Connecting" is reserved for transport that is genuinely not ready.
        // An accepted message waiting for the agent is work in progress, not a
        // connection problem: mapping `awaitingReplyID`/`waiting` here showed
        // "正在连接" after every send and read as a network fault (pp
        // 2026-11-16). Those states now fall through to the working label.
        if !model.session.runtime.isFresh
            || model.session.network.availability == .offline
            || model.session.metadata?.connectorStatus == .offline {
            return .connecting
        }
        // Official precedence (R24 §6.5): `.compacting`/`.connecting` go
        // straight to the working row; only the remaining states consult the
        // thinking text. Nil means the turn has no thinking block to report.
        if let thinking = liveThinkingPhase(startedAt: startedAt) { return thinking }
        return .working(startedAt: startedAt)
    }

    /// The live turn's thinking state, mirroring the official tag-3 activity
    /// (`0x102a88dfc`): while a block runs the five tiers replace the verbs;
    /// for 2 s after it settles the closed label replaces them; afterwards
    /// the caller falls back to the verbs.
    ///
    /// The running anchor is the working block's start (the turn start), not
    /// the thinking item's own creation time — the official branch measures
    /// `now − turnStartedAt` (`0x102a89010`). The closed duration is the
    /// block's own span: the wire's first/last ingest stamps when both are
    /// present, otherwise the span this client observed.
    private func liveThinkingPhase(startedAt: Date) -> CodeWorkingStatusPhase? {
        // An optimistic user message is newer than every presented row: the
        // scan would otherwise read the previous turn's trailing reasoning as
        // the live block and show its closed label at the new turn's start.
        // Same guard as `liveWorkingMarkBody`; a steer keeps the running
        // turn's thinking block (pp 2026-11-17).
        guard !model.timeline.pendingMessages.contains(where: { !$0.isSteer })
        else { return nil }
        guard let item = liveThinkingItem() else {
            liveThinkingRowID = nil
            liveThinkingObservedStart = nil
            liveThinkingClosed = nil
            return nil
        }
        if item.status.isActive {
            if liveThinkingRowID != item.id {
                liveThinkingRowID = item.id
                liveThinkingObservedStart = Date()
                liveThinkingClosed = nil
            }
            return .thinking(startedAt: startedAt)
        }
        if liveThinkingClosed?.id != item.id {
            let observedStart = liveThinkingObservedStart
            // A block this client watched running ends now. A block first
            // seen already settled (reconnect, relaunch, history) ends at its
            // wire stamp, clamped to now so clock skew cannot hold the label.
            let endedAt = observedStart != nil
                ? Date()
                : min(Date(), V2Timestamp.date(item.updatedAt) ?? Date())
            liveThinkingClosed = (
                id: item.id,
                endedAt: endedAt,
                seconds: Self.closedThinkingSeconds(
                    item: item,
                    observedStart: observedStart,
                    observedEnd: endedAt
                )
            )
            liveThinkingRowID = nil
            liveThinkingObservedStart = nil
        }
        guard let closed = liveThinkingClosed else { return nil }
        return .thoughtFor(seconds: closed.seconds,
                           endedAt: closed.endedAt,
                           fallbackStartedAt: startedAt)
    }

    /// The trailing reasoning row of the live turn, if any. The scan stops at
    /// the last visible-turn start, the same live-turn boundary
    /// `liveWorkingMarkBody` uses (a steering row is inside the turn).
    private func liveThinkingItem() -> V2TimelineItem? {
        for row in model.timeline.rows.reversed() {
            let item = row.value
            // The sub-agent's own thinking must not surface as the main
            // turn's closed 「思考了 n 秒」 label (pp 2026-11-16).
            if SubAgentProgress.parentItemID(item) != nil { continue }
            if item.startsVisibleTurn { break }
            if item.isReasoning { return item }
        }
        return nil
    }

    /// Official closed duration (`0x102a88f5c`): `endedAt − startedAt`,
    /// `frinta` (half away from zero), then `max(1, n)`. The wire carries the
    /// server's first/last ingest stamps for the thinking row, which are the
    /// closest analogue of the official block timestamps; if either is
    /// missing, the span this client observed running stands in.
    private static func closedThinkingSeconds(item: V2TimelineItem,
                                              observedStart: Date?,
                                              observedEnd: Date) -> Int {
        if let created = V2Timestamp.date(item.createdAt),
           let updated = V2Timestamp.date(item.updatedAt),
           updated >= created {
            return CodeThinkingText.closedSeconds(updated.timeIntervalSince(created))
        }
        guard let observedStart else { return 1 }
        return CodeThinkingText.closedSeconds(observedEnd.timeIntervalSince(observedStart))
    }

    /// True while the live turn's compact row is active. The connector turns a
    /// CLI `status:"compacting"` frame into this marker
    /// (`connector/connector/runtimes/claude/timeline/markers.py:320-323`).
    private func liveTurnIsCompacting() -> Bool {
        for row in model.timeline.rows.reversed() {
            let item = row.value
            if SubAgentProgress.parentItemID(item) != nil { continue }
            if item.startsVisibleTurn { break }
            if TimelineEntryPresentation.isCompactItem(item) {
                return TimelineEntryPresentation.isActiveCompactItem(item)
            }
        }
        return false
    }

    /// Attachments ride inside the typed content: a message carries a list, an
    /// attachment item carries one. `V2TimelineItem` itself exposes neither.
    private func attachments(of item: V2TimelineItem) -> [V2AttachmentContent] {
        switch item.content {
        case .message(let content): return content.attachments
        case .attachment(let content): return [content]
        default: return []
        }
    }

    private func attachmentSignatures(_ contents: [V2AttachmentContent],
                                      clientID: String? = nil) -> [TimelineAttachmentPreviewSignature] {
        guard !contents.isEmpty else { return [] }
        return model.session.attachmentPreviews.resolve(contents, clientID: clientID).map { attachment in
            let size = attachment.previewPixelSize ?? attachment.content.serverPixelSize
            let width = size.flatMap { $0.width.isFinite && $0.width > 0 ? Int($0.width.rounded()) : nil }
            let height = size.flatMap { $0.height.isFinite && $0.height > 0 ? Int($0.height.rounded()) : nil }
            return TimelineAttachmentPreviewSignature(id: attachment.id,
                                                       pixelWidth: width, pixelHeight: height)
        }
    }

    /// The pixel size the attachment tile will draw at: the locally decoded
    /// preview size when the store has one, otherwise the server's reported
    /// dimensions. `CodeMessageRowView` resolves the same value through the
    /// store, so the measured height and the drawn tile box cannot disagree
    /// when a preview arrives after the wire payload.
    private func attachmentPixelSize(_ content: V2AttachmentContent) -> CGSize? {
        let resolved = model.session.attachmentPreviews.resolve([content]).first
        // The row draws the merge-filled content, so the size fallback must
        // come from that same content, not the raw wire payload.
        return resolved?.previewPixelSize
            ?? resolved?.content.serverPixelSize
            ?? content.serverPixelSize
    }

    /// The attachment identities the Code row draws for one group. Only a
    /// message's own `attachments` reach the Code row (its `.attachment`
    /// items have no attachment block), and the builder hands the row the
    /// wire `clientMessageId` so the store can resolve local previews before
    /// the echo carries the uploaded file ids.
    private func codeAttachmentPreviews(
        _ group: ChatTimelineGroup
    ) -> [TimelineAttachmentPreviewSignature] {
        var previews: [TimelineAttachmentPreviewSignature] = []
        for row in group.rows where row.value.role == .user {
            guard case let .message(content) = row.value.content,
                  !content.attachments.isEmpty else { continue }
            let clientID = row.value.source["clientMessageId"]?.stringValue
            previews.append(contentsOf:
                attachmentSignatures(content.attachments, clientID: clientID))
        }
        return previews
    }

    private func groupHasInteractiveContent(_ group: ChatTimelineGroup) -> Bool {
        if group.kind != .single { return true }
        if group.rows.contains(where: { row in !(inlineNoticesByRow[row.id] ?? []).isEmpty }) { return true }
        let cwd = model.session.metadata?.cwd
        return group.rows.contains { row in
            switch row.entry(cwd: cwd).kind {
            case .reasoning, .compact, .tool: return true
            case .marker:
                // `TimelineEntryPresentation` classifies a plain message as
                // `.marker`; only a real marker row has a fold.
                return row.structure.type != .message
            case .artifact: return false
            }
        }
    }

    private func streamingItemIDs() -> Set<String> {
        var ids: Set<String> = []
        for group in groupsByID.values {
            if group.rows.contains(where: { $0.isRevealing || $0.value.isStreamingText }) {
                ids.insert(TimelineListItem.group(group.id).itemID)
            }
        }
        if model.isAwaitingReply || !model.session.sendQueue.items.isEmpty {
            ids.insert(TimelineListItem.tail.itemID)
        }
        return ids
    }

    private static var emptyGroupSignature: TimelineGroupContentSignature {
        TimelineGroupContentSignature(
            rows: [], revealingRowIDs: [],
            inlineNotices: [], attachments: [],
            turnAction: nil,
            turnSuppression: TimelineTurnSuppression(isRunning: false, hasNewerItems: false,
                                                     hasPendingUserMessage: false))
    }

    // MARK: - Typography

    /// The wrapper's environment wins; this is the pre-first-update fallback so
    /// the initial synchronous measurement uses the same scale as the cell.
    static func currentTypography(scale: ChatTypeScale? = nil) -> TimelineTypographySnapshot {
        typography(dynamicType: UITraitCollection.current.preferredContentSizeCategory.rawValue,
                   layoutDirection: UITraitCollection.current.layoutDirection == .rightToLeft ? 1 : 0,
                   boldText: UIAccessibility.isBoldTextEnabled,
                   scale: scale)
    }

    static func typography(dynamicType: String, layoutDirection: Int, boldText: Bool,
                           scale: ChatTypeScale? = nil) -> TimelineTypographySnapshot {
        let scale = scale ?? ChatTypeSettings.current
        return TimelineTypographySnapshot(
            body: scale.body,
            lineSpacing: scale.lineSpacing,
            paragraphSpacing: scale.paragraphSpacing,
            headings: scale.headings,
            inlineCodeRatio: scale.inlineCodeRatio,
            codeBlockRatio: scale.codeBlockRatio,
            codeBlockLineSpacingRatio: scale.codeBlockLineSpacingRatio,
            inlineCodePin: scale.inlineCodePin,
            codeBlockPin: scale.codeBlockPin,
            inlineCodeBold: ChatColorSettings.inlineCodeBold(),
            boldText: boldText,
            dynamicType: dynamicType,
            layoutDirection: layoutDirection)
    }
}

// MARK: - Working status exit

/// Mutable half of the working row's 0.4 s exit
/// (`CANONICAL/20-working-mark.md` §6). The hosted row reads it, so the
/// true→false edge updates the mounted `WorkingMarkView` in place: the exit
/// group only plays when the view keeps its identity, and a cell reconfigure
/// replaces the hosting configuration and resets its `@State` (the adapter's
/// own tool-detail comment records the same reset; `WorkingMarkView.onAppear`
/// mounts a stopped mark already invisible).
@MainActor @Observable
private final class WorkingStatusExitState {
    var isRunning = true
    /// The official live-turn pose (`SessionDisplay.liveTurnMark`). Updated in
    /// place through the observable box so a running mark swaps its flipbook
    /// without the row being reconfigured.
    var markBody: WorkingMarkBody = .think
    /// The official working-status phase (connecting / compacting / verb
    /// rotation); same in-place update rule.
    var phase: CodeWorkingStatusPhase = .working(startedAt: Date())
    /// False while the send is still unacknowledged: the mark draws alone and
    /// only the server's acknowledgement adds the text (pp 2026-11-16).
    var showsText = true
}

/// The chat profile's step groups, shared with the step-group detail sheet.
///
/// The adapter recomputes the groups on every stream flush; publishing the
/// same dictionary through this observable box lets a presented sheet keep
/// updating — a running step turns into a settled one and newly emitted calls
/// append at the tail, the way the official StepSheet grows while the turn
/// runs (pp 2026-10-30). The tapped snapshot stays the fallback for a group
/// that has left the timeline window.
@MainActor @Observable
final class TimelineLiveStepGroups {
    private(set) var groups: [String: TimelineStepGroup] = [:]

    func publish(_ groups: [String: TimelineStepGroup]) {
        guard groups != self.groups else { return }
        self.groups = groups
    }
}

/// The cell's root for `.workingStatus`. Keeping this view mounted and
/// toggling the observable delivers `isRunning = false` without a reconfigure.
private struct WorkingStatusRowHost: View {
    let state: WorkingStatusExitState
    /// The chat profile replaces the Code page's English verb rotation with
    /// the neutral localized status, shimmered (pp 2026-10-30).
    let usesChatWorkingStyle: Bool

    var body: some View {
        CodeWorkingStatusRow(isRunning: state.isRunning,
                             markBody: state.markBody,
                             phase: state.phase,
                             usesChatWorkingStyle: usesChatWorkingStyle,
                             showsText: state.showsText)
    }
}

// MARK: - History prompts (rendered, not yet loaded in C4)

/// The official `LoadOlderHeader`: a paging sentinel, not a button. It draws
/// only while a page is loading and is otherwise empty — the list loads when
/// the reader nears the top (`LoadsOlderHistoryNearTop`), so there is no
/// tap affordance and no end-of-history label (pp 2026-11-25: match the
/// official row exactly). Geometry from the official device screenshot:
/// spinner 20.3x20.0 pt centred on the column axis, row content 44 pt tall,
/// standard 5 pt row margin above and the paging row's zero list gap below.
private struct TimelineCollectionOlderPromptRow: View {
    let isLoading: Bool

    var body: some View {
        if isLoading {
            // Disassembly of `LoadOlderHeader.body` (build 1.261109.19,
            // 0x101c366cc): `UIActivityIndicatorView(style: .medium)` in a
            // UIViewRepresentable — 20x20 pt, both hugging priorities 1000 —
            // with `.padding(.vertical, 8)` and
            // `.frame(maxWidth: .infinity, alignment: .center)`. No font, no
            // tint; the words are the accessibility label only. Row content is
            // therefore 36 pt (8 + 20 + 8).
            ProgressView()
                .progressViewStyle(.circular)
                .accessibilityLabel(Text(String(localized: "正在加载更早的消息")))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}

private struct TimelineCollectionLatestPromptRow: View {
    let hasNewerItems: Bool
    let isLoading: Bool
    let pullReady: Bool
    let onLoad: (() -> Void)?

    var body: some View {
        if hasNewerItems {
            Button { onLoad?() } label: {
                Group {
                    if isLoading { ProgressView(String(localized: "正在加载更新的记录…")) }
                    else {
                        Text(pullReady ? String(localized: "松开加载更新的记录")
                             : String(localized: "继续上拉加载更新的记录"))
                    }
                }.font(.footnote).frame(maxWidth: .infinity, minHeight: 44)
            }.disabled(onLoad == nil || isLoading)
        }
    }
}

/// The tail block from the SwiftUI timeline: queued messages, the two-tier
/// status spacer and its 12↔32 animation. The 96pt/2pt visibility probes stay
/// in C5, where the controller computes scroll-edge visibility geometrically.
private struct TimelineCollectionTailRow: View {
    let model: SessionChatModel
    /// Opens a queued attachment through the same viewer as a sent bubble.
    let onAttachment: (V2AttachmentContent, UIImage?) -> Void
    /// False while a message row already shows the official working status
    /// line: one turn gets one mark, never two (device report 2026-10-23).
    let showsStatusLine: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A queued message whose echo row is already on screen is the same
    /// message twice: the tail bubble plus the timeline row. Hiding the
    /// bubble in the same apply that inserts the row keeps the bottom height
    /// stable; otherwise the echo adds its height (+49) and the bubble
    /// removal takes it back (−51) in a later layout pass, so the
    /// bottom-pinned page drops by one bubble height (device 2026-11-14).
    /// The rule mirrors `SessionTimelinePresentation.isEchoed`.
    private var visibleQueueItems: [V2QueuedMessage] {
        let echoed = Set(model.timeline.rows.compactMap { row -> String? in
            guard row.value.role == .user else { return nil }
            return row.value.source["clientMessageId"]?.stringValue
        })
        // The drain stages the normal pending bubble for the head (same id).
        // The queue row is only the pre-send shape, so it must stop drawing
        // in the same apply that presents that pending row — one message, one
        // visual object, from queue to echo.
        let pending = Set(model.timeline.pendingMessages.map(\.id))
        return model.session.sendQueue.items.filter {
            !echoed.contains($0.id) && !pending.contains($0.id)
        }
    }

    private var queueRoster: String {
        visibleQueueItems.map { "\($0.id):\($0.state)" }.joined(separator: ",")
    }
    private static let idleHeight: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !visibleQueueItems.isEmpty {
                VStack(spacing: 6) {
                    ForEach(visibleQueueItems) { item in
                        QueuedMessageRow(item: item, model: model,
                                         onAttachment: onAttachment)
                            .id(item.id)
                            // In on the bottom edge, out by fading in place: a drained
                                // queued bubble used to slide *down* toward the
                                // composer while disappearing, which read as
                                // "the bubble jumped under the input box"
                                // (device 2026-11-14).
                                .transition(.asymmetric(
                                    insertion: .move(edge: .bottom).combined(with: .opacity),
                                    removal: .opacity))
                    }
                }
                // No implicit animation for the queue block: the row that drains at
                    // echo time sits inside the tail (the last measured cell), and
                    // animating its removal made the bottom-pinned offset follow a
                    // 0.25 s shrink while the echoed row was still landing — the
                    // page slid down by one bubble height (device 2026-11-14).
                    // Appearing and disappearing are single-layout-pass events.
                    .animation(nil, value: queueRoster)
            }
            Group {
                if showsStatusLine, model.isRunning {
                    // The Code page's working row, not the Chat page's orb:
                    // the flipbook mark plus the rotating `.connecting` verb
                    // (CANONICAL/20-working-mark.md §1–§4).
                    CodeThinkingStatusLine()
                } else { Color.clear }
            }
            .frame(height: showsStatusLine ? 32 : Self.idleHeight)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: showsStatusLine)
        }
    }
}
