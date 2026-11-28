import SwiftUI
import UIKit

struct PhoneControlSettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        SettingsScreen(title: String(localized: "手机控制")) {
            if let bridge = appState.phoneBridge {
                SettingsSection(
                    footer: String(localized: "需要先在手机上安装 iCTRL。AA 只转发加密字节，不读取屏幕内容。开启后会在后台保持连接。")
                ) {
                    SettingsToggleRow(
                        icon: "anthropicon.mobilePhone",
                        title: String(localized: "允许 AA 控制本机"),
                        subtitle: String(localized: "通过本机 iCTRL 服务操作 App"),
                        isOn: Binding(
                            get: { bridge.isEnabled },
                            set: { bridge.setEnabled($0) }
                        )
                    )
                }

                SettingsSection(String(localized: "状态")) {
                    SettingsRowLabelContent(
                        icon: "anthropicon.codeBlock",
                        title: String(localized: "iCTRL 服务"),
                        value: ictrlStatusText(bridge.ictrlStatus),
                        showsChevron: false
                    )
                    SettingsRowDivider()
                    SettingsRowLabelContent(
                        icon: "anthropicon.cloud",
                        title: String(localized: "连接"),
                        value: connectionText(bridge.status, computer: bridge.currentComputerName),
                        showsChevron: false
                    )
                    SettingsRowDivider()
                    SettingsRowLabelContent(
                        icon: "anthropicon.computer",
                        title: String(localized: "当前电脑"),
                        value: bridge.currentComputerName ?? "—",
                        showsChevron: false
                    )
                    SettingsRowDivider()
                    SettingsDisclosureRow(
                        icon: "anthropicon.arrowClockwise",
                        title: String(localized: "测试连接"),
                        value: latencyText(bridge.latencyMilliseconds),
                        showsChevron: false
                    ) {
                        bridge.testConnection()
                    }
                }

                if let error = bridge.lastError, !error.isEmpty {
                    SettingsSection {
                        SettingsRowLabelContent(
                            icon: "anthropicon.warning",
                            title: String(localized: "最近错误"),
                            subtitle: error,
                            showsChevron: false
                        )
                    }
                }

                SettingsSection(String(localized: "高级")) {
                    SettingsNavigationRow(
                        icon: "anthropicon.research",
                        title: String(localized: "诊断日志"),
                        destination: DiagnosticsLogSettingsView()
                    )
                }

                SettingsSection(String(localized: "帮助")) {
                    SettingsDisclosureRow(
                        icon: "anthropicon.info",
                        title: String(localized: "iCTRL 未安装？查看安装指南"),
                        showsChevron: true
                    ) {
                        if let url = URL(string: "https://github.com/OpenMinis/iCTRL") {
                            openURL(url)
                        }
                    }
                    SettingsRowDivider()
                    SettingsDisclosureRow(
                        icon: "anthropicon.lockShield",
                        title: String(localized: "什么是手机控制？"),
                        showsChevron: true
                    ) {
                        if let url = URL(string: "https://github.com/OpenMinis/iCTRL") {
                            openURL(url)
                        }
                    }
                }
            } else {
                SettingsSection {
                    Text(String(localized: "登录后可以开启手机控制。"))
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SettingsStyle.rowPadding)
                }
            }
        }
        .onAppear { appState.phoneBridge?.probeIctrl() }
    }

    private func ictrlStatusText(_ status: PhoneBridgeClient.IctrlStatus) -> String {
        switch status {
        case .unknown:
            return String(localized: "未检测")
        case .checking:
            return String(localized: "检测中…")
        case .available:
            return String(localized: "已检测到")
        case .unavailable:
            return String(localized: "未检测到")
        }
    }

    private func connectionText(_ status: PhoneBridgeClient.Status, computer: String?) -> String {
        switch status {
        case .off:
            return String(localized: "已关闭")
        case .connecting:
            return String(localized: "连接中…")
        case .connected:
            return computer == nil
                ? String(localized: "等待电脑")
                : String(localized: "已连接")
        case let .error(message):
            return message
        }
    }

    private func latencyText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "" }
        return "\(milliseconds)ms"
    }
}
