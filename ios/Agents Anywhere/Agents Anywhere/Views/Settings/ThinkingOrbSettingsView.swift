import SwiftUI

struct ThinkingOrbSettingsView: View {
    @AppStorage(OrbSettingsKeys.palette) private var paletteID = "kimi"
    @AppStorage(OrbSettingsKeys.customHex) private var customHexJSON = OrbSettingsKeys.encodeCustomHex(["#007CFF", "#00F6FF", "#DFC8F5"])
    @AppStorage(OrbSettingsKeys.form) private var formRaw = OrbForm.dots.rawValue
    @AppStorage(OrbSettingsKeys.glow) private var glowOn = true
    @AppStorage(OrbSettingsKeys.fixedEffect) private var fixedEffectRaw = ""
    @AppStorage(OrbSettingsKeys.receivePulse) private var receivePulse = true
    @AppStorage(OrbSettingsKeys.lowPower) private var lowPower = false
    @State private var demoActivity: OrbActivity = .thinking
    @State private var demoPulse: OrbPulse?

    var body: some View {
        List {
            Section(String(localized: "Preview")) {
                VStack(spacing: 12) {
                    ThinkingOrbView(activity: demoActivity, size: 110, pulse: demoPulse, fadeWhenFinished: false)
                        .frame(maxWidth: .infinity, minHeight: 140)
                    Picker(String(localized: "Status"), selection: $demoActivity) {
                        ForEach(OrbActivity.allCases) { activity in
                            Text(activity.title).tag(activity)
                        }
                    }
                    Button(String(localized: "Simulate incoming message")) { demoPulse = OrbPulse() }
                        .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }

            Section(String(localized: "Palette")) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(OrbPalette.all) { palette in
                        paletteCell(id: palette.id, name: String(localized: palette.name),
                                    colors: palette.previewColors(dark: true))
                    }
                    paletteCell(id: "custom", name: String(localized: "Custom"),
                                colors: OrbSettingsKeys.decodeCustomHex(customHexJSON).map { Color(orbHex: $0) })
                }
                .padding(.vertical, 4)
                if paletteID == "custom" {
                    HStack(spacing: 12) {
                        ForEach(0..<3, id: \.self) { index in
                            ColorPicker("", selection: customColor(index)).labelsHidden()
                        }
                    }
                }
            }

            Section(String(localized: "Effects")) {
                Toggle(String(localized: "Soft glow"), isOn: $glowOn)
                Picker(String(localized: "Form"), selection: formBinding) {
                    ForEach(OrbForm.allCases) { form in
                        Text(form.title).tag(form)
                    }
                }
                .pickerStyle(.segmented)
                Picker(String(localized: "Motion"), selection: fixedEffectBinding) {
                    Text(String(localized: "Follow status")).tag(OrbEffect?.none)
                    ForEach(OrbEffect.userSelectable) { effect in
                        Text(effect.title).tag(Optional(effect))
                    }
                }
                Toggle(String(localized: "React to incoming messages"), isOn: $receivePulse)
                Toggle(String(localized: "Low power mode (30 fps)"), isOn: $lowPower)
            }

            Section {
                Button(String(localized: "Restore defaults"), role: .destructive) {
                    OrbSettingsKeys.reset()
                }
            }
        }
        .settingsPage(String(localized: "Thinking orb"))
    }

    private var formBinding: Binding<OrbForm> {
        Binding(
            get: { OrbSettingsKeys.resolvedForm(formRaw) },
            set: { formRaw = $0.rawValue }
        )
    }

    private var fixedEffectBinding: Binding<OrbEffect?> {
        Binding(
            get: { OrbSettingsKeys.resolvedFixedEffect(fixedEffectRaw) },
            set: { fixedEffectRaw = $0?.rawValue ?? "" }
        )
    }

    private func paletteCell(id: String, name: String, colors: [Color]) -> some View {
        let selected = paletteID == id
        return Button {
            paletteID = id
        } label: {
            VStack(spacing: 8) {
                Capsule()
                    .fill(LinearGradient(colors: colors.count > 1 ? colors : colors + colors,
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(height: 12)
                HStack(spacing: 6) {
                    Text(name).font(.footnote).foregroundStyle(.primary)
                    if selected { AppSymbol("checkmark", size: 14) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25),
                                  lineWidth: selected ? 2 : 0.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func customColor(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let hex = OrbSettingsKeys.decodeCustomHex(customHexJSON)
                return index < hex.count ? Color(orbHex: hex[index]) : .blue
            },
            set: { color in
                var hex = OrbSettingsKeys.decodeCustomHex(customHexJSON)
                while hex.count < 3 { hex.append("#007CFF") }
                hex[index] = color.orbHex
                customHexJSON = OrbSettingsKeys.encodeCustomHex(hex)
            }
        )
    }
}
