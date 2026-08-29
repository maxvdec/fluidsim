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

float calculateDensity(device const Particle *particles, float2 samplePos, constant Uniforms& uniforms) {
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

float2 calculateDensityGradient(device const Particle *particles, float2 samplePos, constant Uniforms& uniforms) {
    const float mass = 1.0;
    float2 densityGradient = float2(0.0, 0.0);
    
    for (uint i = 0; i < uniforms.particleCount; i++) {
        Particle p = particles[i];
        
        float dst = length(p.position - samplePos);
        float2 dir = (p.position - samplePos) / dst;
        float slope = smoothingKernelDerivative(uniforms.smoothingRadius, dst);
        float density = p.density;
        densityGradient += -p.density * dir * slope * mass / density;
    }
    
    return densityGradient;
}

kernel void simulateParticles(device Particle *particles [[buffer(0)]], constant Uniforms &uniforms [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    float2 bounds = uniforms.bounds;
    
    if (!insideOriginRectangle(p.position, bounds, uniforms.particleSize)) {
        p.velocity *= -0.9;
        p.position = getBoundContactPosition(p.position, bounds, uniforms.particleSize);
    }
    
    particles[id] = p;
}

kernel void calculateDensities(device Particle* particles [[buffer(0)]], constant Uniforms &uniforms [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    // Calculate the density from origin
    p.density = calculateDensity(particles, float2(0, 0), uniforms);
    
    particles[id] = p;
}

