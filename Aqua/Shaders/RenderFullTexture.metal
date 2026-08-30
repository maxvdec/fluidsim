//
//  RenderDensityMap.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct FullscreenVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex FullscreenVertexOut fullscreenVertex(
    uint vertexID [[vertex_id]]
) {
    constexpr float2 positions[6] = {
           float2(-1.0, -1.0),
           float2( 1.0, -1.0),
           float2(-1.0,  1.0),

           float2( 1.0, -1.0),
           float2( 1.0,  1.0),
           float2(-1.0,  1.0)
       };

       constexpr float2 uvs[6] = {
           float2(0.0, 1.0),
           float2(1.0, 1.0),
           float2(0.0, 0.0),

           float2(1.0, 1.0),
           float2(1.0, 0.0),
           float2(0.0, 0.0)
       };

       FullscreenVertexOut out;

       out.position =
           float4(
               positions[vertexID],
               0.0,
               1.0
           );

       out.uv =
           uvs[vertexID];

       return out;
}

fragment float4 fullscreenFragment(
    FullscreenVertexOut in [[stage_in]],
    texture2d<float> renderTexture [[texture(0)]]
) {
    constexpr sampler renderSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    return renderTexture.sample(
            renderSampler,
            in.uv
        );
}
