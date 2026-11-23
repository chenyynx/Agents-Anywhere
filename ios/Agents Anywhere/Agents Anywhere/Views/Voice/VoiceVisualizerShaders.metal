//
// voiceVisualizer — reconstructed MSL from AIR bitcode (Claude iOS 1.261109.19)
// Source of truth: voiceVisualizerVertexShader.ll / voiceVisualizerFragmentShader.ll
// (llvm-dis-18 of the exact bitcode embedded in ClaudeVoiceUI-default.metallib)
// Reconstruction 2026-11-23. Names are ours; math/constants are transcribed 1:1.
//

#include <metal_stdlib>
using namespace metal;

struct VoiceVisualizerUniforms {
    float4x4 modelView;              // offset 0
    float4   baseColor;              // offset 64
    float    time;                   // offset 80
    float    opacityFactor;          // offset 84
    float    ovalRatio;              // offset 88
    float    ditherSeed;             // offset 92
    float    gradientFalloffFactor;  // offset 96
    float    edgeSmoothstepOuter;    // offset 100
};                                   // size 112, align 16

struct VoiceVisualizerVaryings {
    float4 position [[position]];
    float2 normalizedPosition;
};

static inline float hash21(float2 p) {
    return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.546875);
}

vertex VoiceVisualizerVaryings voiceVisualizerVertexShader(
    float2 position [[attribute(0)]],
    constant VoiceVisualizerUniforms &u [[buffer(1)]])
{
    VoiceVisualizerVaryings out;
    // IR: modelView[0]*x + modelView[1]*y + modelView[3]
    out.position = u.modelView * float4(position, 0.0, 1.0);
    out.normalizedPosition = position * 0.5;
    return out;
}

fragment float4 voiceVisualizerFragmentShader(
    float4 position [[position]],
    float2 npos,                       // varying normalizedPosition
    constant VoiceVisualizerUniforms &u [[buffer(1)]])
{
    // ---- radial falloff / edge ----
    float2 q = float2(npos.x / u.ovalRatio, npos.y);
    float  r = sqrt(dot(q, q));
    float  g = exp(-(r * r) * u.gradientFalloffFactor);

    float  e = clamp((r - u.edgeSmoothstepOuter) / (0.48 - u.edgeSmoothstepOuter), 0.0, 1.0);
    float  shape = e * e * g * (3.0 - 2.0 * e);           // 0..~0.55

    float  s2 = 3.0 - 2.0 * shape;
    float  baseA = u.baseColor.a;
    float  intensity = shape * shape * (u.opacityFactor * 0.75 * baseA);
    float  edgeFactor = intensity * s2;                    // final alpha

    // ---- base color + quantized "grain"/string pattern ----
    float3 rgb = u.baseColor.rgb;

    float2 v  = position.xy * 0.01 + npos * 0.2;
    float  tq = floor(u.time * 24.0) / 24.0;               // quantize to 1/24 s

    float n1 = hash21(floor(v * 50.0)  + tq * float2(1.0, 0.7)) * 0.5;
    float n2 = hash21(floor(v * 150.0) + tq * float2(0.5, 1.3)) * 0.3;
    float n3 = hash21(floor(v * 300.0) + tq * float2(0.9, 0.2)) * 0.2;

    float n = n1 + n2 + n3 - 0.75;
    n = clamp(n * 4.1666665, 0.0, 1.0);
    float add = n * n * 0.45 * (3.0 - 2.0 * n);
    rgb += add;

    rgb += hash21(position.xy * 0.001) * 0.02;
    rgb *= edgeFactor;

    float4 outc = float4(rgb, edgeFactor);

    // ---- optional per-frame film grain ----
    if (edgeFactor > 0.0 && u.ditherSeed > 0.0) {
        float2 h = npos + u.ditherSeed * 17.0 + floor(u.time * 60.0);
        float  d = hash21(h);
        outc += float4((d - 0.5) * 0.0078431377);                   // ±1/255, added to rgba
    }
    return outc;
}
