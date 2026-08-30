//
//  FluidShader.metal
//  Aqua
//
//  Created by Max Van den Eynde on 30/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct FluidSurfaceHit {
    bool hit;
    float3 position;
    float density;
};

inline bool intersectBox(float3 rayOrigin, float3 rayDirection, float3 bounds, thread float &tEnter, thread float &tExit) {
    float3 halfBounds = bounds * 0.5;
    
    float3 boxMin = -halfBounds;
    float3 boxMax = halfBounds;
    
    float3 inverseDir = 1.0 / rayDirection;
    
    float3 t0 = (boxMin - rayOrigin) * inverseDir;
    
    float3 t1 = (boxMax - rayOrigin) * inverseDir;
    
    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);
    
    tEnter = max(max(tMin.x, tMin.y), tMin.z);
    tExit = min(min(tMax.x, tMax.y), tMax.z);
    
    return tExit >= max(tEnter, 0.0);
}


inline void generateCameraRay(uint2 pixel, uint2 resolution, float4x4 inverseViewProjection, thread float3 &rayOrigin, thread float3 &rayDirection) {
    float2 uv = (float2(pixel) + 0.5) / float2(resolution);
    
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    
    float4 nearClip = float4(ndc.x, ndc.y, 0.0, 1.0);
    
    float4 farClip = float4(ndc.x, ndc.y, 1.0, 1.0);
    
    float4 nearWorld = inverseViewProjection * nearClip;
    float4 farWorld = inverseViewProjection * farClip;
    
    nearWorld /= nearWorld.w;
    farWorld /= farWorld.w;
    
    rayOrigin = nearWorld.xyz;
    
    rayDirection = normalize(farWorld.xyz - nearWorld.xyz);
}

inline float3 worldToVolumeUV(
    float3 position,
    float3 bounds
) {
    return position / bounds + 0.5;
}

inline float sampleDensityFluid(float3 position, float3 bounds, texture3d<float, access::sample> densityTexture, sampler volumeSampler, float isoLevel) {
    float3 uvw = position / bounds + 0.5;
    
    if (any(uvw <= 0.001) || any(uvw >= 0.999)) {
        return -isoLevel;
    }
    
    return densityTexture.sample(volumeSampler, uvw).r - isoLevel;
}

inline float sampleField(
    float3 p,
    float3 bounds,
    texture3d<float, access::sample> tex,
    sampler s,
    float iso
) {
    float3 uvw = p / bounds + 0.5;

    if (any(uvw <= 0.001) || any(uvw >= 0.999)) {
        return -iso;
    }

    return tex.sample(s, uvw).r - iso;
}

inline float3 calculateVolumeNormal(
    float3 p,
    float3 bounds,
    texture3d<float, access::sample> tex,
    sampler s,
    float iso
) {
    float3 voxelSize = bounds / float3(
        tex.get_width(),
        tex.get_height(),
        tex.get_depth()
    );

    float dx =
        sampleField(p - float3(voxelSize.x, 0, 0), bounds, tex, s, iso) -
        sampleField(p + float3(voxelSize.x, 0, 0), bounds, tex, s, iso);

    float dy =
        sampleField(p - float3(0, voxelSize.y, 0), bounds, tex, s, iso) -
        sampleField(p + float3(0, voxelSize.y, 0), bounds, tex, s, iso);

    float dz =
        sampleField(p - float3(0, 0, voxelSize.z), bounds, tex, s, iso) -
        sampleField(p + float3(0, 0, voxelSize.z), bounds, tex, s, iso);

    return normalize(float3(dx, dy, dz));
}

inline FluidSurfaceHit raymarchFluidSurface(
    float3 rayOrigin,
    float3 rayDirection,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float stepSize,
    float isoLevel
) {
    FluidSurfaceHit result;
    result.hit = false;
    result.position = float3(0.0);
    result.density = 0.0;

    float tEnter;
    float tExit;

    if (!intersectBox(
        rayOrigin,
        rayDirection,
        bounds,
        tEnter,
        tExit
    )) {
        return result;
    }

    tEnter = max(tEnter, 0.0);

    float previousT = tEnter;

    float previousField = sampleDensityFluid(
        rayOrigin + rayDirection * previousT,
        bounds,
        densityTexture,
        volumeSampler,
        isoLevel
    );

    for (
        float t = tEnter + stepSize;
        t < tExit;
        t += stepSize
    ) {
        float3 worldPosition =
            rayOrigin + rayDirection * t;

        float field = sampleDensityFluid(
            worldPosition,
            bounds,
            densityTexture,
            volumeSampler,
            isoLevel
        );

        if (previousField <= 0.0 && field > 0.0) {
            result.hit = true;
            result.position = worldPosition;
            result.density = field + isoLevel;

            return result;
        }

        previousField = field;
        previousT = t;
    }

    return result;
}

kernel void renderVolume(texture3d<float, access::sample> densityTexture [[texture(0)]], texture2d<float, access::write> outputTexture [[texture(1)]], constant Uniforms &uniforms [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    
    if (id.x >= width || id.y >= height) {
        return;
    }
    
    constexpr sampler volumeSampler(
                                    mag_filter::linear, min_filter::linear, address::clamp_to_edge
                                    );
    
    float3 rayOrigin;
    float3 rayDirection;
    
    generateCameraRay(id, uint2(width, height), uniforms.invViewProjectionMatrix, rayOrigin, rayDirection);
    
    FluidSurfaceHit hit = raymarchFluidSurface(rayOrigin, rayDirection, uniforms.bounds, densityTexture, volumeSampler, uniforms.stepSize, uniforms.isoLevel);
    
    if (!hit.hit) {
        outputTexture.write(float4(0.0, 0.0, 0.0, 1.0), id);
        return;
    }
    
    float brighness = 1.0 - exp(-hit.density * uniforms.densityMultiplier);
    
    float3 scatter = float3(uniforms.scatterR, uniforms.scatterG, uniforms.scatterB);
    
    outputTexture.write(float4(scatter * bri, 1.0), id);
}
