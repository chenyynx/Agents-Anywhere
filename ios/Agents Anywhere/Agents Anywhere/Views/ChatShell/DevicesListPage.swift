import SwiftUI

/// Device tab root. Tapping a device pushes its page into this tab's stack;
/// the session pages below it are pushed by the shell's navigation
/// destinations so leaving this tab never drops the drill-down.
struct DevicesListPage: View {
    let devices: [ChatSidebarDevice]
    let isLoading: Bool
    let onMenu: () -> Void
    let onOpen: (V2ConnectorID) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            LazyVStack(spacing: DevicePageStyle.cardGap) {
                if isLoading && devices.isEmpty {
                    ProgressView()
                        .padding(.top, 48)
                } else if devices.isEmpty {
                    Text(String(localized: "No devices"))
                        .font(.footnote)
                        .foregroundStyle(DevicePageStyle.secondary(colorScheme))
                        .padding(.top, 48)
                } else {
                    ForEach(devices) { device in
                        Button { onOpen(device.id) } label: {
                            deviceCard(device)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16.7)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(Color(uiColor: CodePageTheme.pageBackgroundUIColor).ignoresSafeArea())
        .modifier(ChatPageToolbar(title: String(localized: "Devices"), onMenu: onMenu))
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
