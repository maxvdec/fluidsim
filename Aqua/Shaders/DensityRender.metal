//
//  DensityRender.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

float calculateDensityForPass(device const Particle *particles, float2 samplePos, constant Uniforms& uniforms) {
    const float mass = 1.0;
    float density = 0.0;
    
    for (uint i = 0; i < uniforms.particleCount; i++) {
        Particle p = particles[i];
        
        float dst = length(p.position - samplePos);
        float influence = smoothingKernel(uniforms.smoothingRadius, dst);
        density += mass * influence;
    }
    
    return density;
}

kernel void renderDensity(device const Particle* particles [[buffer(0)]], constant Uniforms& uniforms [[buffer(1)]],
                          texture2d<float, access::write> output [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint width = output.get_width();
    uint height = output.get_height();
    
    if (gid.x >= width || gid.y >= height) {
        return;
    }
    
    float2 uv = float2(gid) / float2(width - 1, height - 1);

    float2 samplePos = (uv - 0.5) * uniforms.bounds;

    float density = calculateDensityForPass(
        particles,
        samplePos,
        uniforms
    );

    float t = clamp(
        density / 100,
        0.0,
        1.0
    );

    float3 color = float3(
        0.0,
        0.0,
        t
    );

    output.write(float4(color, 1.0), gid);
}

