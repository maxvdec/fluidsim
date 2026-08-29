//
//  RenderPoints.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float speed;
};

vertex VertexOut particleVertex(uint vertexID [[vertex_id]], device const Particle *particles [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
    Particle particle = particles[vertexID];
    
    VertexOut out;
    
    float2 pixelPosition = particle.position * uniforms.ppm;
    
    float2 ndc = float2(
        pixelPosition.x / (uniforms.viewportSize.x * 0.5),
        pixelPosition.y / (uniforms.viewportSize.y * 0.5));
    
    out.position = float4(ndc, 0.0, 1.0);
    
    out.pointSize = uniforms.particleSize * 2.0 * uniforms.ppm;
    
    out.speed = length(particle.velocity);
    
    return out;
}

fragment float4 particleFragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    float2 centered = pointCoord * 2.0 - 1.0;

    if (length(centered) > 1.0) {
        discard_fragment();
    }

    float maxSpeed = 5.0;
    float t = clamp(in.speed / maxSpeed, 0.0, 1.0);

    float3 blue = float3(0.0, 0.0, 1.0);
    float3 red  = float3(1.0, 0.0, 0.0);

    float3 color = mix(blue, red, t);

    return float4(color, 1.0);
}
