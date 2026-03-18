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

fragment float4 imageFragmentShader(
    VertexOut in [[stage_in]],
    texture2d<float> tex [[texture(0)]],
    constant ImageUniforms &uniforms [[buffer(0)]]
) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);
    float4 color = tex.sample(texSampler, in.texCoord);

    // Apply brightness (additive, matching SwiftUI .brightness())
    color.rgb += uniforms.brightness;

    // Apply contrast (scale around 0.5 midpoint, matching SwiftUI .contrast())
    color.rgb = (color.rgb - 0.5) * uniforms.contrast + 0.5;

    // Apply saturation (luminance-based desaturation, matching SwiftUI .saturation())
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    color.rgb = mix(float3(luminance), color.rgb, uniforms.saturation);

    // Clamp to valid range
    color.rgb = clamp(color.rgb, 0.0, 1.0);

    return color;
}
