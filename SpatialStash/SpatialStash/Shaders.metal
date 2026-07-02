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
    float depthStrength;  // max horizontal disparity in UV (fraction of width)
    float convergence;    // depth mapped to zero parallax (0 = far, 1 = near)
    float eyeSign;        // +1 = left eye, -1 = right eye
    float mirror;         // 1 = mirror horizontally (flip), 0 = normal
    float useDepth;       // 1 = sample real depth from depthTex, 0 = heuristic
    // Maps frame UV into the content region of the depth map. Vision letterboxes
    // the frame into the model's square input (.scaleFit), so the depth for
    // frame UV lives at uv * scale + offset; identity when aspects match.
    float2 depthUVScale;
    float2 depthUVOffset;
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
    texture2d<float> depthTex [[texture(1)]],
    constant VideoStereoUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = in.texCoord;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }

    // Real Core ML depth when available (normalized inverse depth: near≈1,
    // far≈0), otherwise the cheap heuristic. (The useDepth branch is currently
    // unreachable — a real depth map always takes the mesh-warp path — but is
    // kept consistent with videoStereoMeshVertex's letterbox remap.)
    float depth = u.useDepth > 0.5
        ? saturate(depthTex.sample(texSampler, uv * u.depthUVScale + u.depthUVOffset).r)
        : pseudo3DHeuristicDepth(tex, texSampler, uv);
    // Near objects (depth high) must get CROSSED disparity to read as "in front":
    // the left eye sees them shifted right, the right eye left. That means
    // sampling the source toward the OPPOSITE side of the shift — hence the
    // minus. (The previous `+` gave uncrossed disparity, pushing near objects
    // behind = inverted/weak depth that won't fuse.)
    float disparity = (depth - u.convergence) * u.depthStrength;
    float2 warpedUV = float2(uv.x - u.eyeSign * disparity, uv.y);

    float4 color = tex.sample(texSampler, warpedUV);

    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}

// MARK: - Pseudo-3D Mesh Warp (depth-displaced grid, occlusion-correct)
//
// When a real depth map is available, render the frame as a displaced grid
// instead of a per-pixel backward warp. Each vertex shifts horizontally by its
// disparity (parallax) and takes a clip-space Z from its depth; with depth
// testing, nearer geometry occludes farther geometry, so foreground/background
// boundaries stay clean instead of smearing into halos. Disocclusions become
// stretched triangles rather than edge smears. Reuses VideoStereoUniforms.

struct MeshVertexOut {
    float4 position [[position]];
    float2 texCoord;
};

vertex MeshVertexOut videoStereoMeshVertex(
    uint vid [[vertex_id]],
    const device float2 *gridPositions [[buffer(0)]],
    constant VideoStereoUniforms &u [[buffer(1)]],
    texture2d<float> depthTex [[texture(0)]]
) {
    constexpr sampler depthSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float2 grid = gridPositions[vid];           // [0,1] across the frame
    float2 uv = grid;
    if (u.mirror > 0.5) { uv.x = 1.0 - uv.x; }

    // uv already indexes the source pixel being displayed (post-mirror), and
    // depth was inferred on the unmirrored frame, so the letterbox remap applies
    // after the flip.
    float2 duv = uv * u.depthUVScale + u.depthUVOffset;
    float depth = saturate(depthTex.sample(depthSampler, duv, level(0)).r); // near≈1
    float disparity = (depth - u.convergence) * u.depthStrength;

    float ndcX = grid.x * 2.0 - 1.0 + u.eyeSign * disparity * 2.0;
    float ndcY = 1.0 - grid.y * 2.0;
    float ndcZ = clamp(1.0 - depth, 0.0, 1.0);   // near (depth 1) → 0 → wins depth test

    MeshVertexOut out;
    out.position = float4(ndcX, ndcY, ndcZ, 1.0);
    out.texCoord = uv;
    return out;
}

fragment float4 videoStereoMeshFragment(
    MeshVertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant VideoStereoUniforms &u [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 color = tex.sample(texSampler, in.texCoord);
    color.rgb += u.brightness;
    color.rgb = (color.rgb - 0.5) * u.contrast + 0.5;
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, u.saturation);
    color.rgb = clamp(color.rgb, 0.0, 1.0);
    color.a = 1.0;
    return color;
}

// MARK: - Depth Stabilization (spatial band-limit + motion-adaptive temporal EMA)
//
// Two depth artifacts feed the warp:
//  1. Spatial: the depth model (esp. Base) carries detail finer than the warp
//     grid can sample, so the grid *aliases* it into rippling standing waves
//     across the frame. A gaussian low-pass band-limits the depth to the grid's
//     sampling rate, removing the ripples (at the cost of slightly softer
//     silhouettes — the same trade the smoother low-res depth used to make).
//  2. Temporal: monocular depth jitters frame-to-frame, wobbling subjects. A
//     motion-adaptive EMA smooths hard where depth is stable (kills flicker) but
//     trusts the new map where it changed a lot (no ghosting on motion).
// Both run at the depth's native resolution.

struct DepthStabilizeParams {
    int   blurRadius;  // spatial low-pass radius in depth texels (0 = no blur)
    float blurSigma;   // gaussian sigma for the low-pass
    float baseAlpha;   // temporal blend toward new map where depth is stable
    float motionGain;  // how fast the blend trusts the new map as depth changes
    uint  hasPrev;     // 1 when emaPrev holds a valid previous frame
};

// The gaussian is separable, so it runs as two 1D passes (H into a scratch
// texture, then V) — 2·(2r+1) taps per texel instead of (2r+1)², a 6.5× tap
// reduction at the default radius 6. The EMA rides the tail of the V pass so
// the whole stabilization is still one command buffer.

static inline float depthGaussian1D(
    texture2d<float, access::sample> src, sampler s,
    float2 uv, float2 texelStep, constant DepthStabilizeParams &p
) {
    if (p.blurRadius <= 0) { return src.sample(s, uv).r; }
    const float inv2s2 = 1.0 / (2.0 * p.blurSigma * p.blurSigma);
    float sum = 0.0, wsum = 0.0;
    for (int d = -p.blurRadius; d <= p.blurRadius; ++d) {
        const float w = exp(-float(d * d) * inv2s2);
        sum += w * src.sample(s, uv + texelStep * float(d)).r;
        wsum += w;
    }
    return wsum > 1e-5 ? (sum / wsum) : src.sample(s, uv).r;
}

kernel void depthBlurH(
    texture2d<float, access::sample> rawDepth [[texture(0)]],
    texture2d<float, access::write>  blurred  [[texture(1)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = blurred.get_width();
    const uint H = blurred.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float raw = depthGaussian1D(rawDepth, s, uv, float2(1.0 / size.x, 0.0), p);
    blurred.write(float4(raw, 0.0, 0.0, 1.0), gid);
}

kernel void depthBlurVEMA(
    texture2d<float, access::sample> blurredH [[texture(0)]],
    texture2d<float, access::sample> emaPrev  [[texture(1)]],
    texture2d<float, access::write>  emaNext  [[texture(2)]],
    constant DepthStabilizeParams &p          [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    const uint W = emaNext.get_width();
    const uint H = emaNext.get_height();
    if (gid.x >= W || gid.y >= H) { return; }

    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    const float2 size = float2(W, H);
    const float2 uv = (float2(gid) + 0.5) / size;
    const float raw = depthGaussian1D(blurredH, s, uv, float2(0.0, 1.0 / size.y), p);

    float out = raw;
    if (p.hasPrev != 0) {
        const float prev = emaPrev.sample(s, uv).r;
        const float alpha = clamp(p.baseAlpha + p.motionGain * abs(raw - prev), p.baseAlpha, 1.0);
        out = mix(prev, raw, alpha);
    }
    emaNext.write(float4(out, 0.0, 0.0, 1.0), gid);
}
