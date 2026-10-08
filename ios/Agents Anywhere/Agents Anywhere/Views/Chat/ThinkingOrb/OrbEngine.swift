import SwiftUI

/// One frame's resolved inputs: everything `ThinkingOrbView` reads from
/// settings + environment before the engine draws.
struct OrbRenderConfig {
    var effect: OrbEffect
    var palette: OrbPalette
    var isDark: Bool
    var glow: Double          // 0 = 关；0.55 = 柔光
    var form: OrbForm
    var reduced: Bool
}

/// The orb's drawing engine, called from inside `Canvas` with a
/// `GraphicsContext`. One instance per orb view; `addPulse` is the only
/// external input and the host never has to know about time. Numbers and
/// formulas are the design-side reference implementation, kept verbatim.
final class OrbEngine {
    struct Dot {
        let x: Double, y: Double, z: Double
        let i: Int
        let sf: Double      // 点大小系数（经纬网格两极收小）
        let h: Double       // 聚散用的随机值
        let rate: Double    // 闪烁频率
        let ph: Double      // 闪烁相位
    }
    private struct Proj {
        var sx = 0.0, sy = 0.0, z3 = 0.0, r = 0.0, a = 0.0
        var yn = 0.0, rho = 0.0, g = 0.0, s = 0.0, rim = 0.0, pw = 0.0
    }
    private struct PulseFrame { var env: Double; var wr: Double }

    private var dots: [Dot] = []
    private var proj: [Proj] = []
    private var order: [Int] = []
    private var builtKey = ""
    private var cur = OrbParams.preset(.scan)
    private var yaw = 0.0, bandYaw = 0.0, hp = 0.0
    private var t0: TimeInterval?
    private var lastT = 0.0
    private var pulses: [(start: Double, strength: Double)] = []
    private var pending: [Double] = []

    /// 收到消息 → 调用一次（宿主不必关心时间）
    func addPulse(strength: Double) { pending.append(strength) }

    private static func makeDot(_ x: Double, _ y: Double, _ z: Double, _ i: Int, _ sf: Double) -> Dot {
        let fi = Double(i)
        return Dot(x: x, y: y, z: z, i: i, sf: sf, h: orbHash(fi + 1),
                   rate: 0.22 + 0.5 * orbHash(fi + 7.3), ph: orbTau * orbHash(fi + 3.1))
    }

    /// 随机点阵：斐波那契球面
    static func fibonacci(_ n: Int) -> [Dot] {
        let g = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = max(0, 1 - y * y).squareRoot()
            let th = g * Double(i)
            return makeDot(cos(th) * r, y, sin(th) * r, i, 1)
        }
    }

    /// 经纬网格：每圈点数相同，两极自然聚成竖条纹
    static func latLong(rings L: Int, perRing M: Int) -> [Dot] {
        var out: [Dot] = []
        var k = 0
        for i in 0..<L {
            let ph = -Double.pi / 2 + Double.pi * (Double(i) + 0.5) / Double(L)
            let y = sin(ph), rr = cos(ph)
            for m in 0..<M {
                let th = orbTau * Double(m) / Double(M)
                out.append(makeDot(cos(th) * rr, y, sin(th) * rr, k, 0.45 + 0.55 * rr))
                k += 1
            }
        }
        return out
    }

    private func ensureDots(form: OrbForm, radius: Double) {
        let big = radius >= 24      // 小图标用精简点数，设置页预览用完整点数
        let key = "\(form.rawValue)-\(big)"
        guard key != builtKey else { return }
        builtKey = key
        switch form {
        case .dots: dots = Self.fibonacci(big ? 300 : 96)
        case .grid: dots = big ? Self.latLong(rings: 15, perRing: 32) : Self.latLong(rings: 8, perRing: 14)
        }
        proj = Array(repeating: Proj(), count: dots.count)
        order = Array(0..<dots.count)
    }

    func render(_ ctx: inout GraphicsContext, size: CGSize, radius R: Double,
                now: TimeInterval, config cfg: OrbRenderConfig) {
        ensureDots(form: cfg.form, radius: R)
        if t0 == nil { t0 = now; lastT = 0 }
        let t = now - (t0 ?? now)
        let dt = min(max(t - lastT, 0), 0.05)
        lastT = t

        // 1. 参数平滑过渡（切换效果/状态时不跳变）
        var target = OrbParams.preset(cfg.effect)
        if cfg.reduced { target = OrbParams.reducedMotion }
        cur.approach(target, 1 - exp(-dt * 4))
        yaw = (yaw + cur.spd * (1 + cur.spdMod * sin(orbTau * t / 3.2)) * dt).truncatingRemainder(dividingBy: orbTau)
        bandYaw += (cur.band * 1.1 - bandYaw * (1 - cur.band) * 1.5) * dt
        if bandYaw > .pi { bandYaw -= orbTau } else if bandYaw < -.pi { bandYaw += orbTau }
        hp = (hp + cur.hueSp * dt).truncatingRemainder(dividingBy: 1)

        // 2. 收到消息脉冲：外扩冲击波 + 整体轻微「弹」一下
        for s in pending { pulses.append((start: t, strength: s)) }
        pending.removeAll()
        pulses.removeAll { t - $0.start > 1.0 }
        if pulses.count > 4 { pulses.removeFirst(pulses.count - 4) }
        var pframes: [PulseFrame] = []
        var pop = 0.0
        for p in pulses {
            let age = t - p.start, u = age / 0.9
            if u < 1 {
                pframes.append(PulseFrame(env: pow(1 - u, 1.3) * p.strength,
                                          wr: 0.12 + 1.55 * (1 - pow(1 - u, 2.2))))
            }
            if age < 0.5 { pop += p.strength * 0.1 * sin(.pi * age / 0.5) }
        }

        // 3. 公共量
        let c = cur, fx = c.fx
        let G = cfg.glow, lit = G > 0, dark = cfg.isDark, mono = cfg.palette.isMono
        let cx = size.width / 2, cy = size.height / 2
        let tilt = c.tilt + c.tiltWob * sin(orbTau * t / 11)
        let roll = c.roll + c.rollWob * sin(orbTau * t / 17)
        let rad = R * (1 + c.breath * sin(orbTau * t / 2.4 - 1.2) + pop)
        let ct = cos(tilt), stl = sin(tilt), cr = cos(roll), sr = sin(roll)
        let scanP = now.truncatingRemainder(dividingBy: OrbMath.period) / OrbMath.period
        let aa = (orbHash(floor(now / OrbMath.period) * 1.7 + 0.3) - 0.5) * 1.6   // 每一轮扫描方向略有倾斜
        let sdx = sin(aa), sdy = cos(aa)
        let wpos = -1.35 + 2.7 * OrbMath.wave(now)
        let scanActive = c.scan > 0.01 && scanP < OrbMath.active
        let gatherPulse = 0.5 - 0.5 * cos(orbTau * t / 4.2)
        let twist = sin(orbTau * t / 6)
        let breathAlpha = cfg.reduced ? 0.8 + 0.2 * sin(orbTau * t / 2.4) : 1.0
        let n = dots.count
        let base = max(0.7, (4 * Double.pi * R * R / Double(n)).squareRoot() * (cfg.form == .grid ? 0.2 : 0.16))

        // 4. 外圈光晕（柔光）
        ctx.blendMode = .normal
        if lit {
            let ac = mono ? (dark ? OrbRGB.white : OrbRGB(0, 0, 0)) : cfg.palette.sample(0.3, dark: dark)
            let amp = G * (dark ? 0.32 : 0.16) * (1 + 0.25 * sin(orbTau * t / 2.8))
            ctx.blendMode = dark ? .plusLighter : .normal
            let grad = Gradient(stops: [
                .init(color: ac.color(amp * 0.08), location: 0),
                .init(color: ac.color(amp * 0.18), location: 0.45),
                .init(color: ac.color(amp * 0.8), location: 0.67),
                .init(color: ac.color(amp * 0.3), location: 0.83),
                .init(color: ac.color(0), location: 1),
            ])
            ctx.fill(Path(CGRect(origin: .zero, size: size)),
                     with: .radialGradient(grad, center: CGPoint(x: cx, y: cy), startRadius: 0, endRadius: rad * 1.5))
        }

        // 5. 逐点计算
        for i in 0..<n {
            let o = dots[i]
            var yi = yaw + c.swirl * 2.4 * o.y * twist
            if c.band > 0.001 || abs(bandYaw) > 0.001 {
                yi += ((Int(floor((o.y + 1) * 2.5)) & 1) == 1 ? 1.0 : -1.0) * bandYaw
            }
            let cy1 = cos(yi), sy1 = sin(yi)
            let x1 = o.x * cy1 + o.z * sy1, z1 = -o.x * sy1 + o.z * cy1, y1 = o.y
            let y2 = y1 * ct - z1 * stl, z2 = y1 * stl + z1 * ct
            let x3 = x1 * cr - y2 * sr, y3 = x1 * sr + y2 * cr, z3 = z2
            let rho = (x3 * x3 + y3 * y3).squareRoot()

            var g = 0.0
            if scanActive {   // 彗星式光带：前沿窄、尾巴长
                let dd = (x3 * sdx + y3 * sdy) - wpos
                let sg = dd > 0 ? 0.16 : 0.45
                g = c.scan * exp(-(dd * dd) / (sg * sg))
            }
            var k = 1 + g * 0.06 + fx * 0.012 * sin(t * 1.3 + Double(o.i) * 2.399)
            let zn = (z3 + 1) / 2
            var sz = 1 + g * 0.45
            var al = 0.22 + 0.78 * pow(zn, 1.4)
            if c.rip > 0.001 {
                let rp = c.rip * sin(orbTau * (t / 1.8 - rho * 1.1))
                k += 0.05 * rp; sz *= 1 + 0.55 * rp; al *= 1 + 0.45 * rp
            }
            if c.sc > 0.001 {
                let sh = c.sc * o.h * gatherPulse
                k *= 1 - 0.1 * c.sc + 0.3 * sh; al *= 1 - 0.5 * sh; sz *= 1 - 0.3 * sh
            }
            if c.nf > 0.001 {
                let nv = c.nf * 0.14 * (sin(o.x * 3 + t * 1.1) * sin(o.y * 2.7 - t * 0.9) + 0.5 * sin(o.z * 3.3 + t * 1.4))
                k += nv; sz *= 1 + nv * 3
            }
            al = min(1, al * (1 + g * 0.3)) * (1 - 0.1 * fx + 0.1 * fx * sin(t * 2.1 + Double(o.i) * 1.7))

            var pw = 0.0
            for pf in pframes { pw += pf.env * exp(-pow((rho - pf.wr) / 0.2, 2)) }
            pw = min(pw, 1)
            if pw > 0 { k += 0.08 * pw; sz *= 1 + 0.7 * pw; al = min(1, al + 0.5 * pw) }

            var s = 0.0, rim = 0.0
            if lit {   // 随机闪烁 + 边缘光
                s = pow(max(0, sin(orbTau * t * o.rate + o.ph)), 22) * c.spark
                rim = pow(min(rho, 1), 4)
                al = min(1, al + G * (0.28 * rim + 0.9 * s))
                sz *= 1 + G * (1.1 * s + 0.2 * rim)
            }
            proj[i] = Proj(sx: cx + x3 * rad * k, sy: cy + y3 * rad * k, z3: z3,
                           r: base * (0.55 + 0.7 * zn) * sz * (1 + 0.12 * fx * z3) * o.sf,
                           a: max(0, al), yn: y3, rho: rho, g: g, s: s, rim: rim, pw: pw)
        }
        order.sort { proj[$0].z3 < proj[$1].z3 }

        // 6. 绘制（由远到近）
        ctx.blendMode = (lit && dark) ? .plusLighter : .normal
        for idx in order {
            let d = proj[idx]
            var col: OrbRGB
            if mono {
                col = dark ? OrbRGB(242, 242, 242) : OrbRGB(28, 28, 28)
            } else {
                let f = ((1 - c.hueRho) * (d.yn * 0.5 + 0.5) + c.hueRho * min(d.rho, 1)) * 0.85 + hp + d.g * 0.38 + d.pw * 0.25
                col = cfg.palette.sample(f, dark: dark)
            }
            let hot = max(d.g * 0.3, d.s, d.pw * 0.6)
            if lit && dark {
                col = col.mixed(with: .white, min(1, 0.8 * d.s + 0.08 * d.g + 0.28 * G * d.rim + 0.3 * d.pw))
            }
            let r = max(0.2, d.r), a = d.a * breathAlpha
            if lit {
                let r2 = r * 2.6
                ctx.fill(Path(ellipseIn: CGRect(x: d.sx - r2, y: d.sy - r2, width: 2 * r2, height: 2 * r2)),
                         with: .color(col.color(a * (dark ? 0.14 : 0.09) * G)))
                if hot > 0.12 {
                    let hr = r * (5 + 5 * hot), ha = (dark ? 0.6 : 0.35) * hot * G
                    let hg = Gradient(stops: [
                        .init(color: col.color(ha), location: 0),
                        .init(color: col.color(ha * 0.35), location: 0.35),
                        .init(color: col.color(0), location: 1),
                    ])
                    ctx.fill(Path(ellipseIn: CGRect(x: d.sx - hr, y: d.sy - hr, width: 2 * hr, height: 2 * hr)),
                             with: .radialGradient(hg, center: CGPoint(x: d.sx, y: d.sy), startRadius: 0, endRadius: hr))
                }
            }
            ctx.fill(Path(ellipseIn: CGRect(x: d.sx - r, y: d.sy - r, width: 2 * r, height: 2 * r)),
                     with: .color(col.color(a)))
            if lit && dark && hot > 0.3 {
                let rc = r * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: d.sx - rc, y: d.sy - rc, width: 2 * rc, height: 2 * rc)),
                         with: .color(OrbRGB.white.color(min(1, hot) * 0.9)))
            }
        }
        ctx.blendMode = .normal
    }
}
