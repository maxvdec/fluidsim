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

float2 calculatePressureForce(device const Particle *particles, float2 samplePos, float sampleDensity, constant Uniforms& uniforms) {
    const float mass = 1.0;
    float2 pressureForce = float2(0.0, 0.0);
    
    for (uint i = 0; i < uniforms.particleCount; i++) {
        Particle p = particles[i];
        
        float dst = length(p.position - samplePos);
        if (dst <= 0.0001 || dst >= uniforms.smoothingRadius) {
            continue;
        }
        float2 dir = (p.position - samplePos) / dst;
        float slope = smoothingKernelDerivative(uniforms.smoothingRadius, dst);
        float neighborDensity = max(p.density, 0.0001);
        float sharedPressure = calculateSharedPressure(sampleDensity, neighborDensity, uniforms.targetDensity, uniforms.pressureMultiplier);
        pressureForce += sharedPressure * dir * slope * mass / neighborDensity;
    }
    
    return pressureForce;
}

kernel void simulateParticles(device const Particle *particles [[buffer(0)]], device Particle *outputParticles [[buffer(1)]], constant Uniforms &uniforms [[buffer(2)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    // Apply pressure force
    float density = max(p.density, 0.0001);
    float2 pressureForce = calculatePressureForce(particles, p.position, density, uniforms);
    float2 acceleration = pressureForce / density;
    p.velocity += acceleration * uniforms.dt;
    
    // Get position
    p.position += p.velocity * uniforms.dt;
    
    // Compute collisions
    float2 bounds = uniforms.bounds;
    
    if (!insideOriginRectangle(p.position, bounds, uniforms.particleSize)) {
        float2 limit = bounds * 0.5 - uniforms.particleSize;

        if (abs(p.position.x) > limit.x) {
            p.velocity.x *= -0.5;
        }

        if (abs(p.position.y) > limit.y) {
            p.velocity.y *= -0.5;
        }

        p.position = getBoundContactPosition(p.position, bounds, uniforms.particleSize);
    }
    
    outputParticles[id] = p;
}

kernel void calculateDensities(device const Particle* particles [[buffer(0)]], device Particle* outputParticles [[buffer(1)]], constant Uniforms &uniforms [[buffer(2)]], uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    p.density = calculateDensity(particles, p.position, uniforms);
    
    outputParticles[id] = p;
}
