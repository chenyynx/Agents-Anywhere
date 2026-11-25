import SwiftUI

/// Device tab root. Tapping a device pushes its page into this tab's stack;
/// the session pages below it are pushed by the shell's navigation
/// destinations so leaving this tab never drops the drill-down.
struct DevicesListPage: View {
    let devices: [ChatSidebarDevice]
    let isLoading: Bool
    /// Dashboard fetch failure while there is nothing to show (cold start
    /// offline); an empty list alone must not read as "no devices".
    var error: String? = nil
    let onMenu: () -> Void
    let onOpen: (V2ConnectorID) -> Void
    var onRetry: () async -> Void = {}
    var onPair: () -> Void = {}
    /// Long-press menu on a device card, replacing the sidebar row's action.
    var onCopyId: (V2ConnectorID) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DevicePageStyle.cardGap) {
                if isLoading && devices.isEmpty {
                    ProgressView()
                        .padding(.top, 48)
                } else if devices.isEmpty, let error {
                    VStack(spacing: 12) {
                        Text(error)
                            .font(.footnote)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        Button(String(localized: "重试")) {
                            Task { await onRetry() }
                        }
                        .font(.footnote.weight(.medium))
                    }
                    .padding(.top, 48)
                    .padding(.horizontal, 24)
                } else if devices.isEmpty {
                    VStack(spacing: 12) {
                        Text(String(localized: "No devices"))
                            .font(.footnote)
                            .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        // The drawer no longer carries the pairing entry in
                        // the tab shell, so an empty list must offer it here.
                        Button(String(localized: "添加设备")) { onPair() }
                            .font(.footnote.weight(.medium))
                    }
                    .padding(.top, 48)
                } else {
                    ForEach(devices) { device in
                        Button { onOpen(device.id) } label: {
                            deviceCard(device)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { onOpen(device.id) } label: {
                                Label(String(localized: "Open"), menuSymbol: "anthropicon.folderOpen")
                            }
                            Divider()
                            Button { onCopyId(device.id) } label: {
                                Label(String(localized: "Copy device ID"), menuSymbol: "anthropicon.copy")
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16.7)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .refreshable { await onRetry() }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
        .modifier(ChatPageToolbar(title: String(localized: "Devices"), onMenu: onMenu))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button(String(localized: "添加设备"), systemImage: "plus") { onPair() }
                } label: {
                    AppSymbol("anthropicon.dotsHorizontal", size: 15)
                }
                .accessibilityLabel(String(localized: "Device actions"))
            }
        }
    }

    private func deviceCard(_ device: ChatSidebarDevice) -> some View {
        HStack(spacing: 12) {
            Image("anthropicon.laptop")
                .resizable()
                .scaledToFit()
                .frame(width: 20, height: 20)
                .foregroundStyle(DevicePageStyle.deviceGlyph(colorScheme))
                .frame(width: DevicePageStyle.tileSize, height: DevicePageStyle.tileSize)
                .background(DevicePageStyle.tile(colorScheme), in: .rect(cornerRadius: DevicePageStyle.tileRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(DevicePageStyle.ink(colorScheme))
                HStack(spacing: 5) {
                    Circle()
                        .fill(presenceColor(device.presence))
                        .frame(width: 7, height: 7)
                    Text(presenceText(device.presence))
                        .font(.system(size: 13))
                        .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                }
            }
            Spacer(minLength: 8)
            AppSymbol("anthropicon.caretRight", size: 12)
                .foregroundStyle(DevicePageStyle.secondary(colorScheme))
        }
        .padding(14)
        .background(DevicePageStyle.card(colorScheme), in: .rect(cornerRadius: DevicePageStyle.cardRadius))
        .overlay {
            RoundedRectangle(cornerRadius: DevicePageStyle.cardRadius)
                .strokeBorder(DevicePageStyle.cardBorder(colorScheme), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private func presenceText(_ presence: V2ConnectorPresence) -> String {
        switch presence {
        case .online: String(localized: "Online")
        case .offline: String(localized: "Offline")
        case .unknown: String(localized: "Unknown")
        }
    }

    private func presenceColor(_ presence: V2ConnectorPresence) -> Color {
        switch presence {
        case .online: DevicePageStyle.success(colorScheme)
        case .offline, .unknown: DevicePageStyle.secondary(colorScheme)
        }
    }
}
