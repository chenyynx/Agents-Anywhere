import Foundation

/// The seven `@AppStorage` keys behind the Thinking orb, plus the small codec
/// and reset helpers shared by the status row and the settings page.
///
/// Storage can hold anything: a value written by a newer build, a cleared
/// domain, an empty string. Every reader tolerates that — forms fall back to
/// `.dots`, fixed effects to "follow status", and the custom palette to the
/// default trio of hex colours.
enum OrbSettingsKeys {
    static let palette = "agentsAnywhere.orb.palette"            // String，默认 "kimi"
    static let customHex = "agentsAnywhere.orb.customHex"        // String=JSON ["#RRGGBB",…]，默认 ["#007CFF","#00F6FF","#DFC8F5"]
    static let form = "agentsAnywhere.orb.form"                  // String，默认 OrbForm.dots.rawValue
    static let glow = "agentsAnywhere.orb.glow"                  // Bool，默认 true
    static let fixedEffect = "agentsAnywhere.orb.fixedEffect"    // String，""=跟随状态；默认 ""
    static let receivePulse = "agentsAnywhere.orb.receivePulse"  // Bool，默认 true
    static let lowPower = "agentsAnywhere.orb.lowPower"          // Bool，默认 false

    /// 容错回退 `.dots`：存储里可能是空串、旧版本或未知形态。
    static func resolvedForm(_ raw: String) -> OrbForm { OrbForm(rawValue: raw) ?? .dots }

    /// `""` → nil（跟随任务状态）；未知 raw 同样回退 nil。
    static func resolvedFixedEffect(_ raw: String) -> OrbEffect? {
        raw.isEmpty ? nil : OrbEffect(rawValue: raw)
    }

    /// 解析自定义配色 JSON；坏 JSON / 不足 2 色 → 默认三色。
    static func decodeCustomHex(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let hex = try? JSONDecoder().decode([String].self, from: data),
              hex.count >= 2 else {
            return ["#007CFF", "#00F6FF", "#DFC8F5"]
        }
        return hex
    }

    static func encodeCustomHex(_ hex: [String]) -> String {
        guard let data = try? JSONEncoder().encode(hex),
              let json = String(data: data, encoding: .utf8) else { return "[]" }
        return json
    }

    /// 清 7 键 = 恢复默认（`@AppStorage` 读回各自的默认值）。
    static func reset(in defaults: UserDefaults = .standard) {
        for key in [palette, customHex, form, glow, fixedEffect, receivePulse, lowPower] {
            defaults.removeObject(forKey: key)
        }
    }
}
