#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

inline float densityKernelFast(float distance, float radius, float scale) {
    float value = radius - distance;
    return value > 0.0 ? value * value * scale : 0.0;
}

inline float densitySlopeFast(float distance, float radius, float scale) {
    float value = radius - distance;
    return value > 0.0 ? value * scale : 0.0;
}

inline float nearKernelFast(float distance, float radius, float scale) {
    float value = radius - distance;
    return value > 0.0 ? value * value * value * scale : 0.0;
}

inline float nearSlopeFast(float distance, float radius, float scale) {
    float value = radius - distance;
    return value > 0.0 ? value * value * scale : 0.0;
}

float2 calculateDensitiesAtPosition(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float3 samplePosition,
    constant Uniforms &uniforms
) {
    float2 density = float2(0.0);
    float radius = uniforms.smoothingRadius;
    float radiusSquared = radius * radius;
    float radius4 = radiusSquared * radiusSquared;
    float densityScale = 15.0 / (2.0 * PI * radius4 * radius);
    float nearScale = 15.0 / (PI * radius4 * radiusSquared);
    int3 sampleCell = getCell3D(samplePosition, radius);

    for (uint offsetIndex = 0; offsetIndex < 27; offsetIndex++) {
        int3 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell3D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];
        if (entryIndex == 0xffffffffu) {
            continue;
        }
        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            Particle particle = particles[lookupEntries[entryIndex].particleIndex];
            if (all(getCell3D(particle.predictedPosition, radius) == cell)) {
                float3 offset = particle.predictedPosition - samplePosition;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared < radiusSquared) {
                    float distance = sqrt(distanceSquared);
                    density.x += uniforms.particleMass * densityKernelFast(distance, radius, densityScale);
                    density.y += uniforms.particleMass * nearKernelFast(distance, radius, nearScale);
                }
            }
            entryIndex++;
        }
    }
    return density;
}

struct ForceResult {
    float3 pressure;
    float3 viscosity;
};

ForceResult calculateForces(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float3 samplePosition,
    float sampleDensity,
    float sampleNearDensity,
    float3 sampleVelocity,
    constant Uniforms &uniforms
) {
    ForceResult result = {float3(0.0), float3(0.0)};
    float radius = uniforms.smoothingRadius;
    float radiusSquared = radius * radius;
    float radius4 = radiusSquared * radiusSquared;
    float slopeScale = -15.0 / (PI * radius4 * radius);
    float nearSlopeScale = -45.0 / (PI * radius4 * radiusSquared);
    float densityScale = 15.0 / (2.0 * PI * radius4 * radius);
    int3 sampleCell = getCell3D(samplePosition, radius);

    for (uint offsetIndex = 0; offsetIndex < 27; offsetIndex++) {
        int3 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell3D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];
        if (entryIndex == 0xffffffffu) {
            continue;
        }
        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            Particle particle = particles[lookupEntries[entryIndex].particleIndex];
            if (all(getCell3D(particle.predictedPosition, radius) == cell)) {
                float3 offset = particle.predictedPosition - samplePosition;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared > 0.00000001 && distanceSquared < radiusSquared) {
                    float distance = sqrt(distanceSquared);
                    float neighborDensity = max(particle.density, 0.0001);
                    float pressure = calculateSharedPressure(sampleDensity, neighborDensity, uniforms.targetDensity, uniforms.pressureMultiplier);
                    float nearPressure = calculateSharedNearPressure(sampleNearDensity, particle.nearDensity, uniforms.nearPressureMultiplier);
                    float slope = densitySlopeFast(distance, radius, slopeScale);
                    float nearSlope = nearSlopeFast(distance, radius, nearSlopeScale);
                    result.pressure += (pressure * slope + nearPressure * nearSlope)
                        * (offset / distance) * uniforms.particleMass / neighborDensity;
                    float influence = densityKernelFast(distance, radius, densityScale);
                    result.viscosity += (particle.velocity - sampleVelocity)
                        * influence * uniforms.particleMass / neighborDensity;
                }
            }
            entryIndex++;
        }
    }
    result.viscosity *= uniforms.viscosityStrength;
    return result;
}

inline void resolveCollider(thread Particle &particle, constant Uniforms &uniforms) {
    if (uniforms.colliderEnabled == 0 || uniforms.colliderCollisions == 0) {
        return;
    }
    float3 halfSize = uniforms.colliderSize * 0.5 + uniforms.particleSize;
    float3 local = particle.position - uniforms.colliderPosition;
    if (any(abs(local) >= halfSize)) {
        return;
    }
    float3 penetration = halfSize - abs(local);
    float3 normal;
    if (penetration.x <= penetration.y && penetration.x <= penetration.z) {
        normal = float3(local.x < 0.0 ? -1.0 : 1.0, 0.0, 0.0);
        particle.position.x = uniforms.colliderPosition.x + normal.x * halfSize.x;
    } else if (penetration.y <= penetration.z) {
        normal = float3(0.0, local.y < 0.0 ? -1.0 : 1.0, 0.0);
        particle.position.y = uniforms.colliderPosition.y + normal.y * halfSize.y;
    } else {
        normal = float3(0.0, 0.0, local.z < 0.0 ? -1.0 : 1.0);
        particle.position.z = uniforms.colliderPosition.z + normal.z * halfSize.z;
    }
    float3 colliderVelocity = float3(0.0);
    if (uniforms.colliderFloating != 0) {
        colliderVelocity.y = cos(uniforms.time * 1.35) * 0.216;
    }
    float normalSpeed = dot(particle.velocity - colliderVelocity, normal);
    if (normalSpeed < 0.0) {
        particle.velocity -= normal * normalSpeed * 1.2;
        particle.velocity *= 0.985;
    }
}

kernel void predictPositions(
    device Particle *particles [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle particle = particles[id];
    float3 predictedVelocity = particle.velocity + float3(0.0, -uniforms.gravity, 0.0) * uniforms.dt;
    particle.predictedPosition = particle.position + predictedVelocity * uniforms.dt;
    float3 limit = uniforms.bounds * 0.5 - uniforms.particleSize;
    particle.predictedPosition = clamp(particle.predictedPosition, -limit, limit);
    particles[id] = particle;
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
    Particle particle = particles[id];
    float density = max(particle.density, 0.0001);
    ForceResult forces = calculateForces(
        particles, lookupEntries, cellStartIndices, particle.predictedPosition,
        density, particle.nearDensity, particle.velocity, uniforms
    );
    float3 acceleration = forces.pressure / density + forces.viscosity;
    acceleration.y -= uniforms.gravity;
    particle.velocity += acceleration * uniforms.dt;

    float3 mouseOffset = particle.position - uniforms.mousePosition;
    float mouseDistanceSquared = dot(mouseOffset, mouseOffset);
    float mouseRadiusSquared = uniforms.mouseRadius * uniforms.mouseRadius;
    if (uniforms.mouseMode != 0 && mouseDistanceSquared < mouseRadiusSquared) {
        float mouseDistance = sqrt(mouseDistanceSquared);
        float influence = 1.0 - mouseDistance / max(uniforms.mouseRadius, 0.0001);
        float3 direction = mouseDistance > 0.0001 ? mouseOffset / mouseDistance : float3(0.0);
        if (uniforms.mouseMode == 1) {
            influence *= influence;
            particle.velocity += (direction * uniforms.mouseStrength + uniforms.mouseVelocity * 2.0)
                * influence * uniforms.dt;
        } else {
            float containment = max(0.0, mouseDistance - uniforms.mouseRadius * 0.7);
            float3 desiredVelocity = uniforms.mouseVelocity - direction * containment * 6.0;
            float response = 1.0 - exp(-max(0.0, uniforms.mouseStrength) * influence * uniforms.dt);
            particle.velocity = mix(particle.velocity, desiredVelocity, response);
        }
    }

    if (uniforms.dt > 0.0) {
        float speedSquared = dot(particle.velocity, particle.velocity);
        float maxSpeed = uniforms.smoothingRadius * 0.4 / uniforms.dt;
        if (speedSquared > maxSpeed * maxSpeed) {
            particle.velocity *= maxSpeed * rsqrt(speedSquared);
        }
    }

    particle.position += particle.velocity * uniforms.dt;
    resolveCollider(particle, uniforms);
    float3 limit = uniforms.bounds * 0.5 - uniforms.particleSize;
    if (any(abs(particle.position) > limit)) {
        if (abs(particle.position.x) > limit.x) {
            particle.velocity.x *= -0.2;
            particle.velocity.yz *= 0.985;
        }
        if (abs(particle.position.y) > limit.y) {
            particle.velocity.y *= -0.2;
            particle.velocity.xz *= 0.985;
        }
        if (abs(particle.position.z) > limit.z) {
            particle.velocity.z *= -0.2;
            particle.velocity.xy *= 0.985;
        }
        particle.position = clamp(particle.position, -limit, limit);
    }
    outputParticles[id] = particle;
}

kernel void calculateDensities(
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
    Particle particle = particles[id];
    float2 densities = calculateDensitiesAtPosition(
        particles, lookupEntries, cellStartIndices, particle.predictedPosition, uniforms
    );
    particle.density = densities.x;
    particle.nearDensity = densities.y;
    outputParticles[id] = particle;
}

kernel void updateSpatialLookup(
    device const Particle *particles [[buffer(0)]],
    device SpatialLookupEntry *lookupOut [[buffer(1)]],
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
    int3 cell = getCell3D(particles[id].predictedPosition, uniforms.smoothingRadius);
    lookupOut[id].particleIndex = id;
    lookupOut[id].cellKey = keyFromHash(hashCell3D(cell), uniforms.particleCount);
}

kernel void sortSpatialLookup(
    device SpatialLookupEntry *entries [[buffer(0)]],
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
    SpatialLookupEntry entry = entries[id];
    SpatialLookupEntry partner = entries[partnerIndex];
    bool ascending = (id & sequenceLength) == 0;
    bool entryGreater = entry.cellKey > partner.cellKey
        || (entry.cellKey == partner.cellKey && entry.particleIndex > partner.particleIndex);
    bool partnerGreater = partner.cellKey > entry.cellKey
        || (partner.cellKey == entry.cellKey && partner.particleIndex > entry.particleIndex);
    if ((ascending && entryGreater) || (!ascending && partnerGreater)) {
        entries[id] = partner;
        entries[partnerIndex] = entry;
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
