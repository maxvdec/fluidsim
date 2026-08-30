#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

constant float densityFixedPointScale = 32.0;

inline uint densityLinearIndex(uint3 coordinate, uint3 resolution) {
    return coordinate.x + resolution.x * (coordinate.y + resolution.y * coordinate.z);
}

kernel void clearDensityAccumulation(
    device atomic_uint *densityAccumulation [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    uint voxelCount = uniforms.densityResolution.x
        * uniforms.densityResolution.y
        * uniforms.densityResolution.z;
    if (id < voxelCount) {
        atomic_store_explicit(&densityAccumulation[id], 0u, memory_order_relaxed);
    }
}

kernel void splatDensity(
    device const Particle *particles [[buffer(0)]],
    device atomic_uint *densityAccumulation [[buffer(1)]],
    constant Uniforms &uniforms [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= uniforms.particleCount) {
        return;
    }
    uint3 resolution = uniforms.densityResolution;
    float3 voxelSize = uniforms.bounds / float3(resolution);
    float3 gridPosition = (particles[id].position / uniforms.bounds + 0.5) * float3(resolution) - 0.5;
    int3 center = int3(round(gridPosition));
    int3 radius = int3(ceil(uniforms.smoothingRadius / voxelSize));
    float radiusSquared = uniforms.smoothingRadius * uniforms.smoothingRadius;
    float radius4 = radiusSquared * radiusSquared;
    float kernelScale = 15.0 / (2.0 * PI * radius4 * uniforms.smoothingRadius);

    for (int z = -radius.z; z <= radius.z; z++) {
        for (int y = -radius.y; y <= radius.y; y++) {
            for (int x = -radius.x; x <= radius.x; x++) {
                int3 coordinate = center + int3(x, y, z);
                if (any(coordinate < int3(0)) || any(coordinate >= int3(resolution))) {
                    continue;
                }
                float3 samplePosition = (float3(coordinate) + 0.5) / float3(resolution);
                samplePosition = (samplePosition - 0.5) * uniforms.bounds;
                float3 offset = particles[id].position - samplePosition;
                float distanceSquared = dot(offset, offset);
                if (distanceSquared >= radiusSquared) {
                    continue;
                }
                float remainder = uniforms.smoothingRadius - sqrt(distanceSquared);
                float density = remainder * remainder * kernelScale * uniforms.particleMass;
                uint contribution = uint(max(density * densityFixedPointScale, 0.0));
                atomic_fetch_add_explicit(
                    &densityAccumulation[densityLinearIndex(uint3(coordinate), resolution)],
                    contribution,
                    memory_order_relaxed
                );
            }
        }
    }
}

kernel void resolveDensity(
    device atomic_uint *densityAccumulation [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]],
    texture3d<float, access::write> densityTexture [[texture(0)]],
    uint id [[thread_position_in_grid]]
) {
    uint3 resolution = uniforms.densityResolution;
    uint voxelCount = resolution.x * resolution.y * resolution.z;
    if (id >= voxelCount) {
        return;
    }
    uint planeSize = resolution.x * resolution.y;
    uint3 coordinate = uint3(
        id % resolution.x,
        (id / resolution.x) % resolution.y,
        id / planeSize
    );
    float density = float(atomic_load_explicit(&densityAccumulation[id], memory_order_relaxed))
        / densityFixedPointScale;
    densityTexture.write(float4(density, 0.0, 0.0, 1.0), coordinate);
}
