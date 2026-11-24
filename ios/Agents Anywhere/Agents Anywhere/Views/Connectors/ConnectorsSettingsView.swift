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
                       sectionSpacing: 0,
                       topPadding: 16) {
            // Official vertical rhythm (2026-11-24 capture): card 1 sits
            // 145..232, the “On this device” header ink 260.3..272, card 2
            // 284.3..459.3 and card 3 475.3..638.7.
            VStack(alignment: .leading, spacing: 0) {
                SettingsSection {
                    discoveryRow
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(String(localized: "On this device"))
                        // Fixed 13 pt: the shared settings header scales with
                        // Dynamic Type and reads one step too large here.
                        .font(ConnectorStyle.text(13))
                        .foregroundStyle(SettingsStyle.header(colorScheme))
                        .padding(.leading, 20)
                        .padding(.bottom, 10)
                    SettingsSection {
                        let tools = ConnectorSettingsData.deviceTools
                        ForEach(Array(tools.enumerated()), id: \.element.id) { index, row in
                            if index > 0 {
                                SettingsRowDivider(leading: ConnectorStyle.logoDividerLeading,
                                                   trailing: ConnectorStyle.logoDividerTrailing)
                            }
                            deviceToolRow(row)
                        }
                    }
                }
                .padding(.top, 26)
                SettingsSection {
                    let servers = ConnectorSettingsData.servers
                    ForEach(Array(servers.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            SettingsRowDivider(leading: ConnectorStyle.logoDividerLeading,
                                               trailing: ConnectorStyle.logoDividerTrailing)
                        }
                        serverRow(row)
                    }
                }
                .padding(.top, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                ConnectorCircleButton(symbol: "chevron.left") { dismiss() }
            }
            // Both keys draw their own system-glass circle; the bar's shared
            // background would draw a second one behind them.
            .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) {
                addMenu
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .navigationDestination(isPresented: $showsDirectory) {
            ConnectorDirectoryView()
        }
        .navigationDestination(item: $route) { route in
            switch route {
            case .server(let server):
                // Installed rows open their connector detail page, like the
                // official app (Gmail → directory detail, my phone → custom
                // detail). Demo ids until the roster lands.
                switch server.id {
                case "gmail":
                    ConnectorDetailView(data: .gmail)
                case "my-phone":
                    ConnectorDetailView(data: .myPhone)
                default:
                    ConnectorToolListView(title: server.name,
                                          toolNames: server.toolNames)
                }
            case .deviceTool(let tool):
                ConnectorPermissionPickerView(title: tool.title,
                                              groups: permissionGroups(for: tool))
            case .addCustom:
                AddCustomConnectorView()
            }
        }
    }

    // MARK: Rows

    /// Connector discovery card. The official toggle is centred on the title
    /// line (not the whole card): title row 28 pt, subtitle directly below.
    private var discoveryRow: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: ConnectorStyle.logoRowGap) {
                ConnectorSymbol(name: "anthropicon.connectors", size: 18)
                    .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                    .frame(width: 28, height: 28)
                Text(String(localized: "Connector discovery"))
                    .font(ConnectorStyle.text(15))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                Spacer(minLength: 12)
                // The custom style does not render `configuration.label`, so
                // the copy lives outside the toggle (found in review).
                Toggle("", isOn: $discoveryEnabled)
                    .labelsHidden()
                    .toggleStyle(ConnectorSwitchStyle())
            }
            Text(String(localized: "Claude will help you find available connectors in your directory."))
                .font(ConnectorStyle.text(11))
                .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                // Official subtitle line pitch 15.6 pt (font 11 → 13.75).
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                // Text column starts under the title (28 + 6) and stops 12 pt
                // before the toggle's 63 pt key.
                .padding(.leading, 34)
                .padding(.trailing, 75)
        }
        .padding(.horizontal, ConnectorStyle.logoRowPadding)
        // Card height 87 pt (official); the block centres inside.
        .frame(height: 87)
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
            HStack(spacing: ConnectorStyle.logoRowGap) {
                ConnectorLogoView(source: .appIcon(row.tool.imageName),
                                  size: ConnectorStyle.deviceIconSize)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 3.5) {
                    Text(row.tool.title)
                        .font(ConnectorStyle.text(15))
                        .foregroundStyle(SettingsStyle.ink(colorScheme))
                    if let subtitle = row.subtitle {
                        Text(subtitle)
                            .font(ConnectorStyle.text(11))
                            .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let value = row.value {
                    Text(value)
                        .font(ConnectorStyle.text(14))
                        .foregroundStyle(ConnectorDetailStyle.secondary(colorScheme))
                        .lineLimit(1)
                        // 15 pt ink gap to the chevron (HStack adds 6).
                        .padding(.trailing, 9)
                }
                if row.opensSystemSettings {
                    // Official calendar row: 15 pt glyph in the link blue
                    // (#184F95), not the switch accent.
                    ConnectorSymbol(name: "anthropicon.arrowOutSquare", size: 15)
                        .foregroundStyle(ConnectorDetailStyle.link(colorScheme))
                        .padding(.trailing, 8)
                } else {
                    settingsChevron
                }
            }
            .padding(.horizontal, ConnectorStyle.logoRowPadding)
            .frame(height: row.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func serverRow(_ row: ConnectorServerRow) -> some View {
        Button {
            route = .server(row)
        } label: {
            HStack(spacing: ConnectorStyle.logoRowGap) {
                ConnectorLogoView(source: row.logo,
                                  size: ConnectorStyle.serverLogoSize,
                                  imageInset: 0.025)
                    .frame(width: 28, height: 28)
                Text(row.name)
                    .font(ConnectorStyle.text(15))
                    .foregroundStyle(SettingsStyle.ink(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 8)
                switch row.trailing {
                case .toolCount(let count):
                    ConnectorCountCapsule(count: count)
                        // 15 pt ink gap to the chevron (HStack adds 6).
                        .padding(.trailing, 9)
                    settingsChevron
                case .connect:
                    // Official “Connect” affordance: 13 pt #7A7974 label and
                    // a 15 pt glyph in the same grey — not accent blue.
                    HStack(spacing: 8) {
                        Text(String(localized: "Connect"))
                            .font(ConnectorStyle.text(13))
                            .foregroundStyle(ConnectorStyle.connectLabel(colorScheme))
                        ConnectorSymbol(name: "anthropicon.arrowOutSquare", size: 15)
                            .foregroundStyle(ConnectorStyle.connectLabel(colorScheme))
                            .padding(.trailing, 8)
                    }
                }
            }
            .padding(.horizontal, ConnectorStyle.logoRowPadding)
            // Official server rows measure 53.7 / 53.7 / 54 pt.
            .frame(height: 53.8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Settings-row chevron: #888781, 8 pt in from the row's trailing edge.
    private var settingsChevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ConnectorStyle.rowChevron(colorScheme))
            .padding(.trailing, 8)
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
    /// Official row heights from the 2026-11-24 capture (three rows split the
    /// 175 pt card at 337.3 and 404.3): 53 / 66 / 54.
    var height: CGFloat = 53

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
                               value: String(localized: "Allowed"),
                               height: 53),
        ConnectorDeviceToolRow(tool: .calendar,
                               subtitle: String(localized: "To allow access to calendar, turn it on in your system settings."),
                               opensSystemSettings: true,
                               height: 66),
        ConnectorDeviceToolRow(tool: .reminders,
                               value: String(localized: "Read & write"),
                               height: 54),
    ]

    /// Sample rows mirrored from the 2026-11-24 capture, in the official
    /// order: Gmail (30 tools) → my phone (4) → Figma (连接). `my phone` is a
    /// user-installed custom MCP server (relay.pipicore.cn), not a built-in —
    /// every field here comes from the roster once the connector backend lands.
    static let servers: [ConnectorServerRow] = [
        ConnectorServerRow(id: "gmail", name: "Gmail",
                           logo: .image("connector-logo-gmail"),
                           trailing: .toolCount(30)),
        // Official “my phone” row renders the letter tile (white 24 pt square,
        // #DDDDDD edge, semibold M), not a bitmap.
        ConnectorServerRow(id: "my-phone", name: "my phone",
                           logo: .letter("M"),
                           trailing: .toolCount(4),
                           toolNames: ["Do", "Look", "Skills", "Status"]),
        ConnectorServerRow(id: "figma", name: "Figma",
                           logo: .image("connector-logo-figma"), trailing: .connect),
    ]
}
