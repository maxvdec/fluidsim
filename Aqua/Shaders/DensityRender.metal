#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

float2 calculateVolumeFields(
    device const Particle *particles,
    device const SpatialLookupEntry *lookupEntries,
    device const uint *cellStartIndices,
    float3 samplePosition,
    constant Uniforms &uniforms
) {
    float density = 0.0;
    float foam = 0.0;
    float radius = uniforms.smoothingRadius;
    float radiusSquared = radius * radius;
    float radius4 = radiusSquared * radiusSquared;
    float kernelScale = 15.0 / (2.0 * PI * radius4 * radius);
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
                    float remainder = radius - distance;
                    float influence = remainder * remainder * kernelScale * uniforms.particleMass;
                    density += influence;
                    float surfaceExposure = saturate(
                        (uniforms.targetDensity * 0.9 - particle.density)
                        / max(uniforms.targetDensity * 0.75, 0.0001)
                    );
                    float agitation = saturate(length(particle.velocity) / 3.5);
                    foam += influence * surfaceExposure * (0.2 + agitation * 0.8);
                }
            }
            entryIndex++;
        }
    }

    float normalizedDensity = saturate(density / max(uniforms.targetDensity * 2.0, 0.0001));
    float normalizedFoam = density > 0.0001 ? saturate(foam / density) : 0.0;
    return float2(normalizedDensity, normalizedFoam);
}

kernel void renderDensity(
    device const Particle *particles [[buffer(0)]],
    device const SpatialLookupEntry *lookupEntries [[buffer(1)]],
    device const uint *cellStartIndices [[buffer(2)]],
    constant Uniforms &uniforms [[buffer(3)]],
    texture3d<float, access::write> densityTexture [[texture(0)]],
    uint3 id [[thread_position_in_grid]]
) {
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
    float2 fields = calculateVolumeFields(
        particles, lookupEntries, cellStartIndices, samplePosition, uniforms
    );
    densityTexture.write(float4(fields.x, fields.y, 0.0, 1.0), id);
}
