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
    device const uint *particleNextIndices,
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
        uint particleIndex = cellStartIndices[key];
        if (particleIndex == 0xffffffffu) {
            continue;
        }
        while (particleIndex != 0xffffffffu) {
            Particle particle = particles[particleIndex];
            if (all(getCell3D(particle.predictedPosition, radius) == cell)) {
                float3 offset = particle.predictedPosition - samplePosition;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared < radiusSquared) {
                    float distance = sqrt(distanceSquared);
                    density.x += uniforms.particleMass * densityKernelFast(distance, radius, densityScale);
                    density.y += uniforms.particleMass * nearKernelFast(distance, radius, nearScale);
                }
            }
            particleIndex = particleNextIndices[particleIndex];
        }
    }
    float3 wallDistance = uniforms.bounds * 0.5 - abs(samplePosition);
    for (uint axis = 0; axis < 3; axis++) {
        float ghostDistance = max(wallDistance[axis] * 2.0, 0.0);
        if (ghostDistance < radius) {
            density.x += uniforms.particleMass * densityKernelFast(ghostDistance, radius, densityScale);
            density.y += uniforms.particleMass * nearKernelFast(ghostDistance, radius, nearScale);
        }
    }
    return density;
}

struct ForceResult {
    float3 pressure;
    float3 viscosity;
    float agitation;
    uint neighbours;
};

ForceResult calculateForces(
    device const Particle *particles,
    device const uint *particleNextIndices,
    device const uint *cellStartIndices,
    float3 samplePosition,
    float sampleDensity,
    float sampleNearDensity,
    float3 sampleVelocity,
    constant Uniforms &uniforms
) {
    ForceResult result = {float3(0.0), float3(0.0), 0.0, 0};
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
        uint particleIndex = cellStartIndices[key];
        if (particleIndex == 0xffffffffu) {
            continue;
        }
        while (particleIndex != 0xffffffffu) {
            Particle particle = particles[particleIndex];
            if (all(getCell3D(particle.predictedPosition, radius) == cell)) {
                float3 offset = particle.predictedPosition - samplePosition;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared > 0.00000001 && distanceSquared < radiusSquared) {
                    float distance = sqrt(distanceSquared);
                    float neighborDensity = max(particle.density, uniforms.targetDensity * 0.15);
                    float neighborNearDensity = max(particle.nearDensity, 0.01);
                    float pressure = calculateSharedPressure(sampleDensity, neighborDensity, uniforms.targetDensity, uniforms.pressureMultiplier);
                    float nearPressure = calculateSharedNearPressure(sampleNearDensity, particle.nearDensity, uniforms.nearPressureMultiplier);
                    float slope = densitySlopeFast(distance, radius, slopeScale);
                    float nearSlope = nearSlopeFast(distance, radius, nearSlopeScale);
                    float3 direction = offset / distance;
                    result.pressure += direction * uniforms.particleMass
                        * (pressure * slope / neighborDensity + nearPressure * nearSlope / neighborNearDensity);
                    float influence = densityKernelFast(distance, radius, densityScale);
                    result.viscosity += (particle.velocity - sampleVelocity)
                        * influence * uniforms.particleMass / neighborDensity;
                    float3 relativeVelocity = sampleVelocity - particle.velocity;
                    float relativeSpeed = length(relativeVelocity);
                    float3 relativeDirection = relativeSpeed > 0.000001
                        ? relativeVelocity / relativeSpeed
                        : float3(0.0);
                    float convergence = 1.0 - dot(relativeDirection, -direction);
                    result.agitation += relativeSpeed * convergence * (1.0 - distance / radius);
                    result.neighbours++;
                }
            }
            particleIndex = particleNextIndices[particleIndex];
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
    float3 colliderVelocity = uniforms.colliderVelocity;
    float normalSpeed = dot(particle.velocity - colliderVelocity, normal);
    if (normalSpeed < 0.0) {
        particle.velocity -= normal * normalSpeed * 1.2;
        particle.velocity *= 0.985;
    }
}

inline uint nextRandom(thread uint &state) {
    state = state * 747796405u + 2891336453u;
    uint result = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (result >> 22u) ^ result;
}

inline float randomValue(thread uint &state) {
    return float(nextRandom(state)) / 4294967295.0;
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
    device const uint *particleNextIndices [[buffer(2)]],
    device const uint *cellStartIndices [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    device FoamParticle *foamParticles [[buffer(5)]],
    device atomic_uint *foamCounter [[buffer(6)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle particle = particles[id];
    float density = max(particle.density, uniforms.targetDensity * 0.15);
    ForceResult forces = calculateForces(
        particles, particleNextIndices, cellStartIndices, particle.predictedPosition,
        density, particle.nearDensity, particle.velocity, uniforms
    );
    float3 acceleration = forces.pressure / density + forces.viscosity;
    acceleration.y -= uniforms.gravity;
    if (uniforms.dt > 0.0) {
        float accelerationSquared = dot(acceleration, acceleration);
        float maxAcceleration = max(
            60.0,
            uniforms.smoothingRadius * 0.08 / (uniforms.dt * uniforms.dt)
        );
        if (accelerationSquared > maxAcceleration * maxAcceleration) {
            acceleration *= maxAcceleration * rsqrt(accelerationSquared);
        }
    }
    particle.velocity += acceleration * uniforms.dt;
    particle.velocity *= exp(-0.08 * uniforms.dt);

    if (forces.neighbours < 8) {
        particle.velocity -= particle.velocity * uniforms.dt * 0.75;
    }

    if (uniforms.foamEnabled != 0 && uniforms.dt > 0.0 && uniforms.foamParticleCapacity > 0) {
        float kineticEnergy = dot(particle.velocity, particle.velocity);
        float agitation = max(forces.agitation - uniforms.foamThreshold, 0.0);
        float kineticFactor = saturate((kineticEnergy - 3.0) / 30.0);
        float surfaceFactor = forces.neighbours < 12
            ? saturate((kineticEnergy - 1.5) / 18.0)
            : 0.0;
        float spawnProbability = saturate(
            (agitation * kineticFactor
                + surfaceFactor * 1.5 * float(uniforms.sprayEnabled) * uniforms.sprayIntensity)
            * uniforms.foamIntensity * uniforms.dt * 0.035
        );
        uint randomState = id * 19349669u ^ as_type<uint>(uniforms.time) * 83492791u;
        if (randomValue(randomState) < spawnProbability) {
            uint foamIndex = atomic_fetch_add_explicit(&foamCounter[0], 1u, memory_order_relaxed)
                % uniforms.foamParticleCapacity;
            float3 jitter = float3(
                randomValue(randomState) * 2.0 - 1.0,
                randomValue(randomState) * 2.0 - 1.0,
                randomValue(randomState) * 2.0 - 1.0
            );
            FoamParticle foam;
            foam.position = particle.position + jitter * uniforms.smoothingRadius * 0.65;
            foam.velocity = particle.velocity + jitter * 0.35;
            foam.lifetime = mix(4.0, 9.0, randomValue(randomState));
            foam.scale = mix(0.65, 1.35, randomValue(randomState));
            foam.kind = forces.neighbours <= 5 && uniforms.sprayEnabled != 0
                ? 0.0
                : (forces.neighbours >= 18 ? 2.0 : 1.0);
            foamParticles[foamIndex] = foam;
        }
    }

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
        float maxSpeed = uniforms.smoothingRadius * 0.3 / uniforms.dt;
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
    device const uint *particleNextIndices [[buffer(2)]],
    device const uint *cellStartIndices [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    Particle particle = particles[id];
    float2 densities = calculateDensitiesAtPosition(
        particles, particleNextIndices, cellStartIndices, particle.predictedPosition, uniforms
    );
    particle.density = densities.x;
    particle.nearDensity = densities.y;
    outputParticles[id] = particle;
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

kernel void buildSpatialLinkedList(
    device const Particle *particles [[buffer(0)]],
    device atomic_uint *cellStartIndices [[buffer(1)]],
    device uint *particleNextIndices [[buffer(2)]],
    constant Uniforms &uniforms [[buffer(3)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    int3 cell = getCell3D(particles[id].predictedPosition, uniforms.smoothingRadius);
    uint key = keyFromHash(hashCell3D(cell), uniforms.particleCount);
    particleNextIndices[id] = atomic_exchange_explicit(
        &cellStartIndices[key], id, memory_order_relaxed
    );
}

kernel void updateFoamParticles(
    device FoamParticle *foamParticles [[buffer(0)]],
    device const Particle *particles [[buffer(1)]],
    device const uint *particleNextIndices [[buffer(2)]],
    device const uint *cellStartIndices [[buffer(3)]],
    constant Uniforms &uniforms [[buffer(4)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.foamParticleCapacity) {
        return;
    }
    FoamParticle foam = foamParticles[id];
    if (foam.lifetime <= 0.0 || uniforms.dt <= 0.0) {
        return;
    }

    float radius = uniforms.smoothingRadius;
    float radiusSquared = radius * radius;
    float radius4 = radiusSquared * radiusSquared;
    float kernelScale = 315.0 / (64.0 * PI * radius4 * radius4 * radius);
    int3 sampleCell = getCell3D(foam.position, radius);
    float3 velocitySum = float3(0.0);
    float weightSum = 0.0;
    uint neighbourCount = 0;

    for (uint offsetIndex = 0; offsetIndex < 27; offsetIndex++) {
        int3 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell3D(cell), uniforms.particleCount);
        uint particleIndex = cellStartIndices[key];
        if (particleIndex == 0xffffffffu) {
            continue;
        }
        while (particleIndex != 0xffffffffu) {
            Particle particle = particles[particleIndex];
            if (all(getCell3D(particle.predictedPosition, radius) == cell)) {
                float3 offset = particle.predictedPosition - foam.position;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared < radiusSquared) {
                    float remainder = radiusSquared - distanceSquared;
                    float weight = remainder * remainder * remainder * kernelScale;
                    velocitySum += particle.velocity * weight;
                    weightSum += weight;
                    neighbourCount++;
                }
            }
            particleIndex = particleNextIndices[particleIndex];
        }
    }

    if (neighbourCount <= 5) {
        foam.kind = 0.0;
        float speedSquared = dot(foam.velocity, foam.velocity);
        float3 drag = speedSquared > 0.000001
            ? -normalize(foam.velocity) * speedSquared * 0.04
            : float3(0.0);
        foam.velocity += (float3(0.0, -uniforms.gravity, 0.0) + drag) * uniforms.dt;
    } else if (neighbourCount >= 18 && weightSum > 0.000001) {
        foam.kind = 2.0;
        float3 fluidVelocity = velocitySum / weightSum;
        foam.velocity += ((fluidVelocity - foam.velocity) * 3.0 + float3(0.0, uniforms.gravity * 0.5, 0.0))
            * uniforms.dt;
        foam.scale = mix(foam.scale, 0.55, saturate(uniforms.dt * 5.0));
    } else if (weightSum > 0.000001) {
        foam.kind = 1.0;
        foam.velocity = mix(foam.velocity, velocitySum / weightSum, saturate(uniforms.dt * 12.0));
        foam.scale = mix(foam.scale, 1.0, saturate(uniforms.dt * 4.0));
    }

    foam.position += foam.velocity * uniforms.dt;
    foam.lifetime -= uniforms.dt;
    float radiusPadding = uniforms.foamScale * foam.scale;
    float3 limit = uniforms.bounds * 0.5 - radiusPadding;
    if (any(abs(foam.position) > limit)) {
        if (abs(foam.position.x) > limit.x) {
            foam.velocity.x *= -0.1;
        }
        if (abs(foam.position.y) > limit.y) {
            foam.velocity.y *= -0.1;
        }
        if (abs(foam.position.z) > limit.z) {
            foam.velocity.z *= -0.1;
        }
        foam.position = clamp(foam.position, -limit, limit);
    }
    foamParticles[id] = foam;
}
