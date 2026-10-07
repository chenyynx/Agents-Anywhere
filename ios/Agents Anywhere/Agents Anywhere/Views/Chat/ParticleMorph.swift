import SwiftUI

struct ParticleMorph: View {
    struct Palette {
        var colors: [SIMD3<Double>]   // 3 个同色相色阶，循环流动
        var hi: SIMD3<Double>         // 接近白的高光色
        static let cobalt = Palette(
            colors: [[38,68,180],[61,100,225],[130,166,255]],
            hi: [226,236,255])
        static let indigo = Palette(
            colors: [[72,64,200],[108,104,240],[168,164,255]],
            hi: [236,234,255])
    }

    var size: CGFloat
    var count: Int
    var dotScale: Double
    var palette: Palette

    @State private var shapes: [[SIMD3<Double>]]
    @State private var h: [SIMD2<Double>]
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(size: CGFloat = 24, count: Int = 100, dotScale: Double = 0.03,
         palette: Palette = .cobalt) {
        self.size = size; self.count = count
        self.dotScale = dotScale; self.palette = palette
        _shapes = State(initialValue: Self.buildShapes(count))
        _h = State(initialValue: (0..<count).map {
            SIMD2(Self.hs($0, 8), Self.hs($0, 9))
        })
    }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { tl in
            let t = reduceMotion ? 0.6 : tl.date.timeIntervalSince(start)
            Canvas { ctx, _ in draw(&ctx, t) }
                .frame(width: size, height: size)
        }
    }

    // MARK: - 状态

    private struct Frame {
        var ia: Int, ib: Int
        var e: Double, sw: Double
        var cy: Double, sy: Double, cx: Double, sx: Double
        var t: Double
    }
    private struct P { var x, y, z, ys, u: Double }
    private struct Dot {
        var x, y, qx, qy, z, r, a, d, pu: Double
        var c: SIMD3<Double>
        var star: Bool
    }

    private func frame(_ t: Double) -> Frame {
        let k = Int(floor(t / 3.2))
        let lc = t - Double(k) * 3.2
        let e = lc > 1.8 ? ease((lc - 1.8) / 1.4) : 0
        let ry = t * 0.5
        let rx = 0.35 + 0.15 * sin(t * 0.4)
        return Frame(ia: k % 4, ib: (k + 1) % 4, e: e,
                     sw: sin(Double.pi * e),
                     cy: cos(ry), sy: sin(ry), cx: cos(rx), sx: sin(rx), t: t)
    }

    private func pos(_ i: Int, _ s: Frame, _ m: Double, _ R: Double) -> P {
        let A = shapes[s.ia][i], B = shapes[s.ib][i]
        let p = A + (B - A) * s.e
        let ang = s.sw * (1.2 + h[i].x * 1.6)
        let ac = cos(ang), asn = sin(ang)
        var bx = p.x * ac + p.z * asn
        var bz = -p.x * asn + p.z * ac
        var py = p.y
        let sc = 1 + 0.35 * s.sw * (h[i].y - 0.3)
        bx *= sc; py *= sc; bz *= sc
        let br = 0.02 * sin(s.t * 2 + Double(i))
        bx += br; py += br
        let x1 = bx * s.cy + bz * s.sy
        let z1 = -bx * s.sy + bz * s.cy
        let y2 = py * s.cx - z1 * s.sx
        let z2 = py * s.sx + z1 * s.cx
        let f = 1 + z2 * 0.22
        return P(x: m + x1 * R * f, y: m + y2 * R * f, z: z2,
                 ys: (y2 + 1) / 2,
                 u: atan2(z1, x1) / (2 * Double.pi))
    }

    // MARK: - 绘制

    private func draw(_ ctx: inout GraphicsContext, _ t: Double) {
        let m = Double(size) / 2
        let R = Double(size) * 0.44
        let rs = Double(size) * dotScale
        let detailed = size >= 60          // 小尺寸跳过光痕和渐变光晕
        let s = frame(t)
        let s0 = frame(max(0, t - 0.09))
        let ph = 1.2 - (t * 0.55).truncatingRemainder(dividingBy: 1.4)

        var dots: [Dot] = []
        dots.reserveCapacity(count)

        for i in 0..<count {
            let p = pos(i, s, m, R)
            let q = pos(i, s0, m, R)
            let d = min(1, max(0, (p.z + 1) / 2))
            let star = h[i].x > 0.93
            let pu = exp(-pow((p.ys - ph) * 5, 2))
            let sf = star ? 1.9 : (0.55 + 0.7 * h[i].y)
            let r = rs * (0.45 + 0.9 * d) * sf * (1 + 0.6 * pu)
            var a = 0.18 + 0.82 * pow(d, 1.3)
            if star {
                a *= 1 - 0.25 * (0.5 + 0.5 * sin(t * 2.6 + h[i].x * 40))
            }
            a = min(1, a + 0.4 * pu)
            let tint = min(1, (star ? 0.7 : 0) + d * 0.15 + pu * 0.85)
            let c = mix(ramp(p.u + t * 0.12), palette.hi, tint)
            dots.append(Dot(x: p.x, y: p.y, qx: q.x, qy: q.y, z: p.z,
                            r: r, a: a, d: d, pu: pu, c: c, star: star))
        }

        dots.sort { $0.z < $1.z }

        for o in dots {
            // 1. 变形时的光痕
            if detailed && s.sw > 0.05 {
                var line = Path()
                line.move(to: CGPoint(x: o.qx, y: o.qy))
                line.addLine(to: CGPoint(x: o.x, y: o.y))
                ctx.stroke(line,
                           with: .color(rgb(o.c, o.a * 0.5 * s.sw)),
                           style: StrokeStyle(lineWidth: o.r * 1.1, lineCap: .round))
            }
            // 2. 远处粒子的虚化光晕（景深）
            if detailed && o.d < 0.4 {
                ctx.fill(circle(o.x, o.y, o.r * 2),
                         with: .color(rgb(o.c, o.a * 0.35)))
            }
            // 3. 星点 / 亮光扫过时的柔光
            if o.star || o.pu > 0.35 {
                if detailed {
                    let g = o.r * 4
                    ctx.fill(circle(o.x, o.y, g),
                             with: .radialGradient(
                                Gradient(colors: [rgb(o.c, o.a * 0.5), rgb(o.c, 0)]),
                                center: CGPoint(x: o.x, y: o.y),
                                startRadius: 0, endRadius: g))
                } else {
                    ctx.fill(circle(o.x, o.y, o.r * 2.4),
                             with: .color(rgb(o.c, o.a * 0.2)))
                }
            }
            // 4. 粒子本体
            ctx.fill(circle(o.x, o.y, o.r), with: .color(rgb(o.c, o.a)))
        }
    }

    // MARK: - 工具

    private func circle(_ x: Double, _ y: Double, _ r: Double) -> Path {
        Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    private func rgb(_ c: SIMD3<Double>, _ a: Double) -> Color {
        Color(.sRGB, red: c.x / 255, green: c.y / 255, blue: c.z / 255,
              opacity: max(0, a))
    }
    private func mix(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ t: Double) -> SIMD3<Double> {
        a + (b - a) * t
    }
    private func ramp(_ u: Double) -> SIMD3<Double> {
        let w = u - floor(u)
        let k = w * 3
        let i = Int(k)
        return mix(palette.colors[i % 3], palette.colors[(i + 1) % 3], k - Double(i))
    }
    private func ease(_ e: Double) -> Double {
        e < 0.5 ? 4 * e * e * e : 1 - pow(-2 * e + 2, 3) / 2
    }
    static func hs(_ i: Int, _ s: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + s * 78.233) * 43758.5453
        return v - floor(v)
    }

    // 四个形状：球 → 圆环 → 星系 → 三叶结
    static func buildShapes(_ n: Int) -> [[SIMD3<Double>]] {
        var S = Array(repeating: [SIMD3<Double>](), count: 4)
        let G = 2.399963
        for i in 0..<n {
            let fi = Double(i), fn = Double(n)
            // 0 球
            let y = 1 - 2 * (fi + 0.5) / fn
            let r = sqrt(1 - y * y), a = fi * G
            S[0].append([r * cos(a), y, r * sin(a)])
            // 1 圆环
            let u = fi * G, v = fi * 0.754877666 * 2 * Double.pi
            let rr = 0.72 + 0.28 * cos(v)
            S[1].append([rr * cos(u), 0.28 * sin(v), rr * sin(u)])
            // 2 星系
            let gr = sqrt(fi / fn) * 0.98
            let arm = Double(i % 3) * 2.0944
            let ga = gr * 5.2 + arm + (hs(i, 3) - 0.5) * 0.5
            S[2].append([gr * cos(ga),
                         (hs(i, 4) - 0.5) * 0.12 * (1 - gr * 0.5),
                         gr * sin(ga)])
            // 3 三叶结
            let tt = fi / fn * 2 * Double.pi
            let kx = (sin(tt) + 2 * sin(2 * tt)) / 3.1
            let ky = (cos(tt) - 2 * cos(2 * tt)) / 3.1
            let kz = -sin(3 * tt) / 3.1
            S[3].append([kx + (hs(i, 5) - 0.5) * 0.2,
                         ky + (hs(i, 6) - 0.5) * 0.2,
                         kz + (hs(i, 7) - 0.5) * 0.2])
        }
        return S
    }
}
