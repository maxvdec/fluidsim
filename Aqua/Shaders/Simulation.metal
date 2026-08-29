//
//  Simulation.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
using namespace metal;

kernel void simulateParticles(device Particle *particles [[buffer(0)]], constant Uniforms &uniforms [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];
    
    p.velocity.y -= uniforms.gravity * uniforms.dt;
    p.position += p.velocity * uniforms.dt;
    
    particles[id] = p;
}


