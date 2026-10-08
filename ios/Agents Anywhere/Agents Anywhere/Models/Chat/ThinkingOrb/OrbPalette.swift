import Foundation
import SwiftUI

/// One sRGB colour, channels 0...255. Hex data only — the palette tables live
/// in `ClientCore` (compiled for macOS in CI), and the `UIColor`-backed
/// `Color` bridging stays in the iOS-only views.
struct OrbRGB: Equatable {
    var r: Double, g: Double, b: Double   // 0...255
    init(_ r: Double, _ g: Double, _ b: Double) { self.r = r; self.g = g; self.b = b }
    init(hex: UInt32) {
        self.init(Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
    }
    init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }
    static let white = OrbRGB(255, 255, 255)
    func mixed(with o: OrbRGB, _ k: Double) -> OrbRGB {
        OrbRGB(r + (o.r - r) * k, g + (o.g - g) * k, b + (o.b - b) * k)
    }
    func color(_ a: Double = 1) -> Color {
        Color(.sRGB, red: r / 255, green: g / 255, blue: b / 255, opacity: max(0, min(1, a)))
    }
}

/// The eight shipped colourways plus the custom picker's entry. `darkStops`
/// carry the dark-mode look, `lightStops` the deepened light-mode variant.
/// `name` is a `LocalizedStringResource` so the settings page localizes it;
/// `id` is the persisted contract.
struct OrbPalette: Identifiable, Equatable {
    let id: String
    let name: LocalizedStringResource
    let darkStops: [OrbRGB]    // 深色背景用
    let lightStops: [OrbRGB]   // 浅色背景用（相对压深，保证可见）
    var isMono = false

    func stops(dark: Bool) -> [OrbRGB] { dark ? darkStops : lightStops }

    /// h 循环取色（周期 1），相邻色标之间 smoothstep 插值
    func sample(_ h: Double, dark: Bool) -> OrbRGB {
        let s = stops(dark: dark)
        if s.isEmpty { return dark ? OrbRGB(242, 242, 242) : OrbRGB(28, 28, 28) }
        var hh = h.truncatingRemainder(dividingBy: 1)
        if hh < 0 { hh += 1 }
        let n = s.count
        let f = hh * Double(n)
        let a = Int(floor(f)) % n, b = (a + 1) % n
        let u = f - floor(f)
        return s[a].mixed(with: s[b], u * u * (3 - 2 * u))
    }

    private static func p(_ id: String, _ name: LocalizedStringResource, _ d: [UInt32], _ l: [UInt32]) -> OrbPalette {
        OrbPalette(id: id, name: name, darkStops: d.map(OrbRGB.init(hex:)), lightStops: l.map(OrbRGB.init(hex:)))
    }

    /// 8 套预设：颜色 = 设计定稿，逐字保留。
    static let all: [OrbPalette] = [
        p("kimi", "Kimi blue-violet", [0x007CFF, 0x00A1FF, 0xA0DAF7, 0xDFC8F5], [0x007CFF, 0x00A1FF, 0x7FB2F0, 0xC5A6F0]),
        p("aurora", "Aurora", [0x00C2A8, 0x3DE0A0, 0xB3F4A8, 0x00A1FF], [0x00957F, 0x20B97F, 0x7FD28A, 0x0A86D8]),
        p("sunset", "Sunset", [0xFF7A59, 0xFFA45C, 0xFFD1D4, 0xDFC8F5], [0xF2552F, 0xF58A3C, 0xF2A0A8, 0xC5A6F0]),
        p("lavender", "Lavender", [0x7C6CFF, 0xA58BFF, 0xDFC8F5, 0xFFD1D4], [0x5B4BDB, 0x8A6CF0, 0xB79CF0, 0xE79AB8]),
        p("mint", "Mint", [0x00D4A6, 0x7BEFB2, 0xB3F4A8, 0xF4F9A7], [0x00A883, 0x3CC08A, 0x8FD68A, 0xC9CF55]),
        p("amber", "Amber", [0xFFB020, 0xFFD166, 0xF4F9A7, 0xFFD1D4], [0xE08A00, 0xF0A830, 0xD9B84A, 0xE8A0A8]),
        p("neon", "Neon", [0xFF3DCB, 0x7C4DFF, 0x00F6FF, 0xB3F4A8], [0xD81B9B, 0x6A3DE8, 0x00A8C8, 0x5FBF4F]),
        OrbPalette(id: "mono", name: "Mono", darkStops: [], lightStops: [], isMono: true),
    ]

    static func resolve(id: String, customHex: [String]) -> OrbPalette {
        if id == "custom" {
            let c = customHex.compactMap { OrbRGB(hexString: $0) }
            if c.count >= 2 { return OrbPalette(id: "custom", name: "Custom", darkStops: c, lightStops: c) }
        }
        return all.first { $0.id == id } ?? all[0]
    }

    /// 设置页色块预览用
    func previewColors(dark: Bool) -> [Color] {
        let s = stops(dark: dark)
        return s.isEmpty ? [dark ? .white : .black] : s.map { $0.color(1) }
    }
}
