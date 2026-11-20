import Foundation
import Observation

@MainActor @Observable
final class SessionNoticeModel: Identifiable {
    enum Submission: Equatable { case idle, sending(String), accepted, uncertain, unavailable }
    let id: String
    private(set) var notice: V2RuntimeNotice
    private(set) var form: NoticeInputForm?
    private(set) var submission = Submission.idle
    private(set) var error: String?
    var choices: [String: Set<String>] = [:]
    var custom: [String: String] = [:]
    private(set) var customQuestions: Set<String> = []
    /// Questions the user explicitly skipped (`QuestionCard` skip). A skipped
    /// question is left out of the submitted `answers` map.
    private(set) var skipped: Set<String> = []
    var fields: [String: [String: JSONValue]] = [:]
    var composingFields: Set<String> = []
    /// The card leaves the moment the user acts, instead of waiting for the
    /// write's reconciliation round and the server's notice event — that wait
    /// read as a pause before the collapse (pp 2026-11-20). A failed response
    /// clears it, so the card returns carrying the error.
    private(set) var locallyDismissed = false
    /// The notice revision the dismissal was made against; the store keeps it
    /// so a model rebuilt from a stale snapshot stays collapsed.
    private(set) var dismissedRevision: Int?
    @ObservationIgnored private var submittedRevision = 0

    init(_ notice: V2RuntimeNotice) {
        id = notice.id; self.notice = notice; form = NoticeInputForm(notice)
    }
    var hasDraft: Bool { !choices.isEmpty || !custom.isEmpty || !skipped.isEmpty || !fields.isEmpty }
    var isVisible: Bool {
        guard !locallyDismissed, submission != .unavailable else { return false }
        if notice.type == "notification" { return notice.status == .open }
        return notice.type == "interaction" && [.open, .failed, .responding, .responseAccepted, .resolving].contains(notice.status)
    }
    var timelineTargetID: String? {
        notice.source["timelineItemId"]?.stringValue ?? notice.context["timelineItemId"]?.stringValue
    }
    func blocks(_ sessionID: String) -> Bool {
        isVisible && notice.type == "interaction"
            && notice.blocking?.scope == "session" && notice.blocking?.targetId == sessionID
    }
    var expiresAt: Date? { V2Timestamp.date(notice.expiresAt) }
    func isExpired(at now: Date) -> Bool {
        expiresAt.map { $0 <= now } ?? false
    }
    func canRespond(fresh: Bool, at now: Date = Date()) -> Bool {
        fresh && notice.type == "interaction" && [.open, .failed].contains(notice.status)
            && submission == .idle && composingFields.isEmpty && !isExpired(at: now)
    }

    func update(_ next: V2RuntimeNotice) {
        guard next.revision >= notice.revision, next != notice else { return }
        let nextForm = NoticeInputForm(next)
        // Status revisions keep draft answers; changing the action/schema cannot
        // accidentally submit values collected for an obsolete question set.
        if form != nextForm || notice.actions != next.actions {
            choices = [:]; custom = [:]; customQuestions = []; skipped = []; fields = [:]; composingFields = []; submission = .idle; error = nil
            locallyDismissed = false
        }
        if next.revision > submittedRevision && next.status == .failed {
            submission = .idle
            locallyDismissed = false
            error = next.context["error"]?["message"]?.stringValue ?? next.context["error"]?.stringValue
        }
        if submission == .unavailable && next.revision > submittedRevision { submission = .idle }
        notice = next; form = nextForm
    }

    func select(_ optionID: String, question: NoticeInputQuestion) {
        skipped.remove(question.id)
        var selected = choices[question.id] ?? []
        if question.multiple {
            if !selected.insert(optionID).inserted { selected.remove(optionID) }
        } else { selected = [optionID] }
        choices[question.id] = selected
        if !question.multiple { custom[question.id] = nil; customQuestions.remove(question.id) }
    }
    func setCustom(_ text: String, question: NoticeInputQuestion) {
        guard question.allowCustom else { return }
        setCustomSelected(true, question: question)
        custom[question.id] = text
    }
    func setCustomSelected(_ selected: Bool, question: NoticeInputQuestion) {
        guard question.allowCustom else { return }
        if selected {
            skipped.remove(question.id)
            customQuestions.insert(question.id)
            if !question.multiple { choices[question.id] = [] }
        } else {
            customQuestions.remove(question.id); custom[question.id] = nil
        }
    }
    /// Official QuestionCard "skip": leave this question unanswered. The
    /// submitted payload omits it (the CLI then reports only what it got).
    func skip(_ question: NoticeInputQuestion) {
        skipped.insert(question.id)
        choices[question.id] = []
        custom[question.id] = nil
        customQuestions.remove(question.id)
    }
    func isSkipped(_ question: NoticeInputQuestion) -> Bool { skipped.contains(question.id) }
    /// True once the question is answered (option or custom text) or skipped.
    func hasAnswer(_ question: NoticeInputQuestion) -> Bool {
        if skipped.contains(question.id) { return true }
        if !(choices[question.id] ?? []).isEmpty { return true }
        return customQuestions.contains(question.id)
            && !(custom[question.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func isSending(_ action: V2RuntimeNoticeAction) -> Bool { submission == .sending(action.id) }
    var responseError: String? {
        error ?? (notice.status == .failed
            ? notice.context["error"]?["message"]?.stringValue ?? notice.context["error"]?.stringValue : nil)
    }
    func payload(for action: V2RuntimeNoticeAction) -> JSONValue? {
        if form?.actionID == action.id {
            return form?.payload(choices: choices,
                                 custom: custom.filter { customQuestions.contains($0.key) },
                                 skipped: skipped)
        }
        if let schema = action.input.schema {
            return NoticeActionForm(schema: schema, uiSchema: action.input.uiSchema)?.payload(fields[action.id] ?? [:])
        }
        return nil
    }
    func hasValidInput(for action: V2RuntimeNoticeAction) -> Bool {
        if form?.actionID == action.id { return payload(for: action) != nil }
        if action.input.schema != nil { return payload(for: action) != nil || (!action.input.required && fields[action.id, default: [:]].isEmpty) }
        return !action.input.required
    }
    func begin(actionID: String) {
        submittedRevision = notice.revision
        submission = .sending(actionID); error = nil
    }
    func accepted() {
        // A terminal/failed authoritative push can win the race with HTTP.
        if notice.revision > submittedRevision && notice.status == .failed { submission = .idle }
        else { submission = .accepted }
    }
    /// Collapse the card optimistically at tap time. Kept separate from
    /// `begin` because only the surfaces that stand in for the composer (the
    /// question card) hand over the screen; anything that fails to write puts
    /// the card back below.
    func dismissLocally() {
        locallyDismissed = true
        dismissedRevision = notice.revision
    }

    /// Re-apply a dismissal recorded by the store to a model rebuilt from a
    /// snapshot that was taken before (or during) the submit.
    func restoreDismissal(revision: Int) {
        locallyDismissed = true
        dismissedRevision = revision
    }
    func fail(_ failure: Error) {
        if [.resolved, .closed, .expired, .cancelled].contains(notice.status) { return }
        if [.responding, .responseAccepted, .resolving].contains(notice.status) { submission = .accepted; return }
        // The write did not land: give the card back with the error.
        locallyDismissed = false
        let value = V2ClientFailure(failure)
        error = value.message
        let missing = ["not_found", "notice_not_found", "interaction_not_found", "request_not_found", "approval_not_found"]
        if let code = value.code, missing.contains(code) { submission = .unavailable }
        else if V2ClientFailure.isDefiniteWriteRejection(failure) || (notice.revision > submittedRevision && notice.status == .failed) {
            submission = .idle
        } else { submission = .uncertain }
    }
    func acknowledgeUncertain() { if submission == .uncertain { submission = .idle; error = nil } }
}

@MainActor @Observable
final class SessionNoticeStore {
    private(set) var notices: [SessionNoticeModel] = []
    /// The single source of truth for "is there anything left to show": the
    /// notices sheet and its auto-dismiss watch emptiness through this, never
    /// a second copy of the `isVisible` filter.
    var visibleNotices: [SessionNoticeModel] { notices.filter(\.isVisible) }
    var hasDraft: Bool { notices.contains { $0.hasDraft } }
    /// Notice ids the user collapsed optimistically, with the revision they
    /// were dismissed at. A list update can drop a model, and a stale read
    /// that still holds the notice then rebuilds it with no memory — the card
    /// flashed back for a frame (pp 2026-11-21). The map survives that gap.
    private var dismissed: [String: Int] = [:]
    func update(_ values: [V2RuntimeNotice], sessionID: String) {
        for model in notices where model.locallyDismissed {
            if let revision = model.dismissedRevision { dismissed[model.id] = revision }
        }
        let existing = Dictionary(uniqueKeysWithValues: notices.map { ($0.id, $0) })
        let updated = values.filter { $0.sessionId == sessionID }.map { value in
            let model = existing[value.id] ?? SessionNoticeModel(value)
            if let revision = dismissed[value.id],
               value.status != .failed || value.revision <= revision {
                if existing[value.id] == nil {
                    ClientDiagnosticsLog.shared.record(
                        kind: "notice.dismiss.restored",
                        sessionID: sessionID,
                        detail: [
                            "notice": value.id,
                            "revision": String(value.revision),
                            "status": value.status.rawValue,
                        ],
                        dedupe: false)
                }
                model.restoreDismissal(revision: revision)
            }
            model.update(value)
            if model.isVisible { dismissed[value.id] = nil }
            return model
        }
        if notices.map(\.id) != updated.map(\.id) { notices = updated }
    }
    func clear() { notices = [] }
}
