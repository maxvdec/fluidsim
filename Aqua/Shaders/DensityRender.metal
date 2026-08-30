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

float calculateDensityForPass(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float2 samplePos,
    constant Uniforms& uniforms
) {
    float density = 0.0;

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

                for (uint ghostIndex = 0; ghostIndex < 8; ghostIndex++) {
                    if (boundaryGhostIsActive(samplePos, uniforms.bounds, uniforms.smoothingRadius, ghostIndex)) {
                        float2 ghostPosition = boundaryGhostPosition(p.predictedPosition, uniforms.bounds, ghostIndex);
                        float ghostDst = length(ghostPosition - samplePos);
                        density += uniforms.particleMass * smoothingKernel(uniforms.smoothingRadius, ghostDst);
                    }
                }
            }

            entryIndex++;
        }
    }

    return density;
}

kernel void renderDensity(device const Particle* particles [[buffer(0)]], device const SpatialLookupEntry *lookupEntries [[buffer(1)]],
                          device const uint *cellStartIndices [[buffer(2)]], constant Uniforms& uniforms [[buffer(3)]],
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
        lookupEntries,
        cellStartIndices,
        samplePos,
        uniforms
    );
    
    output.write(float4(density, 0.0, 0.0, 1.0), gid);
}
