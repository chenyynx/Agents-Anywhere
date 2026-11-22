import SwiftUI
import UIKit

/// Geometry and colours for the card device page, measured from the official
/// Code tab reference `REFERENCES/device/code_tab_list_light_de_1170x2532.png`
/// (1170×2532 = 390 pt @3x): 16.7 pt content inset, 24 pt card radius, 10 pt
/// between session cards, 163×99 pt device cards, 36 pt leading tiles and a
/// 150×44 pt floating button 25 pt from the trailing edge. Dark values come
/// from the companion Japanese capture under `REFERENCES/round2/device/`.
nonisolated enum DevicePageStyle {
    static let cardRadius: CGFloat = 24
    static let cardGap: CGFloat = 10
    static let deviceCardWidth: CGFloat = 163
    static let deviceCardHeight: CGFloat = 99
    static let tileSize: CGFloat = 36
    static let tileRadius: CGFloat = 10
    static let fabHeight: CGFloat = 44
    static let fabTrailing: CGFloat = 25

    static func card(_ scheme: ColorScheme) -> Color {
        SettingsStyle.card(scheme)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        SettingsStyle.ink(scheme)
    }

    static func secondary(_ scheme: ColorScheme) -> Color {
        SettingsStyle.secondary(scheme)
    }

    /// Official "Verbunden" green: #409027 on the light capture, a brighter
    /// green on the dark capture.
    static func success(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x5B / 255.0, green: 0xD7 / 255.0, blue: 0x5B / 255.0)
            : Color(red: 0x40 / 255.0, green: 0x90 / 255.0, blue: 0x27 / 255.0)
    }

    /// The 36 pt leading tile behind the session mark: #F3F3F0 official light.
    static func tile(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color(red: 0xF3 / 255.0, green: 0xF3 / 255.0, blue: 0xF0 / 255.0)
    }

    /// The official floating button is dark on light and white on dark.
    static func fabFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xF8 / 255.0, green: 0xF8 / 255.0, blue: 0xF6 / 255.0)
            : Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0)
    }

    static func fabInk(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : .white
    }
}

/// One device in the top row. The current device carries a quiet ink border so
/// the page's sections stay attributable; every other card switches device.
struct DeviceIdentityCard: View {
    let connector: V2Connector
    let isCurrent: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var online: Bool { connector.status == .online }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    AppSymbol("anthropicon.computer", size: 20)
                        .foregroundStyle(SettingsStyle.icon(colorScheme))
                    if online {
                        Circle()
                            .fill(DevicePageStyle.success(colorScheme))
                            .frame(width: 7, height: 7)
                            .offset(x: 3, y: -2)
                    }
                }
                Spacer(minLength: 0)
                Text(connector.name)
                    .font(SettingsStyle.text(16, weight: .semibold))
                    .foregroundStyle(DevicePageStyle.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(online ? String(localized: "已连接") : String(localized: "离线"))
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(online
                        ? DevicePageStyle.success(colorScheme)
                        : DevicePageStyle.secondary(colorScheme))
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(width: DevicePageStyle.deviceCardWidth, alignment: .leading)
            .frame(minHeight: DevicePageStyle.deviceCardHeight, alignment: .leading)
            .background(DevicePageStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius,
                                             style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius, style: .continuous)
                        .strokeBorder(DevicePageStyle.ink(colorScheme)
                            .opacity(colorScheme == .dark ? 0.32 : 0.14), lineWidth: 1.5)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }
}

/// The 36 pt rounded tile every list card leads with.
struct DeviceLeadingTile<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        content()
            .frame(width: DevicePageStyle.tileSize, height: DevicePageStyle.tileSize)
            .background(DevicePageStyle.tile(colorScheme),
                        in: RoundedRectangle(cornerRadius: DevicePageStyle.tileRadius,
                                             style: .continuous))
    }
}

/// The running mark on a session tile: a thin ring that turns while the turn
/// runs. It holds the official still pose under Reduce Motion.
struct DeviceActivityRing: View {
    let color: Color
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isAnimating && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            ring
                .rotationEffect(.degrees(animates
                    ? seconds.truncatingRemainder(dividingBy: 1) * 360
                    : 0))
        }
        .frame(width: 22, height: 22)
    }

    private var ring: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.22), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.7)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 22, height: 22)
    }
}

/// Agents stay a one-line entry on the page; the full configuration lives in
/// the sheet `DeviceManagementView` presents.
struct DeviceAgentsEntry: View {
    let model: DeviceAgentModel
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var instances: [V2DeviceRuntime] { model.inventory.configuredInstances }

    private var title: String {
        if instances.isEmpty, model.isLoading { return String(localized: "正在查找 Agent…") }
        return instances.isEmpty
            ? String(localized: "添加 Agent")
            : String(localized: "\(instances.count) 个 Agent")
    }

    private var subtitle: String {
        instances.isEmpty
            ? (model.isLoading
                ? String(localized: "连接设备以查看可用 Agent")
                : String(localized: "选择要在这台设备上运行的 Agent"))
            : instances.map(\.sessionDisplayName).joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                DeviceLeadingTile {
                    AppSymbol("anthropicon.agent", size: 18)
                        .foregroundStyle(SettingsStyle.icon(colorScheme))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsStyle.text(16))
                        .foregroundStyle(DevicePageStyle.ink(colorScheme))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DevicePageStyle.secondary(colorScheme).opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(minHeight: 69)
            .background(DevicePageStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius,
                                             style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// A project or workspace row as its own card. The leading area opens the
/// directory; the pencil starts a session there, as on the previous grouped
/// row.
struct DeviceDirectoryCard: View {
    let name: String
    let path: String
    var pinned = false
    var canOpen = true
    let openHint: String
    let onOpen: () -> Void
    let onNewSession: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 13) {
            Button(action: onOpen) {
                HStack(spacing: 13) {
                    DeviceLeadingTile {
                        AppSymbol("folder", size: 18)
                            .foregroundStyle(SettingsStyle.icon(colorScheme))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Text(name)
                                .font(SettingsStyle.text(16))
                                .foregroundStyle(DevicePageStyle.ink(colorScheme))
                                .lineLimit(1)
                            if pinned {
                                AppSymbol("pin", size: 11)
                                    .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                            }
                        }
                        Text(path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!canOpen)
            .accessibilityHint(openHint)
            Button(action: onNewSession) {
                AppSymbol("square.and.pencil", size: 17)
                    .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                    .frame(width: 32, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "New session"))
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DevicePageStyle.secondary(colorScheme).opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 69)
        .background(DevicePageStyle.card(colorScheme),
                    in: RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius,
                                         style: .continuous))
        .contentShape(.rect)
    }
}

/// One session as its own card: status tile, title, relative stamp and the
/// "connected · device · project" line the official Code list shows.
struct DeviceSessionCard: View {
    let session: V2SessionMeta
    let deviceName: String
    let projectName: String?
    let isSelecting: Bool
    let selected: Bool
    let canManage: Bool
    let onTap: () -> Void
    let onArchive: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var connectionText: String {
        DeviceSessionConnection.text(session.connectorStatus)
    }

    private var connectionColor: Color {
        DeviceSessionConnection.isConnected(session.connectorStatus)
            ? DevicePageStyle.success(colorScheme)
            : DevicePageStyle.secondary(colorScheme)
    }

    private var markColor: Color {
        DeviceSessionActivity.isAlert(session.status)
            ? (session.status == .error ? .red : .orange)
            : DevicePageStyle.secondary(colorScheme)
    }

    private var title: String {
        session.title.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled session")
    }

    private var timeText: String? {
        DeviceSessionTime.compact(V2Timestamp.date(session.sortAt ?? session.lastActivityAt ?? session.lastItemAt))
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 13) {
                leading
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(SettingsStyle.text(16, weight: session.unread ? .semibold : .regular))
                            .foregroundStyle(DevicePageStyle.ink(colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let timeText {
                            Text(timeText)
                                .font(SettingsStyle.text(15))
                                .monospacedDigit()
                                .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        }
                    }
                    HStack(spacing: 4) {
                        AppSymbol("anthropicon.computer", size: 12)
                            .foregroundStyle(connectionColor)
                        Text(connectionText)
                            .foregroundStyle(connectionColor)
                        Text(verbatim: "·")
                            .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        Text(deviceName)
                            .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                            .lineLimit(1)
                        if let projectName, !projectName.isEmpty {
                            Text(verbatim: "·")
                                .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                            Text(projectName)
                                .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                                .lineLimit(1)
                        }
                    }
                    .font(SettingsStyle.text(15))
                    .lineLimit(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 69, alignment: .leading)
            .background(DevicePageStyle.card(colorScheme),
                        in: RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius,
                                             style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityValue(session.status.displayName)
        .contextMenu {
            Button(String(localized: "Open"), systemImage: "arrow.up.right") { onTap() }
            Button(session.archived ? String(localized: "Restore") : String(localized: "Archive"),
                systemImage: session.archived ? "tray.and.arrow.up" : "archivebox") { onArchive() }
                .disabled(!canManage || session.id.hasPrefix("local:"))
            Button(String(localized: "Copy session ID"), systemImage: "doc.on.doc") {
                UIPasteboard.general.string = session.id
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if isSelecting {
            AppSymbol(selected ? "checkmark.circle.fill" : "circle", size: 20)
                .foregroundStyle(selected
                    ? DevicePageStyle.ink(colorScheme)
                    : DevicePageStyle.secondary(colorScheme))
                .frame(width: DevicePageStyle.tileSize, height: DevicePageStyle.tileSize)
        } else {
            DeviceLeadingTile {
                if DeviceSessionActivity.isRunning(session.status) {
                    DeviceActivityRing(color: markColor, isAnimating: session.status == .running)
                } else {
                    AppSymbol("circle.dashed", size: 22)
                        .foregroundStyle(markColor)
                }
            }
        }
    }
}

/// The official floating action: dark on light, white on dark.
struct DeviceNewSessionFab: View {
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                AppSymbol("plus", size: 16)
                Text(String(localized: "新建会话"))
                    .font(SettingsStyle.text(16, weight: .semibold))
            }
            .foregroundStyle(DevicePageStyle.fabInk(colorScheme))
            .padding(.horizontal, 20)
            .frame(height: DevicePageStyle.fabHeight)
            .background(Capsule().fill(DevicePageStyle.fabFill(colorScheme)))
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "新建会话"))
    }
}
