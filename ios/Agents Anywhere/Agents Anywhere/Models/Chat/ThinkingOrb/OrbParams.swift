import Foundation

/// 圆周（2π）。Internal：绘制引擎、动效参数与状态文字高光共用同一节奏。
let orbTau = 2.0 * Double.pi

/// 稳定哈希 0...1（参考实现逐字）。Internal：引擎逐点随机量与参数表都用它。
func orbHash(_ i: Double) -> Double {
    let s = sin(i * 12.9898) * 43758.5453
    return s - floor(s)
}

// MARK: - 动效参数

/// 绝对时间驱动的扫描节奏（状态文字高光与球体光带天然同步）。
enum OrbMath {
    static let period = 2.8      // 扫描一轮的周期（秒）
    static let active = 0.8      // 一轮中光带实际移动的比例，其余为停顿
    static func ease(_ q: Double) -> Double { q < 0.5 ? 4 * q * q * q : 1 - pow(-2 * q + 2, 3) / 2 }
    /// 用绝对时间计算，状态文字高光与球体光带天然同步
    static func wave(_ now: TimeInterval) -> Double {
        let p = now.truncatingRemainder(dividingBy: period) / period
        return ease(min(p / active, 1))
    }
}

struct OrbParams {
    var spd = orbTau / 7, spdMod = 0.0
    var tilt = 0.36, tiltWob = 0.0, roll = 0.35, rollWob = 0.0
    var breath = 0.0, scan = 0.0, swirl = 0.0, rip = 0.0, sc = 0.0, nf = 0.0, band = 0.0
    var hueRho = 0.0, hueSp = 0.0, fx = 1.0, spark = 0.7

    mutating func approach(_ t: OrbParams, _ f: Double) {
        func m(_ a: inout Double, _ b: Double) { a += (b - a) * f }
        m(&spd, t.spd); m(&spdMod, t.spdMod); m(&tilt, t.tilt); m(&tiltWob, t.tiltWob)
        m(&roll, t.roll); m(&rollWob, t.rollWob); m(&breath, t.breath); m(&scan, t.scan)
        m(&swirl, t.swirl); m(&rip, t.rip); m(&sc, t.sc); m(&nf, t.nf); m(&band, t.band)
        m(&hueRho, t.hueRho); m(&hueSp, t.hueSp); m(&fx, t.fx); m(&spark, t.spark)
    }

    static func preset(_ e: OrbEffect) -> OrbParams {
        let w = orbTau / 7
        var p = OrbParams()
        switch e {
        case .base:   p.fx = 0; p.spark = 0
        case .scan:   p.spdMod = 0.45; p.tilt = 0.38; p.tiltWob = 0.14; p.rollWob = 0.5; p.breath = 0.045; p.scan = 1; p.hueSp = 0.05; p.spark = 0.5
        case .swirl:  p.spdMod = 0.3; p.tilt = 0.5; p.tiltWob = 0.1; p.rollWob = 0.3; p.breath = 0.03; p.swirl = 1; p.nf = 0.2; p.hueSp = 0.09; p.spark = 0.7
        case .ripple: p.spd = w * 0.45; p.spdMod = 0.2; p.tilt = 0.3; p.breath = 0.05; p.rip = 1; p.hueRho = 1; p.hueSp = 0.04; p.spark = 0.5
        case .gather: p.spd = w * 0.6; p.spdMod = 0.35; p.tilt = 0.4; p.tiltWob = 0.12; p.sc = 1; p.hueSp = 0.06; p.spark = 1
        case .flow:   p.spd = w * 0.7; p.spdMod = 0.3; p.tilt = 0.42; p.tiltWob = 0.12; p.rollWob = 0.4; p.breath = 0.03; p.nf = 1; p.hueSp = 0.1; p.spark = 0.8
        case .orbit:  p.spd = w * 0.5; p.spdMod = 0.1; p.tilt = 0.62; p.tiltWob = 0.08; p.breath = 0.02; p.band = 1; p.hueSp = 0.03; p.spark = 0.6
        case .calm:   p.spd = w * 0.12; p.breath = 0.01; p.spark = 0
        }
        return p
    }

    /// 「减少动态效果」：不旋转、无扫描/闪烁，仅保留极慢的透明度呼吸（在引擎里处理）
    static var reducedMotion: OrbParams {
        var p = OrbParams()
        p.spd = 0; p.fx = 0; p.spark = 0
        return p
    }
}
