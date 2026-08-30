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
        float4(
            ndc.x,
            ndc.y,
            0.0,
            1.0
        );

    float4 farClip =
        float4(
            ndc.x,
            ndc.y,
            1.0,
            1.0
        );

    float4 nearWorld =
        inverseViewProjection *
        nearClip;

    float4 farWorld =
        inverseViewProjection *
        farClip;

    nearWorld /= nearWorld.w;
    farWorld /= farWorld.w;

    rayOrigin = nearWorld.xyz;

    rayDirection =
        normalize(
            farWorld.xyz -
            nearWorld.xyz
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
        worldToVolumeUV(
            position,
            bounds
        );

    constexpr float epsilon = 0.001;

    if (
        any(uvw <= float3(epsilon)) ||
        any(uvw >= float3(1.0 - epsilon))
    ) {
        return -isoLevel;
    }

    return
        densityTexture.sample(
            volumeSampler,
            uvw
        ).r
        - isoLevel;
}


inline float sampleField(
    float3 position,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float isoLevel
) {
    return sampleDensityFluid(
        position,
        bounds,
        densityTexture,
        volumeSampler,
        isoLevel
    );
}


// ============================================================
// MARK: - Normal calculation
// ============================================================

inline float3 calculateClosestFaceNormal(
    float3 boxSize,
    float3 position
) {
    float3 halfSize =
        boxSize * 0.5;

    float3 distanceToFace =
        halfSize - abs(position);

    if (
        distanceToFace.x < distanceToFace.y &&
        distanceToFace.x < distanceToFace.z
    ) {
        return float3(
            sign(position.x),
            0.0,
            0.0
        );
    }

    if (distanceToFace.y < distanceToFace.z) {
        return float3(
            0.0,
            sign(position.y),
            0.0
        );
    }

    return float3(
        0.0,
        0.0,
        sign(position.z)
    );
}


inline float3 calculateVolumeNormal(
    float3 position,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float isoLevel
) {
    //
    // Actual world-space dimensions of one voxel.
    //
    float3 voxelSize =
        bounds /
        float3(
            float(densityTexture.get_width()),
            float(densityTexture.get_height()),
            float(densityTexture.get_depth())
        );

    voxelSize =
        max(
            voxelSize,
            float3(0.0001)
        );

    //
    // Central derivatives.
    //
    // IMPORTANT:
    //
    // We divide by the physical spacing on each axis.
    // Your volume isn't cubic in world space, so without this,
    // X/Y/Z derivatives have different scales and the normal
    // becomes distorted.
    //
    float dx =
        (
            sampleField(
                position -
                    float3(
                        voxelSize.x,
                        0.0,
                        0.0
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
            -
            sampleField(
                position +
                    float3(
                        voxelSize.x,
                        0.0,
                        0.0
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
        )
        /
        (2.0 * voxelSize.x);

    float dy =
        (
            sampleField(
                position -
                    float3(
                        0.0,
                        voxelSize.y,
                        0.0
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
            -
            sampleField(
                position +
                    float3(
                        0.0,
                        voxelSize.y,
                        0.0
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
        )
        /
        (2.0 * voxelSize.y);

    float dz =
        (
            sampleField(
                position -
                    float3(
                        0.0,
                        0.0,
                        voxelSize.z
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
            -
            sampleField(
                position +
                    float3(
                        0.0,
                        0.0,
                        voxelSize.z
                    ),
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            )
        )
        /
        (2.0 * voxelSize.z);

    float3 gradient =
        float3(
            dx,
            dy,
            dz
        );

    float gradientLength =
        length(gradient);

    if (gradientLength < 0.00001) {
        return float3(
            0.0,
            1.0,
            0.0
        );
    }

    float3 volumeNormal =
        gradient /
        gradientLength;

    //
    // Sebastian-style boundary correction.
    //
    // Near the simulation walls, flatten the reconstructed
    // fluid normal toward the nearest box face.
    //
    float3 distanceFromFaces =
        bounds * 0.5 -
        abs(position);

    float faceDistance =
        min(
            distanceFromFaces.x,
            min(
                distanceFromFaces.y,
                distanceFromFaces.z
            )
        );

    float3 faceNormal =
        calculateClosestFaceNormal(
            bounds,
            position
        );

    constexpr float smoothDistance = 0.3;
    constexpr float smoothPower = 5.0;

    float faceWeight =
        1.0 -
        smoothstep(
            0.0,
            smoothDistance,
            faceDistance
        );

    //
    // Avoid flattening upward-facing free surfaces.
    //
    faceWeight *=
        1.0 -
        pow(
            saturate(volumeNormal.y),
            smoothPower
        );

    return normalize(
        volumeNormal *
            (1.0 - faceWeight)
        +
        faceNormal *
            faceWeight
    );
}


// ============================================================
// MARK: - Surface raymarching
// ============================================================

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

    if (
        !intersectBox(
            rayOrigin,
            rayDirection,
            bounds,
            tEnter,
            tExit
        )
    ) {
        return result;
    }

    tEnter =
        max(
            tEnter,
            0.0
        );

    float previousT =
        tEnter;

    float previousField =
        sampleDensityFluid(
            rayOrigin +
                rayDirection *
                previousT,
            bounds,
            densityTexture,
            volumeSampler,
            isoLevel
        );

    for (
        float t =
            tEnter +
            stepSize;

        t < tExit;

        t += stepSize
    ) {
        float3 worldPosition =
            rayOrigin +
            rayDirection *
            t;

        float field =
            sampleDensityFluid(
                worldPosition,
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            );

        //
        // Outside -> inside transition.
        //
        if (
            previousField <= 0.0 &&
            field > 0.0
        ) {
            //
            // Refine the surface with binary search.
            //
            float low =
                previousT;

            float high =
                t;

            for (
                int i = 0;
                i < 7;
                i++
            ) {
                float middle =
                    (low + high) *
                    0.5;

                float3 middlePosition =
                    rayOrigin +
                    rayDirection *
                    middle;

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
                (low + high) *
                0.5;

            float3 hitPosition =
                rayOrigin +
                rayDirection *
                hitT;

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

        previousField =
            field;

        previousT =
            t;
    }

    return result;
}


// ============================================================
// MARK: - Optical depth
// ============================================================

inline float calculateOpticalDepth(
    float3 rayOrigin,
    float3 rayDirection,
    float startT,
    float endT,
    float3 bounds,
    texture3d<float, access::sample> densityTexture,
    sampler volumeSampler,
    float stepSize,
    float isoLevel,
    float densityMultiplier
) {
    if (endT <= startT) {
        return 0.0;
    }

    float opticalDepth =
        0.0;

    //
    // Start halfway into the first step so we don't repeatedly
    // sample exactly on the surface.
    //
    float t =
        startT +
        stepSize * 0.5;

    for (
        ;
        t < endT;
        t += stepSize
    ) {
        float3 position =
            rayOrigin +
            rayDirection *
            t;

        float density =
            sampleDensityFluid(
                position,
                bounds,
                densityTexture,
                volumeSampler,
                isoLevel
            );

        if (density > 0.0) {
            opticalDepth +=
                density *
                densityMultiplier *
                stepSize;
        }
    }

    return opticalDepth;
}


// ============================================================
// MARK: - Environment
// ============================================================

inline float3 sampleEnvironment(
    float3 direction
) {
    direction =
        normalize(direction);

    //
    // Simple environment lighting.
    //
    // This does NOT need to be visible as your background;
    // we're simply using it as the light surrounding the fluid.
    //

    float3 groundColor =
        float3(
            0.055,
            0.065,
            0.085
        );

    float3 horizonColor =
        float3(
            0.85,
            0.92,
            1.0
        );

    float3 zenithColor =
        float3(
            0.12,
            0.38,
            0.78
        );

    float skyAmount =
        smoothstep(
            -0.05,
            0.05,
            direction.y
        );

    float skyGradient =
        pow(
            saturate(direction.y),
            0.35
        );

    float3 skyColor =
        mix(
            horizonColor,
            zenithColor,
            skyGradient
        );

    float3 environment =
        mix(
            groundColor,
            skyColor,
            skyAmount
        );

    //
    // Small bright directional sun.
    //
    float3 sunDirection =
        normalize(
            float3(
                -0.4,
                0.8,
                0.5
            )
        );

    float sun =
        pow(
            max(
                dot(
                    direction,
                    sunDirection
                ),
                0.0
            ),
            512.0
        );

    environment +=
        float3(
            1.0,
            0.95,
            0.85
        )
        *
        sun *
        3.0;

    return environment;
}


// ============================================================
// MARK: - Fresnel
// ============================================================

inline float fresnelSchlick(
    float NdotV,
    float F0
) {
    return
        F0 +
        (1.0 - F0) *
        pow(
            1.0 -
                saturate(NdotV),
            5.0
        );
}


// ============================================================
// MARK: - Color
// ============================================================

inline float3 linearToSRGB(
    float3 color
) {
    color =
        max(
            color,
            float3(0.0)
        );

    float3 low =
        color *
        12.92;

    float3 high =
        1.055 *
        pow(
            color,
            float3(
                1.0 / 2.4
            )
        )
        -
        0.055;

    return select(
        high,
        low,
        color <= float3(0.0031308)
    );
}


// ============================================================
// MARK: - Final render
// ============================================================

kernel void renderVolume(
    texture3d<float, access::sample>
        densityTexture [[texture(0)]],

    texture2d<float, access::write>
        outputTexture [[texture(1)]],

    constant Uniforms &
        uniforms [[buffer(0)]],

    uint2 id
        [[thread_position_in_grid]]
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

    // --------------------------------------------------------
    // Camera ray
    // --------------------------------------------------------

    float3 rayOrigin;
    float3 rayDirection;

    generateCameraRay(
        id,
        uint2(
            width,
            height
        ),
        uniforms.invViewProjectionMatrix,
        rayOrigin,
        rayDirection
    );

    // --------------------------------------------------------
    // Find fluid surface
    // --------------------------------------------------------

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

    //
    // Keep your background black.
    //
    if (!hit.hit) {
        outputTexture.write(
            float4(
                0.0,
                0.0,
                0.0,
                1.0
            ),
            id
        );

        return;
    }

    // --------------------------------------------------------
    // Determine distance through simulation box
    // --------------------------------------------------------

    float boxEnterT;
    float boxExitT;

    bool intersectsBounds =
        intersectBox(
            rayOrigin,
            rayDirection,
            uniforms.bounds,
            boxEnterT,
            boxExitT
        );

    if (!intersectsBounds) {
        outputTexture.write(
            float4(
                0.0,
                0.0,
                0.0,
                1.0
            ),
            id
        );

        return;
    }

    // --------------------------------------------------------
    // Integrate REAL density through the fluid
    // --------------------------------------------------------

    float opticalDepth =
        calculateOpticalDepth(
            rayOrigin,
            rayDirection,
            hit.t,
            boxExitT,
            uniforms.bounds,
            densityTexture,
            volumeSampler,
            uniforms.stepSize,
            uniforms.isoLevel,
            uniforms.densityMultiplier
        );

    // --------------------------------------------------------
    // Beer-Lambert extinction
    // --------------------------------------------------------

    //
    // IMPORTANT:
    //
    // Your existing defaults are approximately:
    //
    // scatterR = 0.15
    // scatterG = 0.8
    // scatterB = 2.0
    //
    // Those values were originally being used to CREATE blue
    // light:
    //
    //     1 - exp(-scatter * depth)
    //
    // But extinction does the opposite:
    //
    //     exp(-extinction * depth)
    //
    // Water needs to absorb RED more strongly than BLUE.
    //
    // So for now, reverse your existing controls.
    //
    // This gives:
    //
    // extinction ~= (2.0, 0.8, 0.15)
    //
    // which produces blue/cyan transmitted water.
    //

    float3 extinctionCoefficient =
        max(
            float3(
                uniforms.scatterR,
                uniforms.scatterG,
                uniforms.scatterB
            ),
            float3(0.0)
        );

    float3 transmittance =
        exp(
            -extinctionCoefficient *
            opticalDepth
        );

    // --------------------------------------------------------
    // Correct normal orientation
    // --------------------------------------------------------

    float3 normal =
        normalize(
            hit.normal
        );

    //
    // Normal should oppose the incoming camera ray.
    //
    if (
        dot(
            normal,
            rayDirection
        ) > 0.0
    ) {
        normal =
            -normal;
    }

    // --------------------------------------------------------
    // Fresnel
    // --------------------------------------------------------

    float3 viewDirection =
        normalize(
            -rayDirection
        );

    float NdotV =
        saturate(
            dot(
                normal,
                viewDirection
            )
        );

    //
    // Water-air interface:
    // F0 is approximately 0.02.
    //
    constexpr float waterF0 =
        0.0204;

    float fresnel =
        fresnelSchlick(
            NdotV,
            waterF0
        );

    // --------------------------------------------------------
    // Transmission
    // --------------------------------------------------------

    //
    // No refraction yet:
    //
    // simply continue looking in the original ray direction.
    //
    float3 environmentBehindFluid =
        sampleEnvironment(
            rayDirection
        );

    float3 transmittedLight =
        environmentBehindFluid *
        transmittance;

    // --------------------------------------------------------
    // Reflection
    // --------------------------------------------------------

    float3 reflectedDirection =
        reflect(
            rayDirection,
            normal
        );

    float3 reflectedLight =
        sampleEnvironment(
            reflectedDirection
        );

    // --------------------------------------------------------
    // Combine surface reflection + medium transmission
    // --------------------------------------------------------

    float3 finalColor =
        transmittedLight *
            (1.0 - fresnel)
        +
        reflectedLight *
            fresnel;

    // --------------------------------------------------------
    // Tiny amount of blue in-scattering
    // --------------------------------------------------------

    //
    // This is intentionally subtle.
    //
    // It prevents very deep water from becoming completely
    // black while NOT turning the whole volume into glowing
    // blue jelly like the previous 1-exp() implementation.
    //

    float meanTransmittance =
        (
            transmittance.r +
            transmittance.g +
            transmittance.b
        )
        /
        3.0;

    float absorbedAmount =
        1.0 -
        meanTransmittance;

    float3 inScatterColor =
        float3(
            0.015,
            0.055,
            0.085
        );

    finalColor +=
        inScatterColor *
        absorbedAmount;

    // --------------------------------------------------------
    // Exposure
    // --------------------------------------------------------

    //
    // Use your old brightnessMultiplier as exposure.
    //
    // IMPORTANT:
    // exposure belongs BEFORE tone mapping.
    //
    finalColor *=
        max(
            uniforms.brightnessMultiplier,
            0.0
        );

    // --------------------------------------------------------
    // Tone mapping
    // --------------------------------------------------------

    finalColor =
        finalColor /
        (
            finalColor +
            1.0
        );

    // --------------------------------------------------------
    // Gamma
    // --------------------------------------------------------

    //
    // Your MTKView currently uses .bgra8Unorm rather than
    // .bgra8Unorm_sRGB, so encode sRGB manually here.
    //
    finalColor =
        linearToSRGB(
            finalColor
        );

    // --------------------------------------------------------
    // Output
    // --------------------------------------------------------

    outputTexture.write(
        float4(
            finalColor,
            1.0
        ),
        id
    );
}
