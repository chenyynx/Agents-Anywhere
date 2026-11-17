import SwiftUI

/// 「后续消息处理方式」 — the settings half of the composer delivery choice.
/// The send key's long-press menu writes the same `@AppStorage` value, so the
/// two entry points can never disagree.
struct ComposerSettingsView: View {
    @AppStorage(ComposerDeliverySetting.storageKey) private var deliveryRaw =
        ComposerDeliverySetting.defaultValue.rawValue
    @Environment(\.colorScheme) private var colorScheme

    private var delivery: ComposerDelivery {
        ComposerDeliverySetting.resolve(deliveryRaw)
    }

    var body: some View {
        SettingsScreen(title: String(localized: "编写器")) {
            SettingsSection(footer: String(localized: "运行中发送消息时：引导 = 交给正在运行的任务；排队 = 当前任务结束后再发送。Agent 不支持引导时自动排队。")) {
                ForEach(ComposerDelivery.allCases) { option in
                    Button {
                        deliveryRaw = option.rawValue
                    } label: {
                        HStack(spacing: 0) {
                            Text(option.title)
                                .font(SettingsStyle.text(16))
                                .foregroundStyle(SettingsStyle.ink(colorScheme))
                            Spacer(minLength: 0)
                            if option == delivery {
                                AppSymbol("checkmark", size: 16)
                                    .foregroundStyle(SettingsStyle.controlTint(colorScheme))
                            }
                        }
                        .padding(.horizontal, SettingsStyle.rowPadding)
                        .padding(.vertical, 12)
                        .frame(minHeight: SettingsStyle.rowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(option == delivery ? .isSelected : [])
                    if option != ComposerDelivery.allCases.last {
                        SettingsRowDivider()
                    }
                }
            }
        }
    }
}
