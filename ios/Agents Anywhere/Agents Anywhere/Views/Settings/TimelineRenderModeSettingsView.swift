import SwiftUI

/// 过程展示: the two transcript presentations (pp 2026-10-29). Both run on the
/// collection engine; the choice only changes how rows are drawn.
///
/// A single switch, like the official settings rows (pp 2026-11-13): on is the
/// step-by-step transcript, off merges thinking and tool calls. The footer
/// explains whichever mode is selected.
struct TimelineRenderModeSettingsView: View {
    @AppStorage(TimelineRenderModeSwitch.key)
    private var renderModeRaw = TimelineRenderMode.chat.rawValue

    private var mode: TimelineRenderMode {
        TimelineRenderMode(rawValue: renderModeRaw) ?? .chat
    }

    private var stepByStep: Binding<Bool> {
        Binding(
            get: { mode == .chat },
            set: { renderModeRaw = ($0 ? TimelineRenderMode.chat : .code).rawValue }
        )
    }

    private var footer: String {
        mode.detail + "\n\n" + String(localized: "只改变显示方式，不影响消息内容和 Agent 的执行。")
    }

    var body: some View {
        SettingsScreen(title: String(localized: "Process display")) {
            SettingsSection(footer: footer) {
                SettingsToggleRow(icon: "arrow.down.document",
                                  title: String(localized: "分步展示"),
                                  isOn: stepByStep)
            }
        }
    }
}
