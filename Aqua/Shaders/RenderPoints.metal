//
//  RenderPoints.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float speed;
    float2 siPosition;
};

vertex VertexOut particleVertex(uint vertexID [[vertex_id]], device const Particle *particles [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
    Particle particle = particles[vertexID];
    
    VertexOut out;
        
    out.position = float4(siToNDC(particle.position, uniforms.ppm, uniforms.viewportSize), 0.0, 1.0);
    out.pointSize = uniforms.particleSize * 2.0 * uniforms.ppm;
    
    out.speed = length(particle.velocity);
    out.siPosition = particle.position;
    
    return out;
}

fragment float4 particleFragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    float2 centered = pointCoord * 2.0 - 1.0;

    if (length(centered) > 1.0) {
        discard_fragment();
    }
    
    float mouseDistance = distance(
          in.siPosition,
          uniforms.mousePosition
      );

      if (
          uniforms.mouseMode != 0 &&
          mouseDistance < uniforms.mouseRadius
      ) {
          return float4(1.0, 0.0, 1.0, 1.0); // MAGENTA
      }

    float maxSpeed = 5.0;
    float t = clamp(in.speed / maxSpeed, 0.0, 1.0);

    float3 blue  = float3(0.0, 0.0, 1.0);
    float3 green = float3(0.0, 1.0, 0.0);
    float3 red   = float3(1.0, 0.0, 0.0);

    float3 color;

    if (t < 0.5) {
        float localT = t * 2.0;
        color = mix(blue, green, localT);
    } else {
        float localT = (t - 0.5) * 2.0;
        color = mix(green, red, localT);
    }

    return float4(color, 1.0);
}
