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

kernel void renderVolume(texture3d<float, access::sample> densityTexture [[texture(0)]], texture2d<float, access::write> outputTexture [[texture(1)]], constant Uniforms &uniforms [[buffer(0)]], uint2 id [[thread_position_in_grid]]) {
    uint width = outputTexture.get_width();
    uint height = outputTexture.get_height();
    
    if (id.x >= width || id.y >= height) {
        return;
    }
    
    float3 rayOrigin;
    float3 rayDirection;

    generateCameraRay(
        id,
        uint2(width, height),
        uniforms.invViewProjectionMatrix,
        rayOrigin,
        rayDirection
    );

    float slice =
        clamp(
            uniforms.textureSlice,
            0.0,
            1.0
        );

    float sliceZ =
        mix(
            -uniforms.bounds.z * 0.5,
             uniforms.bounds.z * 0.5,
             slice
        );

    if (abs(rayDirection.z) < 0.000001) {
        outputTexture.write(
            float4(0.0),
            id
        );
        return;
    }

    float t =
        (sliceZ - rayOrigin.z)
        / rayDirection.z;

    if (t < 0.0) {
        outputTexture.write(
            float4(0.0),
            id
        );
        return;
    }

    float3 worldPosition =
        rayOrigin + rayDirection * t;

    float3 halfBounds =
        uniforms.bounds * 0.5;

    if (
        abs(worldPosition.x) > halfBounds.x ||
        abs(worldPosition.y) > halfBounds.y
    ) {
        outputTexture.write(
            float4(0.0),
            id
        );
        return;
    }

    float3 uvw =
        worldToVolumeUV(
            worldPosition,
            uniforms.bounds
        );

    constexpr sampler volumeSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float density =
        densityTexture.sample(
            volumeSampler,
            uvw
        ).r;

    outputTexture.write(
        float4(
            density,
            density,
            density,
            1.0
        ),
        id
    );
}
