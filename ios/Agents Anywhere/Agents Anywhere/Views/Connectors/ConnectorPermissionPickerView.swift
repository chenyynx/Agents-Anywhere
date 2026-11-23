import SwiftUI

/// A device tool's permission choice, reproduced from the official
/// 1.261109.19 captures (2026-11-24, `06-permission-location.png` and
/// `08-permission-reminders.png`): one card per access group with the three
/// choices "Never" / "Ask each time" / "Always allow" and a blue checkmark on
/// the selected row.
///
/// The view owns its selection and reports changes through
/// `onSelectionChange`; the device-tool store can persist them once it lands.
/// The model accepts any number of groups, so the same screen renders the
/// single read group of 位置 and the read + write groups of 提醒.
///
/// ```swift
/// ConnectorPermissionPickerView(title: ConnectorDeviceTool.location.title,
///                               groups: ConnectorPermissionPickerData.location)
/// ```
struct ConnectorPermissionPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    private let title: String
    private let onSelectionChange: ((ConnectorPermissionGroup) -> Void)?
    @State private var groups: [ConnectorPermissionGroup]

    init(title: String,
         groups: [ConnectorPermissionGroup],
         onSelectionChange: ((ConnectorPermissionGroup) -> Void)? = nil) {
        self.title = title
        self.onSelectionChange = onSelectionChange
        self._groups = State(initialValue: groups)
    }

    var body: some View {
        SettingsScreen(title: title) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                SettingsSection(group.title) {
                    ForEach(Array(group.options.enumerated()), id: \.element.id) { optionIndex, option in
                        optionRow(option, groupIndex: index)
                            .overlay(alignment: .bottom) {
                                if optionIndex < group.options.count - 1 { rowDivider }
                            }
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

    // MARK: Rows

    private func optionRow(_ option: ConnectorPermissionOption,
                           groupIndex: Int) -> some View {
        let isSelected = groups[groupIndex].selection == option
        return Button {
            select(option, inGroupAt: groupIndex)
        } label: {
            HStack(spacing: 8) {
                Text(option.title)
                    .font(SettingsStyle.text(16))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isSelected {
                    // UNVERIFIED: dark mode has no official capture; the accent
                    // dark value is projected by `ConnectorStyle`.
                    // UNVERIFIED: symbol point size inferred from the measured
                    // 36 px (12×12 pt) checkmark ink box.
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ConnectorStyle.accent(colorScheme))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, ConnectorPermissionPickerMetrics.rowInset)
            .frame(minHeight: ConnectorStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Official hairlines sit 20 pt inside the card on both sides.
    /// `SettingsRowDivider` exposes only its leading inset (trailing is fixed
    /// at 14 pt), so the remaining 6 pt are added outside it.
    private var rowDivider: some View {
        SettingsRowDivider(leading: ConnectorPermissionPickerMetrics.rowInset)
            .padding(.trailing, ConnectorPermissionPickerMetrics.dividerTrailingExtra)
    }

    // MARK: Selection

    private func select(_ option: ConnectorPermissionOption, inGroupAt index: Int) {
        guard groups.indices.contains(index),
              groups[index].options.contains(option),
              groups[index].selection != option else { return }
        groups[index].selection = option
        onSelectionChange?(groups[index])
    }
}

/// Geometry measured on the 1179×2556 @3x official captures: 147 px = 49 pt
/// row pitch with the 1 pt hairline drawn on the bottom edge *inside* the row
/// (the 3-row card totals 147 pt = 441 px), text and hairlines 108 px = 36 pt
/// from the screen edge (20 pt inside the card's 16 pt margin), checkmark ink
/// 36×36 px = 12×12 pt ending 24 pt before the card's trailing edge.
private enum ConnectorPermissionPickerMetrics {
    static let rowInset: CGFloat = 20
    /// `SettingsRowDivider` already insets 14 pt; the official line ends
    /// 20 pt inside the card.
    static let dividerTrailingExtra: CGFloat = 6
}

/// One choice in a permission group.
nonisolated enum ConnectorPermissionOption: String, CaseIterable, Identifiable {
    case never
    case askEachTime
    case alwaysAllow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .never: String(localized: "Never")
        case .askEachTime: String(localized: "Ask each time")
        case .alwaysAllow: String(localized: "Always allow")
        }
    }
}

/// One access group on the permission screen (read / write). `title` is the
/// localized section header; `options` and `selection` are the rows and the
/// checked one.
nonisolated struct ConnectorPermissionGroup: Identifiable {
    let title: String
    var options: [ConnectorPermissionOption]
    var selection: ConnectorPermissionOption

    /// Group titles are unique on a screen ("Allow read access" /
    /// "Allow write access").
    var id: String { title }
}

/// Group data matching the two official captures. "每次询问" is selected in
/// every group on both screens.
nonisolated enum ConnectorPermissionPickerData {
    /// 位置 (`06-permission-location.png`): one read group.
    static let location: [ConnectorPermissionGroup] = [
        ConnectorPermissionGroup(title: String(localized: "Allow read access"),
                                 options: ConnectorPermissionOption.allCases,
                                 selection: .askEachTime),
    ]

    /// 提醒 (`08-permission-reminders.png`): read and write groups.
    static let reminders: [ConnectorPermissionGroup] = [
        ConnectorPermissionGroup(title: String(localized: "Allow read access"),
                                 options: ConnectorPermissionOption.allCases,
                                 selection: .askEachTime),
        ConnectorPermissionGroup(title: String(localized: "Allow write access"),
                                 options: ConnectorPermissionOption.allCases,
                                 selection: .askEachTime),
    ]
}
