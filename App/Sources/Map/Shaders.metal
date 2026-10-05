#include <metal_stdlib>
using namespace metal;

// CellInstance, LabelInstance, MapUniforms and the kCellMode* constants.
#include "ShaderTypes.h"

struct CellOut {
    float4 position [[position]];
    float2 local;
    float2 size;
    float4 fill [[flat]];
    float4 border [[flat]];
    float2 params [[flat]];
};

static float2 corner(uint vid) { return float2(vid & 1, vid >> 1); }

vertex CellOut cellVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                          constant CellInstance *cells [[buffer(0)]],
                          constant MapUniforms &u [[buffer(1)]]) {
    CellInstance c = cells[iid];
    float2 k = corner(vid);
    float2 pt = c.rect.xy + k * c.rect.zw;
    CellOut o;
    o.position = float4(pt.x / u.viewSize.x * 2.0 - 1.0, 1.0 - pt.y / u.viewSize.y * 2.0, 0, 1);
    o.local = k * c.rect.zw;
    o.size = c.rect.zw;
    o.fill = c.fill;
    o.border = c.border;
    o.params = c.params.xy;
    return o;
}

fragment float4 cellFragment(CellOut in [[stage_in]], constant MapUniforms &u [[buffer(1)]]) {
    float px = 1.0 / u.scale;
    float2 p = in.local;
    float d = min(min(p.x, p.y), min(in.size.x - p.x, in.size.y - p.y));
    float bw = in.params.x;
    float mode = in.params.y;

    float3 rgb = in.fill.rgb;
    float a = in.fill.a;

    if (mode == kCellModeHatch) {
        // Diagonal hatch, 45 degrees, 6 pt period.
        float v = (p.x + p.y) / 6.0;
        float f = abs(fract(v) - 0.5) * 2.0;   // 0 at line centre ... 1 between lines
        float w = max(fwidth(v) * 2.0, 1e-4);
        float line = 1.0 - smoothstep(0.30 - w, 0.30 + w, f);
        rgb = mix(rgb, in.border.rgb, line * 0.45);
    } else if (mode == kCellModeAggregate) {
        // Dim, fine dot texture: reads as "many tiny things".
        float2 g = fract(p / 3.0) - 0.5;
        float dot = 1.0 - smoothstep(0.20, 0.32, length(g));
        rgb = mix(rgb, in.border.rgb, dot * 0.35);
    }

    if (mode == kCellModeBadge) {
        // Right triangle with the right angle at the top-right; soft diagonal edge.
        float e = (in.size.x - p.x) + p.y - in.size.x;   // < 0 inside
        a *= saturate(0.5 - e / px);
        a *= saturate((in.size.y - p.y) / px + 0.5);
    }

    float cov = (bw > 0.0) ? saturate((bw - d) / px + 0.5) : 0.0;
    float ba = cov * in.border.a;
    float4 f = float4(rgb * a, a);
    float4 b = float4(in.border.rgb * ba, ba);
    return b + f * (1.0 - ba);
}

struct LabelOut {
    float4 position [[position]];
    float2 uv;
    float2 pt;
    float4 color [[flat]];
    float4 clip [[flat]];
};

vertex LabelOut labelVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                            constant LabelInstance *labels [[buffer(0)]],
                            constant MapUniforms &u [[buffer(1)]]) {
    LabelInstance l = labels[iid];
    float2 k = corner(vid);
    float2 pt = l.dst.xy + k * l.dst.zw;
    LabelOut o;
    o.position = float4(pt.x / u.viewSize.x * 2.0 - 1.0, 1.0 - pt.y / u.viewSize.y * 2.0, 0, 1);
    o.uv = (l.uv.xy + k * l.uv.zw) / u.atlasSize;
    o.pt = pt;
    o.color = l.color;
    o.clip = l.clip;
    return o;
}

fragment float4 labelFragment(LabelOut in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]],
                              constant MapUniforms &u [[buffer(1)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float cov = atlas.sample(s, in.uv).r;
    float2 inside = step(in.clip.xy, in.pt) * step(in.pt, in.clip.zw);
    float a = cov * in.color.a * inside.x * inside.y;
    return float4(in.color.rgb * a, a);
}
