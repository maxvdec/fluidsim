//
//  Simulation.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

float calculateDensity(device Particle *particles, float2 samplePos, Uniforms uniforms) {
    const float mass = 1;
    float density = 0;
    
    for (unsigned int i = 0; i < uniforms.particleCount; i++) {
        Particle p = particles[i];
        
        float dst = length(p.position - samplePos);
        float influence = smoothingKernel(uniforms.smoothingRadius, dst);
        density += mass * influence;
    }
    
    return density;
}

kernel void simulateParticles(device Particle *particles [[buffer(0)]], constant Uniforms &uniforms [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    // Calculate the density from origin
    p.density = calculateDensity(particles, float2(0, 0), uniforms);
    
    float2 bounds = uniforms.bounds;
    
    if (!insideOriginRectangle(p.position, bounds, uniforms.particleSize)) {
        p.velocity *= -0.9;
        p.position = getBoundContactPosition(p.position, bounds, uniforms.particleSize);
    }
    
    particles[id] = p;
}


