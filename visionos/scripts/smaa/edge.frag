#version 450
#extension GL_GOOGLE_include_directive : require
#include "common.glsl"
#define SMAA_INCLUDE_VS 0
#include "SMAA.hlsl"
layout(binding = 1) uniform sampler2D colorTex;
layout(location = 0) in vec2 v_uv;
layout(location = 1) in vec4 v_offset0;
layout(location = 2) in vec4 v_offset1;
layout(location = 3) in vec4 v_offset2;
layout(location = 0) out vec2 o_edges;
// The picture is read decoded from sRGB (linear); its edges are found in gamma space, as SMAA's
// thresholds are meant for: luma of the square root of each colour.
float LumaAt(vec2 uv) {
    return dot(sqrt(max(textureLod(colorTex, uv, 0.0).rgb, vec3(0.0))), vec3(0.2126, 0.7152, 0.0722));
}
void main() {
    vec2 threshold = vec2(SMAA_THRESHOLD, SMAA_THRESHOLD);
    float L = LumaAt(v_uv);
    float Lleft = LumaAt(v_offset0.xy);
    float Ltop = LumaAt(v_offset0.zw);
    vec4 delta;
    delta.xy = abs(L - vec2(Lleft, Ltop));
    vec2 edges = step(threshold, delta.xy);
    // The two eyes are side by side: no edge between the last column of the left eye and the
    // first of the right one.
    float column = floor(v_uv.x * SMAA_RT_METRICS.z);
    if (column == floor(SMAA_RT_METRICS.z * 0.5)) {
        edges.x = 0.0;
    }
    if (dot(edges, vec2(1.0, 1.0)) == 0.0) {
        discard;
    }
    float Lright = LumaAt(v_offset1.xy);
    float Lbottom = LumaAt(v_offset1.zw);
    delta.zw = abs(L - vec2(Lright, Lbottom));
    vec2 maxDelta = max(delta.xy, delta.zw);
    float Lleftleft = LumaAt(v_offset2.xy);
    float Ltoptop = LumaAt(v_offset2.zw);
    delta.zw = abs(vec2(Lleft, Ltop) - vec2(Lleftleft, Ltoptop));
    maxDelta = max(maxDelta.xy, delta.zw);
    float finalDelta = max(maxDelta.x, maxDelta.y);
    edges.xy *= step(finalDelta, SMAA_LOCAL_CONTRAST_ADAPTATION_FACTOR * delta.xy);
    o_edges = edges;
}
