import Foundation

/// The compact relative stamp the official Code session card carries on its
/// trailing edge ("jetzt", "4m", "1h", "2T"). The official reference is
/// `REFERENCES/device/code_tab_list_light_de_1170x2532.png`; Chinese keeps the
/// same shape ("刚刚 / 4分钟 / 1小时 / 2天") instead of a date.
nonisolated enum DeviceSessionTime {
    static func compact(_ date: Date?, now: Date = Date()) -> String? {
        guard let date else { return nil }
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return String(localized: "刚刚") }
        if seconds < 3_600 { return String(localized: "\(Int(seconds / 60))分钟") }
        if seconds < 86_400 { return String(localized: "\(Int(seconds / 3_600))小时") }
        return String(localized: "\(Int(seconds / 86_400))天")
    }
}

/// The sub-line's connection word. `V2SessionMeta.connectorStatus` is the
/// per-session presence the server reports; the device page's own connector
/// status can be fresher, but the row should describe the session, as the
/// official card does with "Verbunden · kalle".
nonisolated enum DeviceSessionConnection {
    static func text(_ presence: V2ConnectorPresence) -> String {
        switch presence {
        case .online: String(localized: "已连接")
        case .offline: String(localized: "离线")
        case .unknown: String(localized: "未知")
        }
    }

    static func isConnected(_ presence: V2ConnectorPresence) -> Bool {
        presence == .online
    }
}

/// Which statuses own a live ring versus the idle dashed circle.
nonisolated enum DeviceSessionActivity {
    static func isRunning(_ status: V2RuntimeStatus) -> Bool {
        switch status {
        case .running, .waiting, .waitingApproval, .pending, .stopping, .blocked:
            true
        case .idle, .error, .disconnected, .unknown:
            false
        }
    }

    /// Idle rows stay grey like the official dashed circle; only states that
    /// ask the user for something borrow the alert colours.
    static func isAlert(_ status: V2RuntimeStatus) -> Bool {
        switch status {
        case .waitingApproval, .blocked, .error:
            true
        default:
            false
        }
    }
}
