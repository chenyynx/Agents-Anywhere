import Foundation

/// Where each notice surface is drawn. The timeline is for interaction notices
/// only; a notification-type notice ("切换已延后") is a pure notice with no
/// response surface, so it floats as a top toast instead of seating in the
/// timeline (pp 2026-10-16). Kept here, out of the views, so the routing is a
/// pure function the tests can exercise — the same seam `TimelineGrouping`
/// gives the timeline.
enum SessionNoticeRouting {
    /// The notices the timeline tail renders as cards: visible interaction
    /// notices that are not session-blocking and not anchored to a rendered
    /// row. Notification-type notices are excluded — the tail must not seat one
    /// even if a future notification carried no anchor.
    static func tailNotices(_ notices: [SessionNoticeModel], sessionID: String, timelineRowIDs: Set<String>) -> [SessionNoticeModel] {
        notices.filter { notice in
            notice.notice.type != "notification"
                && notice.isVisible
                && !notice.blocks(sessionID)
                && !(notice.timelineTargetID.map(timelineRowIDs.contains) ?? false)
        }
    }

    /// The notices anchored to one timeline row. Only an interaction notice may
    /// anchor; a notification is a top toast and never seats inline.
    static func notices(_ notices: [SessionNoticeModel], sessionID: String, anchoredTo rowID: String) -> [SessionNoticeModel] {
        notices.filter { notice in
            notice.notice.type == "interaction"
                && notice.isVisible
                && !notice.blocks(sessionID)
                && notice.timelineTargetID == rowID
        }
    }
}
