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
    float t;
    float3 position;
    float3 normal;
};


inline bool intersectBox(
    float3 rayOrigin,
    float3 rayDirection,
    float3 bounds,
    thread float &tEnter,
    thread float &tExit
) {
    float3 halfBounds = bounds * 0.5;

    float3 boxMin = -halfBounds;
    float3 boxMax = halfBounds;

    float3 inverseDir = 1.0 / rayDirection;

    float3 t0 = (boxMin - rayOrigin) * inverseDir;
    float3 t1 = (boxMax - rayOrigin) * inverseDir;

    float3 tMin = min(t0, t1);
    float3 tMax = max(t0, t1);

    tEnter = max(
        max(tMin.x, tMin.y),
        tMin.z
    );

    tExit = min(
        min(tMax.x, tMax.y),
        tMax.z
    );

    return tExit >= max(tEnter, 0.0);
}


inline void generateCameraRay(
    uint2 pixel,
    uint2 resolution,
    float4x4 inverseViewProjection,
    thread float3 &rayOrigin,
    thread float3 &rayDirection
) {
    float2 uv =
        (float2(pixel) + 0.5) /
        float2(resolution);

    float2 ndc = float2(
        uv.x * 2.0 - 1.0,
        1.0 - uv.y * 2.0
    );

    float4 nearClip =
        float4(ndc.x, ndc.y, 0.0, 1.0);

    float4 farClip =
        float4(ndc.x, ndc.y, 1.0, 1.0);

    float4 nearWorld =
        inverseViewProjection * nearClip;

    float4 farWorld =
        inverseViewProjection * farClip;

    nearWorld /= nearWorld.w;
    farWorld /= farWorld.w;

    rayOrigin = nearWorld.xyz;

    rayDirection = normalize(
        farWorld.xyz - nearWorld.xyz
    );
}


inline float3 worldToVolumeUV(
    float3 position,
    float3 bounds
) {
    return position / bounds + 0.5;
}


inline float sampleDensityFluid(
    float3 position,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float isoLevel
) {
    float3 uvw =
        worldToVolumeUV(position, bounds);

    if (
        any(uvw <= 0.001) ||
        any(uvw >= 0.999)
    ) {
        return -isoLevel;
    }

    return densityTexture.sample(
        volumeSampler,
        uvw
    ).r - isoLevel;
}


inline float sampleField(
    float3 p,
    float3 bounds,
    texture3d<float, access::sample> tex,
    sampler s,
    float iso
) {
    return sampleDensityFluid(
        p,
        bounds,
        tex,
        s,
        iso
    );
}

inline float3 calculateVolumeNormal(
    float3 p,
    float3 bounds,
    texture3d<float, access::sample> tex,
    sampler s,
    float iso
) {
    float3 voxelSize =
        bounds /
        float3(
            float(tex.get_width()),
            float(tex.get_height()),
            float(tex.get_depth())
        );

    float dx =
        sampleField(
            p - float3(voxelSize.x, 0.0, 0.0),
            bounds,
            tex,
            s,
            iso
        )
        -
        sampleField(
            p + float3(voxelSize.x, 0.0, 0.0),
            bounds,
            tex,
            s,
            iso
        );

    float dy =
        sampleField(
            p - float3(0.0, voxelSize.y, 0.0),
            bounds,
            tex,
            s,
            iso
        )
        -
        sampleField(
            p + float3(0.0, voxelSize.y, 0.0),
            bounds,
            tex,
            s,
            iso
        );

    float dz =
        sampleField(
            p - float3(0.0, 0.0, voxelSize.z),
            bounds,
            tex,
            s,
            iso
        )
        -
        sampleField(
            p + float3(0.0, 0.0, voxelSize.z),
            bounds,
            tex,
            s,
            iso
        );

    float3 gradient =
        float3(dx, dy, dz);

    float gradientLength =
        length(gradient);

    if (gradientLength < 0.00001) {
        return float3(0.0, 1.0, 0.0);
    }

    return gradient / gradientLength;
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
    result.t = 0.0;
    result.position = float3(0.0);
    result.normal = float3(0.0);

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

    float previousField =
        sampleDensityFluid(
            rayOrigin +
                rayDirection * previousT,
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
            rayOrigin +
            rayDirection * t;

        float field =
            sampleDensityFluid(
                worldPosition,
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            );
        
        if (
            previousField <= 0.0 &&
            field > 0.0
        ) {
            float low = previousT;
            float high = t;

            for (int i = 0; i < 6; i++) {
                float middle =
                    (low + high) * 0.5;

                float3 middlePosition =
                    rayOrigin +
                    rayDirection * middle;

                float middleField =
                    sampleDensityFluid(
                        middlePosition,
                        bounds,
                        densityTexture,
                        volumeSampler,
                        isoLevel
                    );

                if (middleField > 0.0) {
                    high = middle;
                } else {
                    low = middle;
                }
            }

            float hitT =
                (low + high) * 0.5;

            float3 hitPosition =
                rayOrigin +
                rayDirection * hitT;

            result.hit = true;
            result.t = hitT;
            result.position = hitPosition;

            result.normal =
                calculateVolumeNormal(
                    hitPosition,
                    bounds,
                    densityTexture,
                    volumeSampler,
                    isoLevel
                );

            return result;
        }

        previousField = field;
        previousT = t;
    }

    return result;
}


inline float findFluidExit(
    float3 rayOrigin,
    float3 rayDirection,
    float startT,
    float boxExitT,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float stepSize,
    float isoLevel
) {

    float previousT =
        startT + stepSize * 0.5;

    float previousField =
        sampleDensityFluid(
            rayOrigin +
                rayDirection * previousT,
            bounds,
            densityTexture,
            volumeSampler,
            isoLevel
        );

    for (
        float t = previousT + stepSize;
        t < boxExitT;
        t += stepSize
    ) {
        float field =
            sampleDensityFluid(
                rayOrigin +
                    rayDirection * t,
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            );
        if (
            previousField > 0.0 &&
            field <= 0.0
        ) {


            float low = t - stepSize;
            float high = t;

            for (int i = 0; i < 6; i++) {
                float middle =
                    (low + high) * 0.5;

                float middleField =
                    sampleDensityFluid(
                        rayOrigin +
                            rayDirection * middle,
                        bounds,
                        densityTexture,
                        volumeSampler,
                        isoLevel
                    );

                if (middleField > 0.0) {
                    low = middle;
                } else {
                    high = middle;
                }
            }

            return (low + high) * 0.5;
        }

        previousField = field;
        previousT = t;
    }

    return boxExitT;
}

kernel void renderVolume(
    texture3d<float, access::sample>
        densityTexture [[texture(0)]],

    texture2d<float, access::write>
        outputTexture [[texture(1)]],

    constant Uniforms &uniforms [[buffer(0)]],

    uint2 id [[thread_position_in_grid]]
) {
    uint width =
        outputTexture.get_width();

    uint height =
        outputTexture.get_height();

    if (
        id.x >= width ||
        id.y >= height
    ) {
        return;
    }

    constexpr sampler volumeSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float3 rayOrigin;
    float3 rayDirection;

    generateCameraRay(
        id,
        uint2(width, height),
        uniforms.invViewProjectionMatrix,
        rayOrigin,
        rayDirection
    );

    FluidSurfaceHit hit =
        raymarchFluidSurface(
            rayOrigin,
            rayDirection,
            uniforms.bounds,
            densityTexture,
            volumeSampler,
            uniforms.stepSize,
            uniforms.isoLevel
        );

    if (!hit.hit) {
        outputTexture.write(
            float4(0.0, 0.0, 0.0, 1.0),
            id
        );

        return;
    }

    float boxEnterT;
    float boxExitT;

    intersectBox(
        rayOrigin,
        rayDirection,
        uniforms.bounds,
        boxEnterT,
        boxExitT
    );

    float fluidExitT =
        findFluidExit(
            rayOrigin,
            rayDirection,
            hit.t,
            boxExitT,
            uniforms.bounds,
            densityTexture,
            volumeSampler,
            uniforms.stepSize,
            uniforms.isoLevel
        );

    float thickness =
        max(
            fluidExitT - hit.t,
            0.0
        );

    float3 scatterCoefficient =
        max(
            float3(
                uniforms.scatterR,
                uniforms.scatterG,
                uniforms.scatterB
            ),
            float3(0.0)
        );


    float opticalThickness =
        thickness *
        uniforms.densityMultiplier;

    float3 scatteredLight =
        1.0 -
        exp(
            -scatterCoefficient *
            opticalThickness
        );

    float3 N =
        normalize(hit.normal);

    float3 lightDirection =
        normalize(
            float3(
                -0.4,
                0.8,
                0.5
            )
        );

    float diffuse =
        max(
            dot(N, lightDirection),
            0.0
        );

    float lighting =
        0.25 +
        diffuse * 0.75;

    float3 volumeColor =
        scatteredLight *
        lighting;

    float3 viewDirection =
        normalize(-rayDirection);

    float NdotV =
        clamp(
            dot(N, viewDirection),
            0.0,
            1.0
        );

    float F0 = 0.02;

    float fresnel =
        F0 +
        (1.0 - F0) *
        pow(
            1.0 - NdotV,
            5.0
        );

    float3 reflectionColor =
        float3(
            0.75,
            0.90,
            1.0
        );

    float3 finalColor =
        mix(
            volumeColor,
            reflectionColor,
            fresnel
        );

    finalColor =
        finalColor /
        (finalColor + 1.0);

    outputTexture.write(
        float4(finalColor * uniforms.brightnessMultiplier, 1.0),
        id
    );
}
