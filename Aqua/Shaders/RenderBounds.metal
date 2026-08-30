//
//  RenderBounds.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct BoundsOut {
    float4 position [[position]];
};

vertex BoundsOut boundsVertex(
        uint vertexID [[vertex_id]],
        constant float3* vertices [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]) {
    BoundsOut out;

    
    out.position = float4(siToClipSpace(vertices[vertexID], uniforms.viewProjectionMatrix));
    
    return out;
}

fragment float4 boundsFragment(BoundsOut in [[stage_in]]) {
    return float4(0.65, 0.68, 0.18, 0.8);
}
