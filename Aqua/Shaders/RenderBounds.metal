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
        constant float2* vertices [[buffer(0)]],
        constant Uniforms& uniforms [[buffer(1)]]) {
    BoundsOut out;
    
    float2 si = vertices[vertexID];
    
    out.position = float4(siToNDC(si, uniforms.ppm, uniforms.viewportSize), 0.0, 1.0);
    
    return out;
}

fragment float4 boundsFragment(BoundsOut in [[stage_in]]) {
    return float4(1.0, 1.0, 1.0, 1.0);
}

