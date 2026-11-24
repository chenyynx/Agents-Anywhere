import SwiftUI
import UIKit

/// Connectors settings list, reproduced from the official 1.261109.19 captures
/// (2026-11-24): connector-discovery toggle, “On this device” device tools and
/// the installed MCP servers.
///
/// The rows below are driven by ``ConnectorSettingsData``; it currently returns
/// the capture samples so the screen can be reviewed against the official
/// screenshots. The MCP roster and device-tool permissions will replace the
/// samples once the connector backend lands.
struct ConnectorsSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var discoveryEnabled = true
    @State private var showsDirectory = false
    @State private var route: ConnectorSettingsRoute?

    var body: some View {
        SettingsScreen(title: String(localized: "Connectors"),
                       sectionSpacing: 16,
                       topPadding: 16) {
            SettingsSection {
                discoveryRow
            }
            SettingsSection(String(localized: "On this device")) {
                let tools = ConnectorSettingsData.deviceTools
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { SettingsRowDivider(leading: ConnectorStyle.logoDividerLeading) }
                    deviceToolRow(row)
                }
            }
            // Official capture: card 1 bottom → card 2 top ≈ 52.7 pt
            // (16 section gap + 12 extra + header 17 + 8).
            .padding(.top, 12)
            SettingsSection {
                let servers = ConnectorSettingsData.servers
                ForEach(Array(servers.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        SettingsRowDivider(leading: ConnectorStyle.logoDividerLeading)
                    }
                    serverRow(row)
                }
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
            }
        }
        .navigationDestination(isPresented: $showsDirectory) {
            ConnectorDirectoryView()
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .server(let server):
                ConnectorToolListView(title: server.name,
                                      toolNames: server.toolNames)
            case .deviceTool(let tool):
                ConnectorPermissionPickerView(title: tool.title,
                                              groups: permissionGroups(for: tool))
            case .addCustom:
                AddCustomConnectorView()
            }
        }
    }

    // MARK: Rows

    private var discoveryRow: some View {
        HStack(spacing: SettingsStyle.iconGap) {
            AppSymbol("anthropicon.connectors", size: 20)
                .frame(width: SettingsStyle.iconFrame)
                .foregroundStyle(SettingsStyle.ink(colorScheme))
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Connector discovery"))
                    .font(SettingsStyle.text(17))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Text(String(localized: "Claude will help you find available connectors in your directory."))
                    .font(SettingsStyle.text(13))
                    .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            // The custom style does not render `configuration.label`, so the
            // copy lives outside the toggle (found in review).
            Toggle("", isOn: $discoveryEnabled)
                .labelsHidden()
                .toggleStyle(ConnectorSwitchStyle())
        }
        .padding(.horizontal, SettingsStyle.rowPadding)
        .padding(.vertical, 12)
        .frame(minHeight: 87)
    }

    private func deviceToolRow(_ row: ConnectorDeviceToolRow) -> some View {
        Button {
            switch row.tool {
            case .location, .reminders:
                route = .deviceTool(row.tool)
            case .calendar:
                // Official row opens the system settings page (the calendar
                // permission is managed by iOS, not by an in-app picker).
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
        } label: {
            HStack(spacing: 2) {
                ConnectorLogoView(source: .appIcon(row.tool.imageName), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.tool.title)
                        .font(SettingsStyle.text(17))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(SettingsStyle.text(13))
                            .foregroundStyle(SettingsStyle.secondary(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(value)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(ConnectorStyle.tertiaryText(colorScheme))
                        .lineLimit(1)
                }
                if row.opensSystemSettings {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(ConnectorStyle.accent(colorScheme))
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme).opacity(0.8))
                }
            }
            .padding(.horizontal, 12)
            // 40 pt icon + 2×9 = 58 pt official row height (measured
            // 175 pt for the three-row card).
            .padding(.vertical, 9)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func serverRow(_ row: ConnectorServerRow) -> some View {
        Button {
            route = .server(row)
        } label: {
            HStack(spacing: ConnectorStyle.logoRowGap) {
                ConnectorLogoView(source: row.logo, size: 28)
                Text(row.name)
                    .font(SettingsStyle.text(17))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                switch row.trailing {
                case .toolCount(let count):
                    ConnectorCountCapsule(count: count)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme).opacity(0.8))
                case .connect:
                    Text(String(localized: "Connect"))
                        .font(SettingsStyle.text(17))
                        .foregroundStyle(SettingsStyle.secondary(colorScheme))
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(ConnectorStyle.accent(colorScheme))
                }
            }
            .padding(.horizontal, ConnectorStyle.logoRowPadding)
            .padding(.vertical, 12)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var addMenu: some View {
        Menu {
            Button {
                showsDirectory = true
            } label: {
                Label(String(localized: "Browse connectors"), systemImage: "square.grid.2x2")
            }
            Button {
                route = .addCustom
            } label: {
                Label(String(localized: "Add custom connector"), systemImage: "plus")
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(SettingsStyle.ink(colorScheme))
                .frame(width: ConnectorStyle.circleKey, height: ConnectorStyle.circleKey)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .accessibilityLabel(Text(String(localized: "Add")))
    }
}

// MARK: - Navigation

private enum ConnectorSettingsRoute: Hashable {
    case server(ConnectorServerRow)
    case deviceTool(ConnectorDeviceTool)
    case addCustom
}

extension ConnectorsSettingsView {
    fileprivate func permissionGroups(for tool: ConnectorDeviceTool) -> [ConnectorPermissionGroup] {
        switch tool {
        case .reminders:
            return ConnectorPermissionPickerData.reminders
        case .location, .calendar:
            return ConnectorPermissionPickerData.location
        }
    }
}

// MARK: - Row data

enum ConnectorDeviceTool: String, CaseIterable, Identifiable {
    case location, calendar, reminders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .location: String(localized: "Location")
        case .calendar: String(localized: "Calendar")
        case .reminders: String(localized: "Reminders")
        }
    }

    var imageName: String { "connector-icon-\(rawValue)" }
}

struct ConnectorDeviceToolRow: Identifiable {
    let tool: ConnectorDeviceTool
    var value: String?
    var subtitle: String?
    var opensSystemSettings = false

    var id: String { tool.rawValue }
}

struct ConnectorServerRow: Identifiable, Hashable {
    enum Trailing: Hashable {
        case toolCount(Int)
        case connect
    }

    let id: String
    let name: String
    var logo: ConnectorLogoView.Source
    var trailing: Trailing
    /// Tool names as reported by this MCP server. Empty until the roster
    /// provides them; the screen must never infer tools from the server name.
    var toolNames: [String] = []
}

/// Capture-sampled rows for the settings screen. Replaced by the live MCP
/// roster / device-tool store when the connector backend lands.
nonisolated enum ConnectorSettingsData {
    static let deviceTools: [ConnectorDeviceToolRow] = [
        ConnectorDeviceToolRow(tool: .location,
                               value: String(localized: "Allowed")),
        ConnectorDeviceToolRow(tool: .calendar,
                               subtitle: String(localized: "To allow access to calendar, turn it on in your system settings."),
                               opensSystemSettings: true),
        ConnectorDeviceToolRow(tool: .reminders,
                               value: String(localized: "Read & write")),
    ]

    /// Sample rows mirrored from the 2026-11-24 capture. `my phone` is a
    /// user-installed custom MCP server (relay.pipicore.cn), not a built-in —
    /// every field here (name, logo, trailing state, tools) comes from the
    /// roster once the connector backend lands.
    static let servers: [ConnectorServerRow] = [
        ConnectorServerRow(id: "my-phone", name: "my phone",
                           logo: .image("connector-logo-myphone"),
                           trailing: .toolCount(4),
                           toolNames: ["Do", "Look", "Skills", "Status"]),
        ConnectorServerRow(id: "figma", name: "Figma",
                           logo: .image("connector-logo-figma"), trailing: .connect),
        ConnectorServerRow(id: "gmail", name: "Gmail",
                           logo: .image("connector-logo-gmail"), trailing: .connect),
    ]
}
