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

float2 calculateDensitiesAtPosition(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float2 samplePos,
    constant Uniforms& uniforms
) {
    float density = 0.0;
    float nearDensity = 0.0;

    int2 sampleCell = getCell2D(samplePos, uniforms.smoothingRadius);

    for (uint offsetIndex = 0; offsetIndex < 9; offsetIndex++) {
        int2 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell2D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];

        if (entryIndex == 0xffffffffu) {
            continue;
        }

        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            uint particleIndex = lookupEntries[entryIndex].particleIndex;
            Particle p = particles[particleIndex];

            if (all(getCell2D(p.predictedPosition, uniforms.smoothingRadius) == cell)) {
                float dst = length(p.predictedPosition - samplePos);
                density += uniforms.particleMass * smoothingKernel(uniforms.smoothingRadius, dst);
                nearDensity += uniforms.particleMass * nearDensityKernel(uniforms.smoothingRadius, dst);
            }

            entryIndex++;
        }
    }

    return float2(density, nearDensity);
}

float2 calculatePressureForce(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float2 samplePos,
    float sampleDensity,
    float sampleNearDensity,
    constant Uniforms& uniforms
) {
    float2 pressureForce = float2(0.0, 0.0);

    int2 sampleCell = getCell2D(samplePos, uniforms.smoothingRadius);

    for (uint offsetIndex = 0; offsetIndex < 9; offsetIndex++) {
        int2 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell2D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];

        if (entryIndex == 0xffffffffu) {
            continue;
        }

        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            uint particleIndex = lookupEntries[entryIndex].particleIndex;
            Particle p = particles[particleIndex];

            if (all(getCell2D(p.predictedPosition, uniforms.smoothingRadius) == cell)) {
                float2 offset = p.predictedPosition - samplePos;
                float dst = length(offset);

                if (dst > 0.0001 && dst < uniforms.smoothingRadius) {
                    float2 dir = offset / dst;
                    float slope = smoothingKernelDerivative(uniforms.smoothingRadius, dst);
                    float nearSlope = nearDensityKernelDerivative(uniforms.smoothingRadius, dst);
                    float neighborDensity = max(p.density, 0.0001);
                    float sharedPressure = calculateSharedPressure(sampleDensity, neighborDensity, uniforms.targetDensity, uniforms.pressureMultiplier);
                    float sharedNearPressure = calculateSharedNearPressure(sampleNearDensity, p.nearDensity, uniforms.nearPressureMultiplier);
                    pressureForce += (
                        sharedPressure * slope
                        + sharedNearPressure * nearSlope
                    ) * dir * uniforms.particleMass / neighborDensity;
                }
            }

            entryIndex++;
        }
    }

    return pressureForce;
}

float2 calculateViscosityAcceleration(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float2 samplePos,
    float2 sampleVelocity,
    constant Uniforms& uniforms
) {
    float2 viscosityAcceleration = float2(0.0);
    int2 sampleCell = getCell2D(samplePos, uniforms.smoothingRadius);

    for (uint offsetIndex = 0; offsetIndex < 9; offsetIndex++) {
        int2 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell2D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];

        if (entryIndex == 0xffffffffu) {
            continue;
        }

        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            uint particleIndex = lookupEntries[entryIndex].particleIndex;
            Particle p = particles[particleIndex];

            if (all(getCell2D(p.predictedPosition, uniforms.smoothingRadius) == cell)) {
                float dst = length(p.predictedPosition - samplePos);

                if (dst > 0.0001 && dst < uniforms.smoothingRadius) {
                    float influence = smoothingKernel(uniforms.smoothingRadius, dst);
                    float neighborDensity = max(p.density, 0.0001);
                    viscosityAcceleration += (p.velocity - sampleVelocity) * influence * uniforms.particleMass / neighborDensity;
                }
            }

            entryIndex++;
        }
    }

    return viscosityAcceleration * uniforms.viscosityStrength;
}

kernel void predictPositions(
    device Particle *particles [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }

    Particle p = particles[id];
    float2 predictedVelocity = p.velocity + float2(0.0, -uniforms.gravity) * uniforms.dt;
    p.predictedPosition = p.position + predictedVelocity * uniforms.dt;
    particles[id] = p;
}

kernel void simulateParticles(
    device const Particle *particles [[buffer(0)]],
    device Particle *outputParticles [[buffer(1)]],
    device const SpatialLookupEntry *lookupEntries [[buffer(2)]],
    device const uint *cellStartIndices [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];

    float density = max(p.density, 0.0001);
    float2 pressureForce = calculatePressureForce(
        particles,
        lookupEntries,
        cellStartIndices,
        p.predictedPosition,
        density,
        p.nearDensity,
        uniforms
    );
    float2 viscosityAcceleration = calculateViscosityAcceleration(
        particles,
        lookupEntries,
        cellStartIndices,
        p.predictedPosition,
        p.velocity,
        uniforms
    );
    float2 acceleration = pressureForce / density
        + viscosityAcceleration
        + float2(0.0, -uniforms.gravity);
    p.velocity += acceleration * uniforms.dt;

    if (uniforms.dt > 0.0) {
        float speed = length(p.velocity);
        float maxSpeed = uniforms.smoothingRadius * 0.4 / uniforms.dt;

        if (speed > maxSpeed) {
            p.velocity *= maxSpeed / speed;
        }
    }
    
    // Create mouse interactions
    float2 offset = p.position - uniforms.mousePosition;
    float dist = length(offset);
    
    if (uniforms.mouseMode != 0 && dist < uniforms.mouseRadius) {
        float influence = 1.0 - (dist / uniforms.mouseRadius);
        influence *= influence;
        
        float2 dir = (dist > 0.0001) ? (offset / dist) : float2(0.0);
        
        // Push
        if (uniforms.mouseMode == 1) {
            float2 radialPush = dir * uniforms.mouseStrength;
            float2 sweepPush = uniforms.mouseVelocity * 2.0;
            
            p.velocity += (radialPush + sweepPush) * influence * uniforms.dt;
        }
        // Grab
        else if (uniforms.mouseMode == 2) {
            float2 toMouse = uniforms.mousePosition - p.position;
            float2 desiredVelocity = toMouse * 8.0 + uniforms.mouseVelocity;
            
            p.velocity += (desiredVelocity - p.velocity) * uniforms.mouseStrength * influence * uniforms.dt;
        }
    }
    
    p.position += p.velocity * uniforms.dt;

    float2 bounds = uniforms.bounds;

    if (!insideOriginRectangle(p.position, bounds, uniforms.particleSize)) {
        float2 limit = bounds * 0.5 - uniforms.particleSize;

        if (abs(p.position.x) > limit.x) {
            p.velocity.x *= -0.25;
            p.velocity.y *= 0.98;
        }

        if (abs(p.position.y) > limit.y) {
            p.velocity.y *= -0.25;
            p.velocity.x *= 0.98;
        }

        p.position = getBoundContactPosition(p.position, bounds, uniforms.particleSize);
    }

    outputParticles[id] = p;
}

kernel void calculateDensities(
    device const Particle* particles [[buffer(0)]],
    device Particle* outputParticles [[buffer(1)]],
    device const SpatialLookupEntry *lookupEntries [[buffer(2)]],
    device const uint *cellStartIndices [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle p = particles[id];

    float2 densities = calculateDensitiesAtPosition(
        particles,
        lookupEntries,
        cellStartIndices,
        p.predictedPosition,
        uniforms
    );
    p.density = densities.x;
    p.nearDensity = densities.y;

    outputParticles[id] = p;
}

kernel void updateSpatialLookup(
    device const Particle* particles [[buffer(0)]],
    device SpatialLookupEntry* lookupOut [[buffer(1)]],
    constant Uniforms &uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.spatialEntryCount) {
        return;
    }

    if (id >= uniforms.particleCount) {
        lookupOut[id].particleIndex = 0xffffffffu;
        lookupOut[id].cellKey = 0xffffffffu;
        return;
    }

    Particle p = particles[id];
    int2 cell = getCell2D(p.predictedPosition, uniforms.smoothingRadius);
    uint hash = hashCell2D(cell);
    uint key = keyFromHash(hash, uniforms.particleCount);
    lookupOut[id].particleIndex = id;
    lookupOut[id].cellKey = key;
}

kernel void sortSpatialLookup(
    device SpatialLookupEntry *lookupEntries [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    constant uint &comparisonDistance [[buffer(2)]],
    constant uint &sequenceLength [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.spatialEntryCount) {
        return;
    }

    uint partnerIndex = id ^ comparisonDistance;
    if (partnerIndex <= id || partnerIndex >= uniforms.spatialEntryCount) {
        return;
    }

    SpatialLookupEntry entry = lookupEntries[id];
    SpatialLookupEntry partner = lookupEntries[partnerIndex];
    bool ascending = (id & sequenceLength) == 0;
    bool entryGreater = entry.cellKey > partner.cellKey
        || (entry.cellKey == partner.cellKey && entry.particleIndex > partner.particleIndex);
    bool partnerGreater = partner.cellKey > entry.cellKey
        || (partner.cellKey == entry.cellKey && partner.particleIndex > entry.particleIndex);

    if ((ascending && entryGreater) || (!ascending && partnerGreater)) {
        lookupEntries[id] = partner;
        lookupEntries[partnerIndex] = entry;
    }
}

kernel void clearCellStartIndices(
    device uint *cellStartIndices [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id < uniforms.particleCount) {
        cellStartIndices[id] = 0xffffffffu;
    }
}

kernel void buildCellStartIndices(
    device const SpatialLookupEntry *lookupEntries [[buffer(0)]],
    device uint *cellStartIndices [[buffer(1)]],
    constant Uniforms &uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }

    SpatialLookupEntry entry = lookupEntries[id];
    if (id == 0 || entry.cellKey != lookupEntries[id - 1].cellKey) {
        cellStartIndices[entry.cellKey] = id;
    }
}
