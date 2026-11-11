import SwiftUI

/// 步骤展示: the two transcript presentations (pp 2026-10-29). Both run on the
/// collection engine; the choice only changes how rows are drawn.
struct TimelineRenderModeSettingsView: View {
    @AppStorage(TimelineRenderModeSwitch.key)
    private var renderModeRaw = TimelineRenderMode.code.rawValue

    var body: some View {
        SettingsScreen(title: String(localized: "步骤展示")) {
            SettingsSection {
                ForEach(Array(TimelineRenderMode.allCases.enumerated()), id: \.element.id) { index, mode in
                    if index > 0 {
                        SettingsRowDivider()
                    }
                    SettingsSelectRow(
                        title: mode.title,
                        subtitle: mode.detail,
                        isSelected: mode.rawValue == renderModeRaw
                    ) {
                        renderModeRaw = mode.rawValue
                    }
                }
            }
        }
    }
}
