cbuffer Frame : register(b0) {
    float4 gamma_ratios;
    float2 target_size;
    float enhanced_contrast;
    uint rect_start;
    uint glyph_start;
    float3 padding;
    float4 round_clip;
    float clip_radius;
};

struct RectInstance {
    float4 rect;
    float4 color;
    float radius;
    float softness;
    float stroke;
    uint fill;
    float4 sheen;
};

struct GlyphInstance {
    float4 rect;
    float4 atlas;
    float4 color;
    uint flags;
    float fade_start;
    float fade_end;
    uint padding;
};

StructuredBuffer<RectInstance> rects : register(t0);
StructuredBuffer<GlyphInstance> glyphs : register(t1);
Texture2D<float> atlas : register(t2);
Texture2D<float4> color_atlas : register(t3);

struct Vertex {
    float4 position : SV_Position;
    float2 local : TEXCOORD0;
    nointerpolation float4 rect : TEXCOORD1;
    nointerpolation float4 color : COLOR0;
    nointerpolation float2 edge : TEXCOORD2;
    nointerpolation uint flags : TEXCOORD4;
    float2 texel : TEXCOORD3;
    nointerpolation float3 extra : TEXCOORD5;
    nointerpolation float4 sheen : TEXCOORD6;
};

float2 corner(uint id) {
    return float2((id == 1 || id == 2 || id == 4) ? 1 : 0, (id >= 2 && id <= 4) ? 1 : 0);
}

float4 clip_position(float2 p) {
    return float4(p / target_size * float2(2, -2) + float2(-1, 1), 0, 1);
}

Vertex rect_vs(uint vertex : SV_VertexID, uint instance : SV_InstanceID) {
    RectInstance r = rects[rect_start + instance];
    float pad = r.softness + 0.5;
    float2 p = r.rect.xy - pad + corner(vertex) * (r.rect.zw + 2 * pad);
    Vertex o = (Vertex)0;
    o.position = clip_position(p);
    o.local = p - r.rect.xy;
    o.rect = r.rect;
    o.color = r.color;
    o.edge = float2(r.radius, r.softness);
    o.extra.x = r.stroke;
    o.flags = r.fill;
    o.sheen = r.sheen;
    return o;
}

float clip_coverage(float2 position) {
    if (clip_radius <= 0) return 1;
    float radius = min(clip_radius, min(round_clip.z, round_clip.w) * 0.5);
    float2 q = abs(position - round_clip.xy - round_clip.zw * 0.5) - round_clip.zw * 0.5 + radius;
    float d = length(max(q, 0)) + min(max(q.x, q.y), 0) - radius;
    return saturate(0.5 - d);
}

float3 hsv_rgb(float hue, float saturation, float value) {
    float3 k = saturate(abs(frac(hue + float3(1, 2.0 / 3, 1.0 / 3)) * 6 - 3) - 1);
    return value * lerp(1, k, saturation);
}

float segment_distance(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-6));
    return length(pa - ba * h);
}

// The arc runs clockwise on screen from angle s.z through s.w radians around s.xy.
float arc_distance(float2 p, float4 s, float radius) {
    float2 v = p - s.xy;
    float t = atan2(v.y, v.x) - s.z;
    t -= 6.2831853 * floor(t / 6.2831853);
    if (t <= s.w) return abs(length(v) - radius);
    float2 e0 = s.xy + radius * float2(cos(s.z), sin(s.z));
    float2 e1 = s.xy + radius * float2(cos(s.z + s.w), sin(s.z + s.w));
    return min(length(p - e0), length(p - e1));
}

float4 rect_ps(Vertex i) : SV_Target {
    if (i.flags == 4 || i.flags == 5) {
        float d = i.flags == 4 ? segment_distance(i.local, i.sheen.xy, i.sheen.zw)
                               : arc_distance(i.local, i.sheen, i.edge.x);
        float a = saturate(0.5 + i.extra.x * 0.5 - d) * i.color.a * clip_coverage(i.position.xy);
        return float4(i.color.rgb * a, a);
    }
    float radius = clamp(i.edge.x, 0, min(i.rect.z, i.rect.w) * 0.5);
    float2 q = abs(i.local - i.rect.zw * 0.5) - i.rect.zw * 0.5 + radius;
    float distance = length(max(q, 0)) + min(max(q.x, q.y), 0) - radius;
    float coverage = saturate(0.5 - distance / max(1, 2 * i.edge.y));
    if (i.extra.x > 0) coverage *= saturate(distance + i.extra.x + 0.5);
    float alpha = coverage * i.color.a * clip_coverage(i.position.xy);
    float3 rgb = i.color.rgb;
    if (i.flags == 1) {
        float2 d = (i.local - i.rect.zw * 0.5) / max(1, i.rect.zw * 0.5);
        rgb = hsv_rgb(frac(atan2(d.y, d.x) / 6.2831853 + 1), saturate(length(d)), i.color.r);
    } else if (i.flags == 2) {
        rgb *= saturate(i.local.x / max(1, i.rect.z));
    } else if (i.flags == 3) {
        // A rim light: a band just inside the rounded edge, reaching out from the pointer,
        // with a faint interior wash so the face is not perfectly flat.
        float2 delta = i.local - i.sheen.xy;
        float reach = saturate(1 - length(delta) / max(1, i.sheen.z));
        float glow = reach * reach * 0.05;
        // Peak the band half a pixel inside the edge, where coverage is full, so the rim
        // reads as a crisp line instead of fading with the antialiased outline.
        float half_width = max(0.5, i.sheen.w * 0.5);
        float band = saturate(1 - abs((distance + half_width) / half_width));
        band = band * band * (3 - 2 * band);
        alpha *= band * reach + glow;
    }
    return float4(rgb * alpha, alpha);
}

Vertex glyph_vs(uint vertex : SV_VertexID, uint instance : SV_InstanceID) {
    GlyphInstance g = glyphs[glyph_start + instance];
    float2 c = corner(vertex);
    Vertex o = (Vertex)0;
    o.position = clip_position(g.rect.xy + c * g.rect.zw);
    o.texel = g.atlas.xy + c * g.atlas.zw;
    o.color = g.color;
    o.flags = g.flags;
    o.extra.yz = float2(g.fade_start, g.fade_end);
    return o;
}

// DirectWrite grayscale correction, after microsoft/terminal src/renderer/atlas/dwrite.hlsl (MIT).
float4 glyph_ps(Vertex i) : SV_Target {
    float opacity = i.color.a * clip_coverage(i.position.xy);
    if (i.flags & 2) opacity *= saturate((i.extra.z - i.position.x) / max(1, i.extra.z - i.extra.y));
    if (i.flags & 1) {
        // Color glyphs are premultiplied RGBA; fade them with the instance alpha only.
        return color_atlas.Load(int3(floor(i.texel), 0)) * opacity;
    }
    float a = atlas.Load(int3(floor(i.texel), 0));
    float3 fg = i.color.rgb;
    float k = enhanced_contrast * saturate(1 - dot(fg, float3(0.30, 0.59, 0.11)) * (4.0 / 3.0));
    a = a * (k + 1) / (a * k + 1);
    float f = dot(fg, float3(0.25, 0.5, 0.25));
    float4 g = gamma_ratios;
    a = saturate(a + a * (1 - a) * ((g.x * f + g.y) * a + (g.z * f + g.w))) * opacity;
    return float4(fg * a, a);
}
