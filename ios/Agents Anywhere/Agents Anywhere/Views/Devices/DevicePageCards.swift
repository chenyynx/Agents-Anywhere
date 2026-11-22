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
    /// Official Code tab stacks cards 10 pt apart (29 px at 3x).
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

    /// Official Code tab secondary: #7A7973 (the settings page's
    /// black-at-58% reads too dark here).
    static func secondary(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xC3 / 255.0, green: 0xC2 / 255.0, blue: 0xB7 / 255.0)
            : Color(red: 0x7A / 255.0, green: 0x79 / 255.0, blue: 0x74 / 255.0)
    }

    /// The device laptop glyph is ink (#0B0B0B light), not the settings row
    /// icon grey.
    static func deviceGlyph(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0xF9 / 255.0, green: 0xF9 / 255.0, blue: 0xF7 / 255.0)
            : Color(red: 0x0B / 255.0, green: 0x0B / 255.0, blue: 0x0B / 255.0)
    }

    /// `ListCardOutlineModifier` draws a 1-physical-pixel #DDDDDD edge;
    /// `RaisedCard` adds black @ 0.08 / radius 4 / y 2. Dark uses #323232 and
    /// a deeper shadow.
    static func cardBorder(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0x32 / 255.0, green: 0x32 / 255.0, blue: 0x32 / 255.0)
            : Color(red: 0xDD / 255.0, green: 0xDD / 255.0, blue: 0xDD / 255.0)
    }

    static func cardShadow(_ scheme: ColorScheme) -> Color {
        Color.black.opacity(scheme == .dark ? 0.20 : 0.08)
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

}

/// The official card surface: white fill, a 1-physical-pixel edge and a downward shadow.
/// The shadow lives on the background shape so text stays crisp.
struct DeviceCardChrome: ViewModifier {
    var cornerRadius: CGFloat = DevicePageStyle.cardRadius
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(DevicePageStyle.card(colorScheme))
                    .shadow(color: DevicePageStyle.cardShadow(colorScheme),
                            radius: 4, x: 0, y: 2)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(DevicePageStyle.cardBorder(colorScheme),
                                  lineWidth: 1 / displayScale)
            }
    }
}

extension View {
    func deviceCardChrome(cornerRadius: CGFloat = DevicePageStyle.cardRadius) -> some View {
        modifier(DeviceCardChrome(cornerRadius: cornerRadius))
    }
}

/// One device in the top row. The reference capture shows no selected ring;
/// the page's nav title already names the device.
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
                    AnthropiconView(name: "anthropicon.laptop", size: .large)
                        .foregroundStyle(DevicePageStyle.deviceGlyph(colorScheme))
                    if online {
                        Circle()
                            .fill(DevicePageStyle.success(colorScheme))
                            .frame(width: 6, height: 6)
                            .offset(x: 1, y: -1)
                    }
                }
                Spacer(minLength: 0)
                Text(connector.name)
                    .font(SettingsStyle.text(15))
                    .foregroundStyle(DevicePageStyle.ink(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(online ? String(localized: "已连接") : String(localized: "离线"))
                    .font(SettingsStyle.text(13))
                    // CJK falls back to PingFang, whose regular strokes read
                    // thinner than the Latin face at this size (pp 2026-11-23).
                    .fontWeight(.medium)
                    .foregroundStyle(online
                        ? DevicePageStyle.success(colorScheme)
                        : DevicePageStyle.secondary(colorScheme))
                    .lineLimit(1)
                    .padding(.top, 4)
            }
            .padding(16)
            .frame(width: DevicePageStyle.deviceCardWidth, alignment: .leading)
            .frame(minHeight: DevicePageStyle.deviceCardHeight, alignment: .leading)
            .deviceCardChrome()
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

/// Official working mark: the `anthropicon.spinner` arc, turning once a
/// second; the still pose holds under Reduce Motion.
struct DeviceWorkingGlyph: View {
    let color: Color
    let isAnimating: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animates: Bool { isAnimating && !reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !animates)) { context in
            let seconds = context.date.timeIntervalSinceReferenceDate
            AnthropiconView(name: "anthropicon.spinner", size: .medium)
                .foregroundStyle(color)
                .rotationEffect(.degrees(animates
                    ? seconds.truncatingRemainder(dividingBy: 1) * 360
                    : 0))
        }
        .frame(width: 20, height: 20)
    }
}

/// Official idle mark: a 20 pt ring dashed into seven round-capped segments
/// (#7A7973, 1.5 pt ring, dash 2.7 / gap 5.6; the round caps bring the ink
/// dash to ~4.2 pt). The official ring is drawn in code, no asset.
struct DeviceIdleRing: View {
    let color: Color

    var body: some View {
        Circle()
            .strokeBorder(color, style: StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                                   dash: [2.7, 5.6]))
            .frame(width: 20, height: 20)
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
            HStack(spacing: 12) {
                DeviceLeadingTile {
                    AppSymbol("anthropicon.agent", size: 18)
                        .foregroundStyle(SettingsStyle.icon(colorScheme))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(DevicePageStyle.ink(colorScheme))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(SettingsStyle.text(15))
                        .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                AnthropiconView(name: "anthropicon.caretRight", size: .medium)
                    .foregroundStyle(DevicePageStyle.secondary(colorScheme).opacity(0.8))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
            .frame(minHeight: 68)
            .deviceCardChrome()
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
        HStack(spacing: 12) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    DeviceLeadingTile {
                        AnthropiconView(name: "anthropicon.folder", size: .large)
                            .foregroundStyle(SettingsStyle.icon(colorScheme))
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Text(name)
                                .font(SettingsStyle.text(15))
                                .foregroundStyle(DevicePageStyle.ink(colorScheme))
                                .lineLimit(1)
                            if pinned {
                                AppSymbol("pin", size: 11)
                                    .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                            }
                        }
                        Text(path)
                            .font(SettingsStyle.text(15))
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
                AppSymbol("anthropicon.edit", size: 19)
                    .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                    .frame(width: 32, height: 40)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "New session"))
            AnthropiconView(name: "anthropicon.caretRight", size: .medium)
                .foregroundStyle(DevicePageStyle.secondary(colorScheme).opacity(0.8))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 15)
        .frame(minHeight: 68)
        .deviceCardChrome()
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
            HStack(spacing: 12) {
                leading
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(title)
                            .font(SettingsStyle.text(15))
                            .foregroundStyle(DevicePageStyle.ink(colorScheme))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if let timeText {
                            Text(timeText)
                                .font(SettingsStyle.text(13))
                                .monospacedDigit()
                                .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        }
                    }
                    HStack(spacing: 4) {
                        AnthropiconView(name: "anthropicon.laptop", size: .small)
                            .foregroundStyle(connectionColor)
                        Text(connectionText)
                            // 15 pt matches the Latin run's visual weight at
                            // regular; the 13 pt device status keeps medium
                            // (pp 2026-11-23 two-step feedback).
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
            .padding(.vertical, 15)
            .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
            .deviceCardChrome()
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
                    DeviceWorkingGlyph(color: markColor, isAnimating: session.status == .running)
                } else {
                    DeviceIdleRing(color: markColor)
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
            HStack(spacing: 12) {
                AppSymbol("anthropicon.add", size: 12)
                Text(String(localized: "新建会话"))
                    .font(SettingsStyle.text(15, weight: .medium))
            }
            .foregroundStyle(AppTheme.sidebarProminentLabel(colorScheme))
            .padding(.horizontal, 17)
            .frame(minWidth: 109, minHeight: DevicePageStyle.fabHeight)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive()
            .tint(AppTheme.sidebarProminentFill(colorScheme)), in: Capsule())
        .accessibilityLabel(String(localized: "新建会话"))
    }
}
