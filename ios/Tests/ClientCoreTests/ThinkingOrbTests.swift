import Foundation
import Testing
@testable import ClientCore

/// Pins the Thinking orb's core contracts: the seven `@AppStorage` keys — the
/// persisted strings that outlive any one build — the custom-hex codec, the
/// palette tables and their sampling math, the effect/activity/form tables,
/// and the animation params. Pure numbers only (no SwiftUI): the model carries
/// hex and doubles, and the assertions recompute the same quantities the
/// engine renders, so an edit that shifts a colour or a period fails here, in
/// CI, before it reaches a device.
@Suite @MainActor struct ThinkingOrbTests {

    // MARK: - Settings keys

    /// The full set of seven, verbatim: these strings are what installs store,
    /// and the settings page + orb read them through `@AppStorage`.
    @Test func storageKeysAreThePersistedContract() {
        #expect(OrbSettingsKeys.palette == "agentsAnywhere.orb.palette")
        #expect(OrbSettingsKeys.customHex == "agentsAnywhere.orb.customHex")
        #expect(OrbSettingsKeys.form == "agentsAnywhere.orb.form")
        #expect(OrbSettingsKeys.glow == "agentsAnywhere.orb.glow")
        #expect(OrbSettingsKeys.fixedEffect == "agentsAnywhere.orb.fixedEffect")
        #expect(OrbSettingsKeys.receivePulse == "agentsAnywhere.orb.receivePulse")
        #expect(OrbSettingsKeys.lowPower == "agentsAnywhere.orb.lowPower")
    }

    @Test func resetClearsEveryKeyBackToItsDefault() {
        let name = "aa-orb-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("neon", forKey: OrbSettingsKeys.palette)
        defaults.set(OrbSettingsKeys.encodeCustomHex(["#000000", "#FFFFFF"]), forKey: OrbSettingsKeys.customHex)
        defaults.set(OrbForm.grid.rawValue, forKey: OrbSettingsKeys.form)
        defaults.set(false, forKey: OrbSettingsKeys.glow)
        defaults.set(OrbEffect.orbit.rawValue, forKey: OrbSettingsKeys.fixedEffect)
        defaults.set(false, forKey: OrbSettingsKeys.receivePulse)
        defaults.set(true, forKey: OrbSettingsKeys.lowPower)
        OrbSettingsKeys.reset(in: defaults)
        for key in [OrbSettingsKeys.palette, OrbSettingsKeys.customHex, OrbSettingsKeys.form,
                    OrbSettingsKeys.glow, OrbSettingsKeys.fixedEffect, OrbSettingsKeys.receivePulse,
                    OrbSettingsKeys.lowPower] {
            #expect(defaults.object(forKey: key) == nil, "\(key) survived reset")
        }
    }

    // MARK: - Codec

    @Test func decodeCustomHexKeepsStoredColors() {
        #expect(OrbSettingsKeys.decodeCustomHex("[\"#FF0000\",\"#00FF00\"]") == ["#FF0000", "#00FF00"])
        #expect(OrbSettingsKeys.decodeCustomHex("[\"#112233\",\"#445566\",\"#778899\"]")
            == ["#112233", "#445566", "#778899"])
    }

    /// 坏 JSON、错误形状、空数组或不足 2 色 —— 一律回退默认三色。
    @Test func decodeCustomHexFallsBackToTheDefaultTrio() {
        let trio = ["#007CFF", "#00F6FF", "#DFC8F5"]
        #expect(OrbSettingsKeys.decodeCustomHex("") == trio)
        #expect(OrbSettingsKeys.decodeCustomHex("not json") == trio)
        #expect(OrbSettingsKeys.decodeCustomHex("{}") == trio)
        #expect(OrbSettingsKeys.decodeCustomHex("[]") == trio)
        #expect(OrbSettingsKeys.decodeCustomHex("[\"#FF0000\"]") == trio)
    }

    @Test func customHexRoundTripsThroughJSON() {
        let hex = ["#112233", "#445566", "#778899"]
        #expect(OrbSettingsKeys.decodeCustomHex(OrbSettingsKeys.encodeCustomHex(hex)) == hex)
        #expect(OrbSettingsKeys.encodeCustomHex(hex) == "[\"#112233\",\"#445566\",\"#778899\"]")
    }

    @Test func formResolutionFallsBackToDots() {
        #expect(OrbSettingsKeys.resolvedForm("dots") == .dots)
        #expect(OrbSettingsKeys.resolvedForm("grid") == .grid)
        #expect(OrbSettingsKeys.resolvedForm("") == .dots)
        #expect(OrbSettingsKeys.resolvedForm("nonsense") == .dots)
    }

    @Test func fixedEffectResolutionTreatsEmptyAsFollowStatus() {
        #expect(OrbSettingsKeys.resolvedFixedEffect("") == nil)
        #expect(OrbSettingsKeys.resolvedFixedEffect("scan") == .scan)
        #expect(OrbSettingsKeys.resolvedFixedEffect("calm") == .calm)
        #expect(OrbSettingsKeys.resolvedFixedEffect("nonsense") == nil)
    }

    // MARK: - OrbRGB

    @Test func hexStringParsingIsStrict() {
        #expect(OrbRGB(hexString: "#007CFF") == OrbRGB(0, 124, 255))
        #expect(OrbRGB(hexString: "007CFF") == OrbRGB(0, 124, 255))
        #expect(OrbRGB(hexString: " #007CFF ") == OrbRGB(0, 124, 255))
        #expect(OrbRGB(hexString: "#12345") == nil)
        #expect(OrbRGB(hexString: "#12345678") == nil)
        #expect(OrbRGB(hexString: "#GGGGGG") == nil)
        #expect(OrbRGB(hexString: "") == nil)
        #expect(OrbRGB(hex: 0xDFC8F5) == OrbRGB(223, 200, 245))
    }

    @Test func mixIsLinearChannelwise() {
        #expect(OrbRGB(0, 0, 0).mixed(with: OrbRGB(255, 255, 255), 0.5) == OrbRGB(127.5, 127.5, 127.5))
        #expect(OrbRGB(10, 20, 30).mixed(with: OrbRGB(255, 255, 255), 0) == OrbRGB(10, 20, 30))
        #expect(OrbRGB(10, 20, 30).mixed(with: OrbRGB(255, 255, 255), 1) == OrbRGB(255, 255, 255))
        #expect(OrbRGB.white == OrbRGB(255, 255, 255))
    }

    // MARK: - Palette

    /// The eight shipped colourways, ids in the shipped order — the ids are
    /// persisted by the settings page, so a rename drops installs back to Kimi.
    @Test func paletteTableIsTheEightShippedColorways() {
        #expect(OrbPalette.all.count == 8)
        #expect(OrbPalette.all.map(\.id) == ["kimi", "aurora", "sunset", "lavender", "mint", "amber", "neon", "mono"])
    }

    /// The design table, value by value — dark stops and the deepened light
    /// variants. A hex edit here must move with the design, not slip in.
    @Test func kimiStopsAreTheDesignTable() {
        let kimi = OrbPalette.resolve(id: "kimi", customHex: [])
        #expect(kimi.darkStops == [OrbRGB(0, 124, 255), OrbRGB(0, 161, 255), OrbRGB(160, 218, 247), OrbRGB(223, 200, 245)])
        #expect(kimi.lightStops == [OrbRGB(0, 124, 255), OrbRGB(0, 161, 255), OrbRGB(127, 178, 240), OrbRGB(197, 166, 240)])
        #expect(kimi.isMono == false)
    }

    @Test func sampleAtZeroIsTheFirstStopBothSchemes() {
        let kimi = OrbPalette.resolve(id: "kimi", customHex: [])
        #expect(kimi.sample(0, dark: true) == kimi.darkStops[0])
        #expect(kimi.sample(0, dark: false) == kimi.lightStops[0])
        // h = 0.25 恰在第一段末尾，取整到第二个色标。
        #expect(kimi.sample(0.25, dark: true) == kimi.darkStops[1])
    }

    /// h = 0.125 = 第一段中点：smoothstep(0.5) = 0.5，两色标各半。
    @Test func sampleMidpointsSmoothstepBetweenStops() {
        let kimi = OrbPalette.resolve(id: "kimi", customHex: [])
        #expect(kimi.sample(0.125, dark: true) == OrbRGB(0, 142.5, 255))
        #expect(kimi.sample(0.125, dark: true) == kimi.darkStops[0].mixed(with: kimi.darkStops[1], 0.5))
    }

    /// 取色周期为 1：负值与超过 1 的 h 循环回同一段；最后一段回卷到首色标。
    @Test func sampleWrapsAroundTheCycle() {
        let kimi = OrbPalette.resolve(id: "kimi", customHex: [])
        #expect(kimi.sample(1.125, dark: true) == kimi.sample(0.125, dark: true))
        #expect(kimi.sample(-0.125, dark: true) == kimi.sample(0.875, dark: true))
        #expect(kimi.sample(0.875, dark: true) == OrbRGB(111.5, 162, 250))
        #expect(kimi.sample(-0.125, dark: true) == kimi.darkStops[3].mixed(with: kimi.darkStops[0], 0.5))
    }

    /// 单色没有色标：深色用 242，浅色用 28（设计兜底）。
    @Test func monoFallsBackPerScheme() {
        let mono = OrbPalette.resolve(id: "mono", customHex: [])
        #expect(mono.isMono == true)
        #expect(mono.darkStops.isEmpty && mono.lightStops.isEmpty)
        #expect(mono.sample(0.3, dark: true) == OrbRGB(242, 242, 242))
        #expect(mono.sample(0.3, dark: false) == OrbRGB(28, 28, 28))
    }

    @Test func customResolutionNeedsTwoValidColors() {
        let custom = OrbPalette.resolve(id: "custom", customHex: ["#FF0000", "#00FF00"])
        #expect(custom.id == "custom")
        #expect(custom.darkStops == [OrbRGB(255, 0, 0), OrbRGB(0, 255, 0)])
        #expect(custom.lightStops == custom.darkStops)
        #expect(custom.isMono == false)
        // 只有 1 个有效色（或 2 个无效色）→ 回退默认 Kimi。
        #expect(OrbPalette.resolve(id: "custom", customHex: ["#FF0000"]).id == "kimi")
        #expect(OrbPalette.resolve(id: "custom", customHex: ["nope", "#00FF00"]).id == "kimi")
        #expect(OrbPalette.resolve(id: "custom", customHex: ["nope", "also nope"]).id == "kimi")
    }

    @Test func unknownPaletteIdFallsBackToKimi() {
        #expect(OrbPalette.resolve(id: "turquoise", customHex: []).id == "kimi")
        #expect(OrbPalette.resolve(id: "", customHex: []).id == "kimi")
    }

    // MARK: - Tables

    @Test func effectRawValuesAndSelectableOrder() {
        #expect(OrbEffect.allCases.map(\.rawValue)
            == ["base", "scan", "swirl", "ripple", "gather", "flow", "orbit", "calm"])
        // calm 仅内部使用（回合结束），不进设置页的固定动效菜单。
        #expect(OrbEffect.userSelectable.map(\.rawValue)
            == ["scan", "swirl", "ripple", "gather", "flow", "orbit", "base"])
    }

    /// 七个活动，raw order + 默认动效全表（按 index 配对）。
    @Test func activityTableMatchesTheDesign() {
        #expect(OrbActivity.allCases.map(\.rawValue)
            == ["thinking", "toolRunning", "parallelWork", "waitingForUser", "writing", "summarizing", "finished"])
        #expect(OrbActivity.allCases.map(\.defaultEffect.rawValue)
            == ["swirl", "scan", "orbit", "ripple", "flow", "gather", "calm"])
        #expect(OrbActivity.allCases.count == 7)
    }

    @Test func formRawValues() {
        #expect(OrbForm.allCases.map(\.rawValue) == ["dots", "grid"])
    }

    @Test func pulseDefaultsToOne() {
        #expect(OrbPulse().strength == 1.0)
        #expect(OrbPulse(strength: 0.3).strength == 0.3)
        // 每次新建换新 id：旧值驻留不会误触发。
        #expect(OrbPulse() != OrbPulse())
    }

    // MARK: - Params

    @Test func paramsDefaultsMatchTheDesign() {
        let p = OrbParams()
        #expect(p.spd == orbTau / 7)
        #expect(p.spdMod == 0)
        #expect(p.tilt == 0.36)
        #expect(p.tiltWob == 0)
        #expect(p.roll == 0.35)
        #expect(p.rollWob == 0)
        #expect(p.breath == 0)
        #expect(p.scan == 0)
        #expect(p.swirl == 0)
        #expect(p.rip == 0)
        #expect(p.sc == 0)
        #expect(p.nf == 0)
        #expect(p.band == 0)
        #expect(p.hueRho == 0)
        #expect(p.hueSp == 0)
        #expect(p.fx == 1.0)
        #expect(p.spark == 0.7)
    }

    /// 逐效果抽查全部八条 preset 的关键参数（数值 = 设计定稿）。
    @Test func presetsCarryTheDesignValues() {
        let w = orbTau / 7

        let base = OrbParams.preset(.base)
        #expect(base.fx == 0)
        #expect(base.spark == 0)

        let scan = OrbParams.preset(.scan)
        #expect(scan.scan == 1)
        #expect(scan.spdMod == 0.45)
        #expect(scan.tilt == 0.38)
        #expect(scan.tiltWob == 0.14)
        #expect(scan.rollWob == 0.5)
        #expect(scan.breath == 0.045)
        #expect(scan.hueSp == 0.05)
        #expect(scan.spark == 0.5)

        let swirl = OrbParams.preset(.swirl)
        #expect(swirl.swirl == 1)
        #expect(swirl.spdMod == 0.3)
        #expect(swirl.tilt == 0.5)
        #expect(swirl.tiltWob == 0.1)
        #expect(swirl.rollWob == 0.3)
        #expect(swirl.breath == 0.03)
        #expect(swirl.nf == 0.2)
        #expect(swirl.hueSp == 0.09)
        #expect(swirl.spark == 0.7)

        let ripple = OrbParams.preset(.ripple)
        #expect(ripple.spd == w * 0.45)
        #expect(ripple.spdMod == 0.2)
        #expect(ripple.tilt == 0.3)
        #expect(ripple.breath == 0.05)
        #expect(ripple.rip == 1)
        #expect(ripple.hueRho == 1)
        #expect(ripple.hueSp == 0.04)
        #expect(ripple.spark == 0.5)

        let gather = OrbParams.preset(.gather)
        #expect(gather.spd == w * 0.6)
        #expect(gather.spdMod == 0.35)
        #expect(gather.tilt == 0.4)
        #expect(gather.tiltWob == 0.12)
        #expect(gather.sc == 1)
        #expect(gather.hueSp == 0.06)
        #expect(gather.spark == 1)

        let flow = OrbParams.preset(.flow)
        #expect(flow.spd == w * 0.7)
        #expect(flow.spdMod == 0.3)
        #expect(flow.tilt == 0.42)
        #expect(flow.tiltWob == 0.12)
        #expect(flow.rollWob == 0.4)
        #expect(flow.breath == 0.03)
        #expect(flow.nf == 1)
        #expect(flow.hueSp == 0.1)
        #expect(flow.spark == 0.8)

        let orbit = OrbParams.preset(.orbit)
        #expect(orbit.spd == w * 0.5)
        #expect(orbit.spdMod == 0.1)
        #expect(orbit.tilt == 0.62)
        #expect(orbit.tiltWob == 0.08)
        #expect(orbit.breath == 0.02)
        #expect(orbit.band == 1)
        #expect(orbit.hueSp == 0.03)
        #expect(orbit.spark == 0.6)

        let calm = OrbParams.preset(.calm)
        #expect(calm.spd == w * 0.12)
        #expect(calm.breath == 0.01)
        #expect(calm.spark == 0)
    }

    /// 「减少动态效果」：不旋转（spd）、无随机闪烁（fx/spark）。
    @Test func reducedMotionIsStill() {
        let p = OrbParams.reducedMotion
        #expect(p.spd == 0)
        #expect(p.fx == 0)
        #expect(p.spark == 0)
    }

    /// approach(_, 1) 一步收敛到目标（17 个字段全收敛，误差仅在浮点舍入级；
    /// `a + (b - a)` 对个别数值对会差 1 ulp，如 0.45 → 0.1，故用极紧容差而非逐位相等）。
    /// factor 0 为不动。
    @Test func approachConvergesAtFactorOne() {
        var p = OrbParams.preset(.scan)
        let t = OrbParams.preset(.orbit)
        p.approach(t, 1)
        let pairs: [(Double, Double)] = [
            (p.spd, t.spd), (p.spdMod, t.spdMod), (p.tilt, t.tilt), (p.tiltWob, t.tiltWob),
            (p.roll, t.roll), (p.rollWob, t.rollWob), (p.breath, t.breath), (p.scan, t.scan),
            (p.swirl, t.swirl), (p.rip, t.rip), (p.sc, t.sc), (p.nf, t.nf), (p.band, t.band),
            (p.hueRho, t.hueRho), (p.hueSp, t.hueSp), (p.fx, t.fx), (p.spark, t.spark),
        ]
        #expect(pairs.count == 17)
        for (got, want) in pairs { #expect(abs(got - want) < 1e-12) }

        var still = OrbParams.preset(.scan)
        still.approach(t, 0)
        #expect(still.spd == OrbParams.preset(.scan).spd)
        #expect(still.scan == 1)
    }

    // MARK: - Timing

    @Test func timingConstantsAndWave() {
        #expect(OrbMath.period == 2.8)
        #expect(OrbMath.active == 0.8)
        #expect(OrbMath.ease(0) == 0)
        #expect(OrbMath.ease(0.5) == 0.5)
        #expect(OrbMath.ease(1) == 1)
        #expect(OrbMath.wave(0) == 0)
        #expect(abs(OrbMath.wave(OrbMath.period * 0.8) - 1) < 1e-9)
        #expect(abs(OrbMath.wave(OrbMath.period * 0.4) - 0.5) < 1e-9)
        #expect(orbTau == 2.0 * Double.pi)
        #expect(orbHash(0) == 0)
        for i in 0..<16 {
            let h = orbHash(Double(i) + 0.37)
            #expect(h >= 0 && h < 1, "orbHash(\(i)) = \(h)")
        }
    }
}
