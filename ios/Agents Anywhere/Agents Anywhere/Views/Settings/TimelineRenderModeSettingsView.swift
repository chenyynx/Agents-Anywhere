import SwiftUI

/// 步骤展示: the two transcript presentations (pp 2026-10-29). Both run on the
/// collection engine; the choice only changes how rows are drawn.
struct TimelineRenderModeSettingsView: View {
    @AppStorage(TimelineRenderModeSwitch.key)
    private var renderModeRaw = TimelineRenderMode.code.rawValue

    var body: some View {
        List {
            ForEach(TimelineRenderMode.allCases) { mode in
                Button {
                    renderModeRaw = mode.rawValue
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(mode.title)
                                .foregroundStyle(.primary)
                            Text(mode.detail)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode.rawValue == renderModeRaw {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle(String(localized: "步骤展示"))
        .navigationBarTitleDisplayMode(.inline)
    }
}
