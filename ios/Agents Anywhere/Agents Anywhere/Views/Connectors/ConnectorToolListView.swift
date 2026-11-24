import SwiftUI

/// A connector's tool list, reproduced from the official 1.261109.19 capture
/// (2026-11-24, `05-tools-list.png`): one white card of plain 16 pt tool names
/// with no icons, no chevrons and no tap targets.
///
/// The screen is chrome only for now. Callers inject the names they read from
/// `McpServer.tools`; ``ConnectorToolListData/googleDriveTools`` keeps the 11
/// names from the capture so the screen can be reviewed on its own.
struct ConnectorToolListView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let title: String
    private let toolNames: [String]

    init(title: String = String(localized: "Tools"),
         toolNames: [String] = ConnectorToolListData.googleDriveTools) {
        self.title = title
        self.toolNames = toolNames
    }

    var body: some View {
        SettingsScreen(title: title) {
            SettingsSection {
                ForEach(Array(toolNames.enumerated()), id: \.offset) { index, name in
                    Text(verbatim: name)
                        .font(ConnectorStyle.text(15))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, ConnectorToolListMetrics.rowInset)
                        .frame(minHeight: ConnectorStyle.rowHeight)
                        .overlay(alignment: .bottom) {
                            if index < toolNames.count - 1 { rowDivider }
                        }
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
            }
        }
    }

    /// Official hairlines sit 20 pt inside the card on both sides.
    private var rowDivider: some View {
        SettingsRowDivider(leading: ConnectorToolListMetrics.rowInset,
                           trailing: ConnectorStyle.logoDividerTrailing)
    }
}

/// Geometry measured on the 1179×2556 @3x official capture.
private enum ConnectorToolListMetrics {
    /// Tool names and hairlines start at 108 px = 36 pt from the screen edge,
    /// i.e. 20 pt inside the card's 16 pt margin. The measured row pitch is
    /// 147 px = 49 pt (`ConnectorStyle.rowHeight`); the 1 pt hairline is drawn
    /// on the bottom edge *inside* the row, so the 11-row card totals
    /// 11 × 49 = 539 pt (1617 px) like the capture.
    static let rowInset: CGFloat = 20
}

/// The 11 Google Drive tool names captured on the official tools screen, in
/// the official order.
nonisolated enum ConnectorToolListData {
    static let googleDriveTools: [String] = [
        "copy_file",
        "create_file",
        "download_file_content",
        "get_file_metadata",
        "get_file_permissions",
        "list_recent_files",
        "read_file_content",
        "search_files",
        "share_file",
        "trash_file",
        "update_file",
    ]
}
