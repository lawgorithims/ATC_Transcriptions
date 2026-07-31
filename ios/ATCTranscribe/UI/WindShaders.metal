#include <metal_stdlib>
using namespace metal;

// Shaders for the animated winds-aloft overlay. Three tiny pipelines:
//
//   1. windSegment*   — draws this frame's particle steps as thin quads, coloured per vertex.
//   2. windFade*      — copies the previous trail texture forward, dimmed and re-registered to the map,
//                       which is what produces the fading slipstream and keeps it glued to the terrain
//                       while the pilot pans.
//   3. windComposite* — lays the accumulated trail texture over the drawable.
//
// Everything is PREMULTIPLIED alpha: the fade pass multiplies RGBA uniformly, which only stays colour-
// correct in premultiplied space, and the blend states are set to match.

struct WindSegVertex {
    float2 position;    // view points, origin top-left
    float4 color;       // straight alpha; premultiplied in the fragment stage
};

struct WindSegUniforms {
    float2 viewportSize;  // view points
    float  alpha;         // layer-wide fade (span gate)
};

struct SegOut {
    float4 position [[position]];
    float4 color;
};

vertex SegOut windSegmentVertex(uint vid [[vertex_id]],
                               const device WindSegVertex* verts [[buffer(0)]],
                               constant WindSegUniforms& u [[buffer(1)]]) {
    WindSegVertex v = verts[vid];
    float2 ndc = float2(v.position.x / max(u.viewportSize.x, 1.0) * 2.0 - 1.0,
                        1.0 - v.position.y / max(u.viewportSize.y, 1.0) * 2.0);
    SegOut o;
    o.position = float4(ndc, 0.0, 1.0);
    o.color = float4(v.color.rgb, v.color.a * u.alpha);
    return o;
}

fragment float4 windSegmentFragment(SegOut in [[stage_in]]) {
    return float4(in.color.rgb * in.color.a, in.color.a);
}

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

vertex QuadOut windQuadVertex(uint vid [[vertex_id]]) {
    const float2 p[4] = { float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0), float2(1.0, 1.0) };
    const float2 t[4] = { float2(0.0, 1.0), float2(1.0, 1.0), float2(0.0, 0.0), float2(1.0, 0.0) };
    QuadOut o;
    o.position = float4(p[vid], 0.0, 1.0);
    o.uv = t[vid];
    return o;
}

struct WindFadeUniforms {
    float3x3 uvTransform;   // destination uv -> source uv (the inverse of the frame's map motion)
    float    fade;          // per-frame trail decay
};

fragment float4 windFadeFragment(QuadOut in [[stage_in]],
                                 texture2d<float> src [[texture(0)]],
                                 constant WindFadeUniforms& u [[buffer(0)]]) {
    float3 t = u.uvTransform * float3(in.uv, 1.0);
    float2 uv = t.xy;
    // Trail that panned in from off screen has no history; sampling clamped edge pixels there would smear
    // a bright streak along the border, so it reads as empty instead.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0.0);
    }
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, uv) * u.fade;
}

// The layer-wide span fade has to be applied HERE, to the accumulated trail — this pass draws almost all
// of the visible field. Without the uniform the composite ran at full strength no matter what
// `spanAlpha` said, so the layer never actually faded as the pilot zoomed out: it stayed solid right up
// to the cutoff and then vanished in one step, through exactly the regime where a single affine is known
// to stop describing the globe. (Premultiplied alpha, so the whole sample scales uniformly.)
fragment float4 windCompositeFragment(QuadOut in [[stage_in]],
                                      texture2d<float> src [[texture(0)]],
                                      constant WindSegUniforms& u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return src.sample(s, in.uv) * u.alpha;
}
