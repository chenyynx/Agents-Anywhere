//
// slosh — reconstructed MSL from AIR bitcode (Claude iOS 1.261109.19)
// Source of truth: sloshVertexShader.ll / sloshFragmentShader.ll
// (llvm-dis-18 of the exact bitcode in ClaudeVoiceUI-default.metallib)
// Reconstruction 2026-11-23. Variable names ours; math/constants transcribed 1:1 from IR.
// NOTE: not compiled here (no Metal toolchain on Linux). Use the .ll as ground truth.
//

#include <metal_stdlib>
using namespace metal;

struct SloshUniforms {
    float2 resolution;               // offset 0   (w, h)
    float  time;                     // offset 8
    float  sinceUtteranceStart;      // offset 12
    float  envelope;                 // offset 16
    float  level;                    // offset 20
    float  bottomLeftCornerRadius;   // offset 24
    float  bottomRightCornerRadius;  // offset 28
    float  darkModeDim;              // offset 32
    float  reduceMotion;             // offset 36
    float  phase;                    // offset 40
    float  compactFill;              // offset 44
    float  thinking;                 // offset 48
    float3 tint;                     // offset 64 (align 16)
};                                   // size 80, align 16

static inline float smoothstep01(float x) {
    x = clamp(x, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}
static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.546875);
}

vertex float4 sloshVertexShader(uint vid [[vertex_id]]) {
    float2 p = float2(-1.0, -1.0);
    if (vid == 1) { p = float2(3.0, -1.0); }
    else if (vid == 2) { p = float2(-1.0, 3.0); }
    return float4(p, 0.0, 1.0);
}

fragment float4 sloshFragmentShader(
    float4 position [[position]],
    constant SloshUniforms &u [[buffer(0)]])
{
    float2 res   = u.resolution;
    float  maxR  = max(u.bottomLeftCornerRadius, u.bottomRightCornerRadius);

    // ---------- normalized, y-up, aspect-corrected coords ----------
    float2 p0  = float2(position.x, res.y - position.y);
    float  aspect = (res.x * 0.6) / res.y;          // 0.6 * w/h
    float2 halfExt = float2(aspect, 0.6);
    float2 p     = ((p0 * 2.0 - res) * half) / res; // 0.6*(2p-res)/res.y

    // ---------- rounded-box SDF (bottom corners) ----------
    float  sideR = (p.x < 0.0) ? u.bottomLeftCornerRadius : u.bottomRightCornerRadius;
    float2 q     = abs(p) - halfExt + sideR;
    float  sdf   = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - sideR;
    float  m     = clamp(res.y * 0.41666666 * sdf, 0.0, 1.0);
    float  insideMask = 1.0 - m * m * (3.0 - 2.0 * m);           // 1 inside

    // ---------- reduce-motion gates ----------
    bool  reduce  = u.reduceMotion > 0.5;
    float ampGate = reduce ? 0.0 : 1.5;                          // %57
    float wideGate= reduce ? 0.0 : 0.3;                          // %58
    float since   = reduce ? 0.0 : u.sinceUtteranceStart;        // %61
    float tPhase  = reduce ? 0.0 : u.phase;                      // used for %172/%173

    // ---------- since-utterance envelopes ----------
    float e0   = clamp(since * 2.5, 0.0, 1.0); e0 *= e0;         // %64
    float envA = 1.0 - (1.0 - smoothstep01((since - 0.37) * 2.0)); // %70
    float w1   = clamp((since - 0.35) * 12.5, 0.0, 1.0);         // %73
    float w2   = 3.0 - 2.0 * w1;                                  // %75

    float lev  = u.level;
    float lev01= clamp(lev * 0.5, 0.0, 1.5);                      // %81

    // ---------- liquid surface cut ----------
    float surf = max(1.5 * mix(0.55, 0.8, u.compactFill) + (maxR - 0.6), -0.12)
               + 0.02 + u.thinking * 0.35;                        // %91
    if (p.y > surf) return float4(0.0);

    // ---------- smoothed corner distance (wave reference height) ----------
    float  mixK = mix(0.45, 1.3, u.compactFill);                  // %94
    float2 hs   = float2(aspect - maxR, maxR - 0.6);              // %96
    float2 ap   = float2(abs(p.x), p.y);                          // %98
    float  q1   = clamp(abs(p.x), 0.0, aspect - maxR);            // %100
    float  d1   = length(ap - float2(q1, -0.6));                  // %104

    float2 d05  = ap - hs;                                        // %105
    float  ang  = clamp(atan2(d05.x, -d05.y), 0.0, 1.5707964);    // %110
    float2 dir  = float2(sin(ang), -cos(ang));                    // %115
    float  d2   = length(d05 + dir * (-maxR));                    // %122

    float  arc  = ang * maxR + (aspect - maxR);                   // %124
    float  arc2 = maxR * 1.5707964 + (aspect - maxR);             // %131
    float  yTop = clamp(p.y, maxR - 0.6, mixK + (maxR - 0.6));    // %126
    float  d3   = length(ap - float2(aspect, yTop));              // %130
    float  yMid = (arc2 - (maxR - 0.6)) + yTop;                   // %133

    float  wA = exp(-20.0 * d1);
    float  wB = exp(-20.0 * d2);
    float  wC = exp(-20.0 * d3);
    float  h  = (wA * q1 + wB * arc + wC * yMid) / max(wA + wB + wC, 1e-24); // %148

    // ---------- outside distance / surface fade ----------
    float outD    = max(-sdf, 0.0);                               // %150
    float fadeTop = maxR - 0.18;                                  // %151
    float fade    = 1.0 - smoothstep01((p.y - fadeTop)
                     / ((mixK + (maxR - 0.6)) - fadeTop));        // %160

    // ---------- wave phase / base height ----------
    float base  = (arc2 + 0.3) * (0.8 + lev01 * 0.22);            // %166
    float wob   = reduce ? 0.0 : sin(tPhase * 0.31) * 0.04;       // %173
    float waveY = (base + wob) * envA;                            // %175

    float k  = (-0.7853982 * maxR - (aspect - maxR) + h) / (maxR * 1.3 + 0.05); // %181
    float kf = exp(-k * k);                                       // %184

    // ---------- travelling waves ----------
    float wave = sin(h * 10.0 - u.phase)
               + 0.55 * sin(h * 17.0 + 1.7 + u.phase * 0.63)
               + 0.35 * sin(h *  5.0 - u.phase * 1.41)
               + 0.40 * sin(p.x * 9.0 + u.phase * 0.83);
    float amp  = (0.25 + 1.2 * lev01) * ampGate * exp(-16.0 * outD) * wave; // %213

    // ---------- body / rim ----------
    float dh   = h - waveY;                                       // %214
    float rim  = (0.03 * ampGate + 0.03) * kf * exp(-30.8642 * dh * dh) + 0.08; // %222
    float lip  = amp * wideGate + 1.0;                            // %224
    float body = (1.5 * lev01 + 0.7) * (0.65 * u.envelope + 0.35) * rim * lip;  // %231
    float expo = 1.5 / clamp(2.25 * lev01 + 2.5, 0.3, 3.0);       // %234/%235
    float bodyE= exp(-pow(outD / max(body, 0.06), expo));         // %240

    // ---------- secondary layers ----------
    float dchain = exp(-pow(dh / ((0.06 * kf + 0.12) * (1.0 + 1.2 * outD)), 2.0)); // %249
    float rim2   = 1.0 - smoothstep01((0.05 + 0.8 * outD + h - waveY)
                                      / (2.0 * (0.05 + 0.8 * outD)));              // %261
    float glowA  = exp(1.4 * dh);                                  // %263
    float lipA   = 0.3 * glowA + 0.6;                              // %265
    float lipB   = 1.0 + 0.22 * amp;                               // %267
    float c1     = clamp(5.5555553 * (h + 0.08), 0.0, 1.0);        // %270
    float c2     = 3.0 - 2.0 * c1;                                 // %272
    float e2     = exp(-pow(outD / max(2.8 * body, 0.05), 0.73 * expo)); // %279
    float g1     = clamp((h - (aspect - maxR))
                         / (max(waveY, (aspect - maxR) + 0.08) - (aspect - maxR)), 0.0, 1.0); // %285
    float g2     = 1.0 - smoothstep01(g1);                         // %290

    float layer  = (1.0 + 0.2 * amp) * (0.6 + 0.5 * lev01) * e2 * g2; // %297
    float mid    = lipB * (0.65 + 0.75 * lev01) * lipA * c1 * c1 * c2 * rim2; // %309
    float far    = dchain * (lev01 + 0.6);                         // %301
    float nearv  = (0.55 + 0.75 * lev01) * envA;                   // %312
    float mixv   = mix(nearv, mid + far, exp(-22.0 * outD));       // %323
    float v      = layer + mixv * bodyE;                           // %325

    float f26    = mix(0.3, 0.6, u.compactFill);                   // %26
    float shell  = 1.0 - smoothstep01((outD - 0.65 * f26) / (0.35 * f26)); // %322

    float mass = w1 * w1 * insideMask * u.envelope * w2 * fade * v * shell; // %332 (%326 = w1^2)

    // ---------- highlight blob (moves with phase / thinking) ----------
    float hx = (reduce ? 0.0 : 1.0) * 0.08 * sin(u.phase * 0.7);   // %336
    float hy = 0.08 * (reduce ? 0.0 : 1.0) * sin(u.phase * 0.5 + 1.9) - 0.08; // %342
    float2 hpos = float2(hx, hy);                                  // %343
    if (!reduce) hpos = mix(float2(0.0, -0.16), hpos, u.thinking); // %350
    float hfade = reduce ? 0.0 : e0 * (1.0 - u.thinking);          // %346
    hpos = mix(hpos, float2(0.0, -0.54), hfade);                   // %355

    float hA = smoothstep01((since - 0.016) * 9.615384);           // %362
    float hB = 1.0 - smoothstep01((since - 0.35) * 10.0);          // %369
    float hG = max(hA * hB, u.thinking);                           // %371
    float hS = mix(1.0, mix(0.9, 1.05, 0.5 + 0.5 * sin(u.phase * 1.2)),
                   (reduce ? 0.0 : 1.0) * u.thinking);             // %378
    float hd = dot(p - hpos, p - hpos);                            // %380
    float hGlow = exp(-hd / (0.0098 * hS * hS)) * hG;              // %386
    float hMix = mix(0.5 + 0.7 * hfade, 0.95, u.thinking);         // %389
    float hi   = hGlow * hMix;                                     // %390

    float hSince = exp(-100.0 * (since - 0.41) * (since - 0.41));  // %394
    float h2d   = exp(-22.22222 * dot(p + float2(0.0, 0.54), p + float2(0.0, 0.54))); // %398
    float hTerm = u.envelope * 1.3 * hSince * h2d;                 // %404

    float aBase = mass * (1.0 - u.thinking);                       // %399
    float aGlow = hi * max(u.envelope, u.thinking);                // %401
    float a     = clamp(0.3 * (insideMask * ((hTerm + aGlow) + 0.0) + aBase), 0.0, 1.0); // %408

    // ---------- color / tint ----------
    float3 col = mix(float3(1.0), u.tint, 0.25);                   // %411
    float  r234 = clamp(2.25 * lev01 + 2.5, 0.3, 3.0);             // %234
    float  rq   = max(r234, 0.5);                                  // %412
    float  edge0 = 0.1 / rq;                                       // %413
    float  edge1 = mix(0.7, 0.45, clamp(0.6 * (r234 - 1.0), 0.0, 1.0)); // %417
    float  eMix  = smoothstep01((a - edge0) / (edge1 - edge0));    // %425
    float3 eCol  = mix(col, u.tint, eMix);                         // %428

    float  insideAmt = clamp(a, 0.0, 1.0) * insideMask;            // %430
    float  rimAmt    = exp(-90.0 * abs(sdf)) * insideMask * clamp(0.36 * mass, 0.0, 1.0); // %437
    float  alpha     = clamp(rimAmt + insideAmt, 0.0, 1.0);        // %439

    float3 rgb = (insideAmt * eCol + rimAmt * u.tint) / max(alpha, 1e-5); // %450
    rgb = clamp(rgb, 0.0, 1.0) * alpha;                            // %454
    float4 outc = float4(rgb, alpha) * u.darkModeDim;              // %461

    // ---------- dither ----------
    if (alpha > 0.0) {
        float2 hh = position.xy + floor(u.time * 60.0);
        float  d  = hash21(hh);
        outc.rgb += float3((d - 0.5) * 0.0078431377);
    }
    return outc;
}
