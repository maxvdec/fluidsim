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

float2 calculateDensitiesAtPositionForPass(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float3 samplePos,
    constant Uniforms& uniforms
) {
    float density = 0.0;
    float nearDensity = 0.0;

    int3 sampleCell = getCell3D(samplePos, uniforms.smoothingRadius);
    bool needsBoundaryGhosts = any(
        uniforms.bounds * 0.5 - abs(samplePos) < uniforms.smoothingRadius
    );

    for (uint offsetIndex = 0; offsetIndex < 27; offsetIndex++) {
        int3 cell = sampleCell + getSpatialNeighborOffset(offsetIndex);
        uint key = keyFromHash(hashCell3D(cell), uniforms.particleCount);
        uint entryIndex = cellStartIndices[key];

        if (entryIndex == 0xffffffffu) {
            continue;
        }

        while (entryIndex < uniforms.particleCount && lookupEntries[entryIndex].cellKey == key) {
            uint particleIndex = lookupEntries[entryIndex].particleIndex;
            Particle p = particles[particleIndex];

            if (all(getCell3D(p.predictedPosition, uniforms.smoothingRadius) == cell)) {
                float dst = length(p.predictedPosition - samplePos);
                density += uniforms.particleMass * smoothingKernel(uniforms.smoothingRadius, dst);
                nearDensity += uniforms.particleMass * nearDensityKernel(uniforms.smoothingRadius, dst);

                if (needsBoundaryGhosts) {
                    for (uint ghostIndex = 0; ghostIndex < 26; ghostIndex++) {
                        int3 direction = getBoundaryGhostDirection(ghostIndex);
                        if (boundaryGhostIsActive(samplePos, uniforms.bounds, uniforms.smoothingRadius, direction)) {
                            float3 ghostPosition = boundaryGhostPosition(p.predictedPosition, uniforms.bounds, direction);
                            float ghostDst = length(ghostPosition - samplePos);
                            density += uniforms.particleMass * smoothingKernel(uniforms.smoothingRadius, ghostDst);
                            nearDensity += uniforms.particleMass * nearDensityKernel(uniforms.smoothingRadius, ghostDst);
                        }
                    }
                }
            }

            entryIndex++;
        }
    }

    return float2(density, nearDensity);
}

kernel void renderDensity(device const Particle* particles [[buffer(0)]], device const SpatialLookupEntry *lookupEntries [[buffer(1)]],
                          device const uint *cellStartIndices [[buffer(2)]], constant Uniforms& uniforms [[buffer(3)]],
                          texture3d<float, access::write> densityTexture [[texture(0)]], uint3 id [[thread_position_in_grid]]) {
    uint3 size = uint3(
        densityTexture.get_width(),
        densityTexture.get_height(),
        densityTexture.get_depth()
    );
    
    if (any(id >= size)) {
        return;
    }
    
    float3 uvw = (float3(id) + 0.5) / float3(size);
    
    float3 samplePosition = (uvw - 0.5) * uniforms.bounds;
    
    float2 densities = calculateDensitiesAtPositionForPass(particles, lookupEntries, cellStartIndices, samplePosition, uniforms);
    
    float density = densities.x;
    
    float maximumDensity = uniforms.targetDensity * 2.0;
    
    float normalizedDensity = clamp(density / max(maximumDensity, 0.0001), 0.0, 1.0);
    
    densityTexture.write(normalizedDensity, id);
}
