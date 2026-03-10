import Metal
import simd

// MARK: - Shared structs between Swift and Metal

/// Vertex data for terminal rendering.
struct TerminalVertex {
    var position: SIMD2<Float>
    var texCoord: SIMD2<Float>
    var color: SIMD4<Float>
}

/// Uniform data passed to shaders.
struct TerminalUniforms {
    var projectionMatrix: simd_float4x4
}

/// Creates an orthographic projection matrix.
func orthographicProjection(width: Float, height: Float) -> simd_float4x4 {
    // Maps (0,0)-(width,height) to (-1,-1)-(1,1), with Y flipped for top-left origin
    let sx: Float = 2.0 / width
    let sy: Float = -2.0 / height
    return simd_float4x4(columns: (
        SIMD4<Float>(sx, 0, 0, 0),
        SIMD4<Float>(0, sy, 0, 0),
        SIMD4<Float>(0, 0, 1, 0),
        SIMD4<Float>(-1, 1, 0, 1)
    ))
}

// MARK: - Metal shader source (compiled at runtime)

let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

struct Vertex {
    float2 position [[attribute(0)]];
    float2 texCoord [[attribute(1)]];
    float4 color    [[attribute(2)]];
};

struct Fragment {
    float4 position [[position]];
    float2 texCoord;
    float4 color;
};

struct Uniforms {
    float4x4 projection;
};

// Background rendering (solid color rectangles)
vertex Fragment bg_vert(
    Vertex in [[stage_in]],
    constant Uniforms &u [[buffer(1)]]
) {
    Fragment out;
    out.position = u.projection * float4(in.position, 0, 1);
    out.texCoord = in.texCoord;
    out.color = in.color;
    return out;
}

fragment float4 bg_frag(Fragment in [[stage_in]]) {
    return in.color;
}

// Glyph rendering (textured quads with alpha from atlas)
vertex Fragment glyph_vert(
    Vertex in [[stage_in]],
    constant Uniforms &u [[buffer(1)]]
) {
    Fragment out;
    out.position = u.projection * float4(in.position, 0, 1);
    out.texCoord = in.texCoord;
    out.color = in.color;
    return out;
}

fragment float4 glyph_frag(
    Fragment in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler s(filter::nearest);
    float alpha = atlas.sample(s, in.texCoord).r;
    return float4(in.color.rgb, in.color.a * alpha);
}

// Cursor rendering (solid color block)
vertex Fragment cursor_vert(
    Vertex in [[stage_in]],
    constant Uniforms &u [[buffer(1)]]
) {
    Fragment out;
    out.position = u.projection * float4(in.position, 0, 1);
    out.texCoord = in.texCoord;
    out.color = in.color;
    return out;
}

fragment float4 cursor_frag(Fragment in [[stage_in]]) {
    return in.color;
}
"""
