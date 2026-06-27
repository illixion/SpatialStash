/*
 Spatial Stash - Metal Shaders

 Simple vertex + fragment shaders for displaying a textured fullscreen
 quad with brightness, contrast, and saturation adjustments applied
 in the fragment shader.
 */

#include <metal_stdlib>
using namespace metal;

// Uniforms passed from the CPU for image adjustments
struct ImageUniforms {
    float brightness; // Additive offset (-1..1), 0 = no change
    float contrast;   // Multiplicative scale (0..2+), 1 = no change
    float saturation; // 0 = grayscale, 1 = original, 2 = oversaturated
    float sharpen;    // RCAS sharpening amount (0 = off, 1 = max). Spatial — runs before tonal ops.
};

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen quad: 6 vertices (2 triangles), no vertex buffer needed.
// Uses vertex_id to generate positions and UVs procedurally.
vertex VertexOut imageVertexShader(uint vertexID [[vertex_id]]) {
    // Triangle strip positions for a fullscreen quad
    const float2 positions[] = {
        float2(-1, -1), // bottom-left
        float2( 1, -1), // bottom-right
        float2(-1,  1), // top-left
        float2(-1,  1), // top-left
        float2( 1, -1), // bottom-right
        float2( 1,  1)  // top-right
    };

    const float2 texCoords[] = {
        float2(0, 1), // bottom-left (UV flipped vertically)
        float2(1, 1), // bottom-right
        float2(0, 0), // top-left
        float2(0, 0), // top-left
        float2(1, 1), // bottom-right
        float2(1, 0)  // top-right
    };

    VertexOut out;
    out.position = float4(positions[vertexID], 0, 1);
    out.texCoord = texCoords[vertexID];
    return out;
}

// MARK: - RCAS Pass (pass 1, optional)
//
// Standalone RCAS shader — sharpens and writes to an intermediate texture so
// the second pass can run AA on the *post-sharpened* result. Doing AA in the
// same pass as RCAS is impossible: each fragment's neighbors haven't been
// RCAS'd yet, so a single-pass FXAA after RCAS would smooth raw input rather
// than the sharpened image.
fragment float4 rcasFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant ImageUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(texSampler, in.texCoord);

    if (uniforms.sharpen <= 0.001) {
        return color;
    }

    float2 px = float2(1.0) / float2(tex.get_width(0), tex.get_height(0));
    float3 e = color.rgb;
    float3 b = tex.sample(texSampler, in.texCoord + float2(0.0, -px.y)).rgb;
    float3 d = tex.sample(texSampler, in.texCoord + float2(-px.x, 0.0)).rgb;
    float3 f = tex.sample(texSampler, in.texCoord + float2( px.x, 0.0)).rgb;
    float3 h = tex.sample(texSampler, in.texCoord + float2(0.0,  px.y)).rgb;

    float3 mn4 = min(min(b, d), min(f, h));
    float3 mx4 = max(max(b, d), max(f, h));

    // Per-channel limit — keeps sharpening from clipping near 0 or 1.
    // hitMin: positive headroom going down. hitMax: non-positive headroom going up.
    const float epsilon = 1.0 / 16384.0;
    float3 hitMin = mn4 / max(4.0 * mx4, float3(epsilon));
    float3 hitMax = (float3(1.0) - mx4) / min(4.0 * mn4 - 4.0, float3(-epsilon));

    float3 lobeRGB = max(-hitMin, hitMax);
    float lobePre = max(max(lobeRGB.r, lobeRGB.g), lobeRGB.b);
    float lobe = clamp(lobePre, -0.1875, 0.0) * uniforms.sharpen;

    float rcpL = 1.0 / (1.0 + 4.0 * lobe);
    color.rgb = saturate((e + lobe * (b + d + f + h)) * rcpL);
    return color;
}

// MARK: - Resolve + Tonal Pass (pass 2, always)
//
// When the RCAS pass ran into a higher-resolution intermediate, this pass
// resolves it to the drawable using a 5-tap rotated-grid supersample (the
// classic RGSS pattern used by hardware MSAA). Combined with bilinear
// filtering, each tap is itself a 2×2 area average, so a drawable pixel
// gathers an effective ~20-sample area weight from the intermediate. This is
// mathematically correct AA — no edge heuristics, no false positives that
// would soften legitimate detail (text, fine textures), and exactly the
// staircase patterns RCAS amplifies are averaged out by the resolve.
//
// When the RCAS pass didn't run (sharpen == 0), `applyResolve` is 0 and we
// just do a single bilinear sample — same cost as the original single-pass
// pipeline.
struct AAUniforms {
    float brightness;
    float contrast;
    float saturation;
    float applyResolve; // 1.0 = rotated-grid resolve, 0.0 = single bilinear sample
};

fragment float4 imageFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant AAUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 color;

    if (uniforms.applyResolve > 0.5) {
        // Rotated-grid 5-tap. Offsets are in intermediate-texel space; the
        // sub-pixel positions exploit hardware bilinear so each sample is
        // already a 2×2 average. Center + 4 rotated points keep the kernel
        // compact while breaking up axis-aligned stair-step patterns.
        float2 px = float2(1.0) / float2(tex.get_width(0), tex.get_height(0));
        float2 off = px * 0.5;
        float3 c0 = tex.sample(texSampler, in.texCoord).rgb;
        float3 c1 = tex.sample(texSampler, in.texCoord + off * float2( 0.4, -0.8)).rgb;
        float3 c2 = tex.sample(texSampler, in.texCoord + off * float2(-0.4,  0.8)).rgb;
        float3 c3 = tex.sample(texSampler, in.texCoord + off * float2(-0.8, -0.4)).rgb;
        float3 c4 = tex.sample(texSampler, in.texCoord + off * float2( 0.8,  0.4)).rgb;
        // Preserve alpha from the center sample (transparency from bg removal).
        float a = tex.sample(texSampler, in.texCoord).a;
        color = float4((c0 + c1 + c2 + c3 + c4) * 0.2, a);
    } else {
        color = tex.sample(texSampler, in.texCoord);
    }

    // Brightness (additive, matching SwiftUI .brightness())
    color.rgb += uniforms.brightness;

    // Contrast (scale around 0.5 midpoint, matching SwiftUI .contrast())
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;

    // Saturation (luminance-based desaturation, matching SwiftUI .saturation())
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, uniforms.saturation);

    color.rgb = clamp(color.rgb, 0.0, 1.0);
    return color;
}

// MARK: - Pseudo-3D Eye Warp
//
// Real-time "fake 3D": synthesize one eye of a stereo pair from a single mono
// frame, with no pre-compute. A cheap heuristic depth estimate (lower-of-frame
// = nearer, brighter = nearer, edges = slightly nearer) drives a horizontal
// parallax shift. Rendered once per eye into a full-frame eye texture; the eye
// is selected by `eyeSign` (+1 left, -1 right). Brightness/contrast/saturation
// are folded in here so the windowed RealityKit VideoPlayerComponent path keeps
// the same look as the flat MetalKit player.
//
// The depth heuristic is intentionally isolated in `pseudo3DHeuristicDepth` so a
// future Core ML depth provider can replace it (sample a supplied depth texture
// instead) without touching the warp/tonal math.

struct VideoStereoUniforms {
    float brightness;
    float contrast;
    float saturation;
    float depthStrength; // max horizontal disparity in UV (fraction of width)
    float convergence;   // depth mapped to zero parallax (0 = far, 1 = near)
    float eyeSign;       // +1 = left eye, -1 = right eye
    float mirror;        // 1 = mirror horizontally (flip), 0 = normal
};

static inline float pseudo3DHeuristicDepth(texture2d<float> tex, sampler s, float2 uv) {
    float2 px = float2(1.0) / float2(tex.get_width(0), tex.get_height(0));
    float3 c  = tex.sample(s, uv).rgb;
    float l   = dot(c, float3(0.2126, 0.7152, 0.0722));
    float lL  = dot(tex.sample(s, uv + float2(-px.x, 0.0)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lR  = dot(tex.sample(s, uv + float2( px.x, 0.0)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lU  = dot(tex.sample(s, uv + float2(0.0, -px.y)).rgb, float3(0.2126, 0.7152, 0.0722));
    float lD  = dot(tex.sample(s, uv + float2(0.0,  px.y)).rgb, float3(0.2126, 0.7152, 0.0722));
    float edge       = saturate((abs(lR - lL) + abs(lD - lU)) * 1.2);
    float lowerNear  = smoothstep(0.10, 0.95, uv.y); // uv.y=1 is bottom of frame
    float brightNear = smoothstep(0.25, 0.85, l);
    return saturate(lowerNear * 0.70 + brightNear * 0.25 + edge * 0.05);
}

fragment float4 videoPseudo3DEyeFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant VideoStereoUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }

    float depth = pseudo3DHeuristicDepth(tex, texSampler, uv);
    float disparity = (depth - u.convergence) * u.depthStrength;
    float2 warpedUV = float2(uv.x + u.eyeSign * disparity, uv.y);

    float4 color = tex.sample(texSampler, warpedUV);

    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}
