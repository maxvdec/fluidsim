#include <metal_stdlib>
#include "../BridgingHeader.h"
using namespace metal;

struct SurfaceHit {
    bool hit;
    float t;
    float3 position;
    float3 normal;
    float foam;
};

struct BoxHit {
    bool hit;
    float t;
    float3 position;
    float3 normal;
};

struct EnvironmentSample {
    float3 color;
    float distance;
    float3 position;
    bool hit;
};

inline float2 boxInterval(float3 origin, float3 direction, float3 center, float3 size) {
    float3 safeDirection = select(
        direction,
        copysign(float3(0.000001), direction),
        abs(direction) < float3(0.000001)
    );
    float3 inverseDirection = 1.0 / safeDirection;
    float3 halfSize = size * 0.5;
    float3 first = (center - halfSize - origin) * inverseDirection;
    float3 second = (center + halfSize - origin) * inverseDirection;
    float3 nearValues = min(first, second);
    float3 farValues = max(first, second);
    return float2(
        max(max(nearValues.x, nearValues.y), nearValues.z),
        min(min(farValues.x, farValues.y), farValues.z)
    );
}

inline BoxHit intersectBox(float3 origin, float3 direction, float3 center, float3 size) {
    BoxHit result = {false, 1e30, float3(0.0), float3(0.0)};
    float2 interval = boxInterval(origin, direction, center, size);
    if (interval.y < max(interval.x, 0.0)) {
        return result;
    }
    result.hit = true;
    result.t = interval.x > 0.0 ? interval.x : interval.y;
    result.position = origin + direction * result.t;
    float3 local = (result.position - center) / max(size * 0.5, float3(0.0001));
    float3 faceDistance = 1.0 - abs(local);
    if (faceDistance.x <= faceDistance.y && faceDistance.x <= faceDistance.z) {
        result.normal = float3(sign(local.x), 0.0, 0.0);
    } else if (faceDistance.y <= faceDistance.z) {
        result.normal = float3(0.0, sign(local.y), 0.0);
    } else {
        result.normal = float3(0.0, 0.0, sign(local.z));
    }
    return result;
}

inline void generateCameraRay(
    uint2 pixel,
    uint2 resolution,
    float4x4 inverseViewProjection,
    thread float3 &origin,
    thread float3 &direction
) {
    float2 uv = (float2(pixel) + 0.5) / float2(resolution);
    float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
    float4 nearWorld = inverseViewProjection * float4(ndc, 0.0, 1.0);
    float4 farWorld = inverseViewProjection * float4(ndc, 1.0, 1.0);
    nearWorld /= nearWorld.w;
    farWorld /= farWorld.w;
    origin = nearWorld.xyz;
    direction = normalize(farWorld.xyz - nearWorld.xyz);
}

inline float3 worldToVolumeUV(float3 position, float3 bounds) {
    return position / bounds + 0.5;
}

inline float2 sampleVolume(
    float3 position,
    float3 bounds,
    texture3d<float, access::sample> volume,
    sampler volumeSampler,
    float isoLevel
) {
    float3 uvw = worldToVolumeUV(position, bounds);
    if (any(uvw <= float3(0.0005)) || any(uvw >= float3(0.9995))) {
        return float2(-isoLevel, 0.0);
    }
    float4 sampleValue = volume.sample(volumeSampler, uvw);
    return float2(sampleValue.r - isoLevel, sampleValue.g);
}

inline float3 calculateNormal(
    float3 position,
    float3 bounds,
    texture3d<float, access::sample> volume,
    sampler volumeSampler,
    float isoLevel
) {
    float3 dimensions = float3(
        volume.get_width(),
        volume.get_height(),
        volume.get_depth()
    );
    float3 voxel = max(bounds / dimensions, float3(0.0001));
    float3 fineOffset = voxel * 0.65;
    float3 broadOffset = voxel * 1.35;
    float3 fine = float3(
        sampleVolume(position - float3(fineOffset.x, 0.0, 0.0), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(fineOffset.x, 0.0, 0.0), bounds, volume, volumeSampler, isoLevel).x,
        sampleVolume(position - float3(0.0, fineOffset.y, 0.0), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(0.0, fineOffset.y, 0.0), bounds, volume, volumeSampler, isoLevel).x,
        sampleVolume(position - float3(0.0, 0.0, fineOffset.z), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(0.0, 0.0, fineOffset.z), bounds, volume, volumeSampler, isoLevel).x
    ) / fineOffset;
    float3 broad = float3(
        sampleVolume(position - float3(broadOffset.x, 0.0, 0.0), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(broadOffset.x, 0.0, 0.0), bounds, volume, volumeSampler, isoLevel).x,
        sampleVolume(position - float3(0.0, broadOffset.y, 0.0), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(0.0, broadOffset.y, 0.0), bounds, volume, volumeSampler, isoLevel).x,
        sampleVolume(position - float3(0.0, 0.0, broadOffset.z), bounds, volume, volumeSampler, isoLevel).x
            - sampleVolume(position + float3(0.0, 0.0, broadOffset.z), bounds, volume, volumeSampler, isoLevel).x
    ) / broadOffset;
    float3 gradient = mix(broad, fine, 0.68);
    if (dot(gradient, gradient) < 0.00000001) {
        return float3(0.0, 1.0, 0.0);
    }
    float3 normal = normalize(gradient);
    float3 faceDistance = bounds * 0.5 - abs(position);
    float nearest = min(faceDistance.x, min(faceDistance.y, faceDistance.z));
    float3 faceNormal;
    if (faceDistance.x <= faceDistance.y && faceDistance.x <= faceDistance.z) {
        faceNormal = float3(sign(position.x), 0.0, 0.0);
    } else if (faceDistance.y <= faceDistance.z) {
        faceNormal = float3(0.0, sign(position.y), 0.0);
    } else {
        faceNormal = float3(0.0, 0.0, sign(position.z));
    }
    float boundaryBlend = (1.0 - smoothstep(0.0, min(voxel.x, min(voxel.y, voxel.z)) * 1.5, nearest))
        * (1.0 - pow(saturate(normal.y), 5.0));
    return normalize(mix(normal, faceNormal, boundaryBlend));
}

inline SurfaceHit raymarchTransition(
    float3 origin,
    float3 direction,
    bool entering,
    float3 bounds,
    texture3d<float, access::sample> volume,
    sampler volumeSampler,
    float stepSize,
    float isoLevel
) {
    SurfaceHit result = {false, 0.0, float3(0.0), float3(0.0), 0.0};
    float2 interval = boxInterval(origin, direction, float3(0.0), bounds);
    float start = max(interval.x, 0.0);
    float finish = interval.y;
    if (finish <= start) {
        return result;
    }
    float marchStep = max(stepSize, 0.002);
    float previousT = start;
    float previousField = sampleVolume(origin + direction * previousT, bounds, volume, volumeSampler, isoLevel).x;
    for (int iteration = 0; iteration < 900; iteration++) {
        float currentT = min(previousT + marchStep, finish);
        float currentField = sampleVolume(origin + direction * currentT, bounds, volume, volumeSampler, isoLevel).x;
        bool crossed = entering
            ? previousField <= 0.0 && currentField > 0.0
            : previousField > 0.0 && currentField <= 0.0;
        if (crossed) {
            float low = previousT;
            float high = currentT;
            for (int refinement = 0; refinement < 7; refinement++) {
                float middle = (low + high) * 0.5;
                float field = sampleVolume(origin + direction * middle, bounds, volume, volumeSampler, isoLevel).x;
                if ((entering && field > 0.0) || (!entering && field <= 0.0)) {
                    high = middle;
                } else {
                    low = middle;
                }
            }
            result.hit = true;
            result.t = (low + high) * 0.5;
            result.position = origin + direction * result.t;
            result.normal = calculateNormal(result.position, bounds, volume, volumeSampler, isoLevel);
            result.foam = sampleVolume(result.position, bounds, volume, volumeSampler, isoLevel).y;
            return result;
        }
        if (currentT >= finish) {
            break;
        }
        previousT = currentT;
        previousField = currentField;
    }
    return result;
}

inline float integrateDensity(
    float3 origin,
    float3 direction,
    float distance,
    float3 bounds,
    texture3d<float, access::sample> volume,
    sampler volumeSampler,
    float stepSize,
    float isoLevel,
    float multiplier
) {
    float result = 0.0;
    float integrationStep = max(stepSize * 1.5, 0.004);
    for (int iteration = 0; iteration < 512; iteration++) {
        float t = (float(iteration) + 0.5) * integrationStep;
        if (t >= distance) {
            break;
        }
        float density = sampleVolume(origin + direction * t, bounds, volume, volumeSampler, isoLevel).x;
        result += max(density, 0.0) * integrationStep;
    }
    return result * multiplier;
}

inline float hash31(float3 point) {
    point = fract(point * 0.1031);
    point += dot(point, point.yzx + 33.33);
    return fract((point.x + point.y) * point.z);
}

inline float valueNoise(float3 point) {
    float3 cell = floor(point);
    float3 local = fract(point);
    local = local * local * (3.0 - 2.0 * local);
    float n000 = hash31(cell);
    float n100 = hash31(cell + float3(1.0, 0.0, 0.0));
    float n010 = hash31(cell + float3(0.0, 1.0, 0.0));
    float n110 = hash31(cell + float3(1.0, 1.0, 0.0));
    float n001 = hash31(cell + float3(0.0, 0.0, 1.0));
    float n101 = hash31(cell + float3(1.0, 0.0, 1.0));
    float n011 = hash31(cell + float3(0.0, 1.0, 1.0));
    float n111 = hash31(cell + float3(1.0));
    float lower = mix(mix(n000, n100, local.x), mix(n010, n110, local.x), local.y);
    float upper = mix(mix(n001, n101, local.x), mix(n011, n111, local.x), local.y);
    return mix(lower, upper, local.z);
}

inline float foamNoise(float3 position, float scale, float time) {
    float3 point = position * scale + float3(time * 0.08, 0.0, time * 0.05);
    return valueNoise(point) * 0.62 + valueNoise(point * 2.13 + 8.7) * 0.28
        + valueNoise(point * 4.31 - 3.1) * 0.1;
}

inline float3 sunDirection() {
    return normalize(float3(-0.42, 0.78, 0.46));
}

inline float3 sampleSky(float3 direction) {
    direction = normalize(direction);
    float horizon = pow(1.0 - abs(direction.y), 5.0);
    float skyAmount = smoothstep(-0.04, 0.05, direction.y);
    float zenithAmount = pow(saturate(direction.y), 0.38);
    float3 sky = mix(float3(0.76, 0.88, 1.0), float3(0.055, 0.22, 0.58), zenithAmount);
    sky += float3(0.36, 0.42, 0.5) * horizon;
    float3 ground = float3(0.09, 0.095, 0.12);
    float sunCore = pow(max(dot(direction, sunDirection()), 0.0), 1500.0);
    float sunGlow = pow(max(dot(direction, sunDirection()), 0.0), 24.0);
    return mix(ground, sky, skyAmount)
        + float3(1.0, 0.72, 0.38) * sunCore * 14.0
        + float3(1.0, 0.48, 0.18) * sunGlow * 0.12;
}

inline float3 shadeBox(BoxHit hit, float3 direction, float3 baseColor, float roughness) {
    float diffuse = saturate(dot(hit.normal, sunDirection())) * 0.72 + 0.28;
    float3 reflected = reflect(direction, hit.normal);
    float specular = pow(max(dot(reflected, sunDirection()), 0.0), mix(180.0, 12.0, roughness));
    float fresnel = 0.04 + 0.96 * pow(1.0 - saturate(dot(-direction, hit.normal)), 5.0);
    return baseColor * diffuse + specular * 0.75 + sampleSky(reflected) * fresnel * 0.12;
}

inline EnvironmentSample traceEnvironment(float3 origin, float3 direction, constant Uniforms &uniforms) {
    direction = normalize(direction);
    EnvironmentSample result = {sampleSky(direction), 1e30, float3(0.0), false};
    float3 platformSize = float3(uniforms.bounds.x * 1.55, 0.45, uniforms.bounds.z * 1.55);
    float3 platformCenter = float3(0.0, -uniforms.bounds.y * 0.5 - platformSize.y * 0.5, 0.0);
    BoxHit platform = intersectBox(origin, direction, platformCenter, platformSize);
    BoxHit cube = {false, 1e30, float3(0.0), float3(0.0)};
    if (uniforms.colliderEnabled != 0) {
        cube = intersectBox(origin, direction, uniforms.colliderPosition, uniforms.colliderSize);
    }
    if (cube.hit && cube.t < platform.t) {
        float edge = min(
            uniforms.colliderSize.x * 0.5 - abs(cube.position.x - uniforms.colliderPosition.x),
            uniforms.colliderSize.z * 0.5 - abs(cube.position.z - uniforms.colliderPosition.z)
        );
        float edgeLight = 1.0 - smoothstep(0.0, 0.12, edge);
        result.color = shadeBox(cube, direction, float3(0.82, 0.16, 0.085), 0.26) + edgeLight * 0.08;
        result.distance = cube.t;
        result.position = cube.position;
        result.hit = true;
        return result;
    }
    if (platform.hit) {
        float2 tilePosition = platform.position.xz * 0.72;
        int2 tile = int2(floor(tilePosition));
        bool dark = ((tile.x ^ tile.y) & 1) != 0;
        float variation = hash31(float3(float2(tile), 4.0));
        float3 base = dark ? float3(0.095, 0.12, 0.15) : float3(0.48, 0.54, 0.56);
        base *= mix(0.88, 1.12, variation);
        float2 local = fract(tilePosition);
        float grout = 1.0 - smoothstep(0.018, 0.045, min(min(local.x, local.y), min(1.0 - local.x, 1.0 - local.y)));
        base = mix(base, float3(0.035), grout * 0.8);
        float shadow = 1.0;
        if (uniforms.colliderEnabled != 0) {
            BoxHit shadowHit = intersectBox(platform.position + platform.normal * 0.002, sunDirection(), uniforms.colliderPosition, uniforms.colliderSize);
            shadow = shadowHit.hit ? 0.28 : 1.0;
        }
        result.color = shadeBox(platform, direction, base * shadow, 0.72);
        result.distance = platform.t;
        result.position = platform.position;
        result.hit = true;
        return result;
    }
    return result;
}

inline float3 sampleEnvironment(float3 origin, float3 direction, constant Uniforms &uniforms) {
    return traceEnvironment(origin, direction, uniforms).color;
}

inline float fresnelDielectric(float3 direction, float3 normal, float iorA, float iorB) {
    float eta = iorA / iorB;
    float cosineIn = saturate(-dot(direction, normal));
    float sineSquaredOut = eta * eta * (1.0 - cosineIn * cosineIn);
    if (sineSquaredOut >= 1.0) {
        return 1.0;
    }
    float cosineOut = sqrt(1.0 - sineSquaredOut);
    float perpendicular = (iorA * cosineIn - iorB * cosineOut)
        / max(iorA * cosineIn + iorB * cosineOut, 0.000001);
    float parallel = (iorB * cosineIn - iorA * cosineOut)
        / max(iorB * cosineIn + iorA * cosineOut, 0.000001);
    return 0.5 * (perpendicular * perpendicular + parallel * parallel);
}

inline float3 roughDirection(float3 direction, float3 position, float roughness) {
    float3 noise = float3(
        hash31(position * 17.13),
        hash31(position.yzx * 23.71 + 4.2),
        hash31(position.zxy * 31.37 - 8.1)
    ) * 2.0 - 1.0;
    return normalize(direction + noise * roughness);
}

inline float foamMask(SurfaceHit hit, constant Uniforms &uniforms) {
    if (uniforms.foamEnabled == 0) {
        return 0.0;
    }
    float noise = foamNoise(hit.position, uniforms.foamScale, uniforms.time);
    float particleFoam = hit.foam * mix(0.68, 1.28, noise);
    float3 boxDistance = abs(hit.position - uniforms.colliderPosition) - uniforms.colliderSize * 0.5;
    float colliderDistance = length(max(boxDistance, float3(0.0))) + min(max(boxDistance.x, max(boxDistance.y, boxDistance.z)), 0.0);
    float contactFoam = uniforms.colliderEnabled != 0
        ? exp(-abs(colliderDistance) * 4.0) * 0.32
        : 0.0;
    float floorFoam = exp(-abs(hit.position.y + uniforms.bounds.y * 0.5) * 4.0) * 0.18;
    float signal = particleFoam + contactFoam + floorFoam;
    float threshold = saturate(uniforms.foamThreshold * 0.1);
    return saturate(smoothstep(threshold, threshold + 0.18, signal)
        * uniforms.foamIntensity * 0.075);
}

inline float3 acesToneMap(float3 color) {
    float3 a = color * (2.51 * color + 0.03);
    float3 b = color * (2.43 * color + 0.59) + 0.14;
    return saturate(a / b);
}

inline float3 linearToSRGB(float3 color) {
    float3 low = color * 12.92;
    float3 high = 1.055 * pow(max(color, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
    return select(high, low, color <= float3(0.0031308));
}

inline float deviceDepth(float3 position, float4x4 viewProjection) {
    float4 clip = viewProjection * float4(position, 1.0);
    return saturate(clip.z / clip.w);
}

kernel void renderVolume(
    texture3d<float, access::sample> volume [[texture(0)]],
    texture2d<float, access::write> outputTexture [[texture(1)]],
    texture2d<float, access::write> outputDepth [[texture(2)]],
    constant Uniforms &uniforms [[buffer(0)]],
    uint2 id [[thread_position_in_grid]]
) {
    uint2 resolution = uint2(outputTexture.get_width(), outputTexture.get_height());
    if (any(id >= resolution)) {
        return;
    }
    constexpr sampler volumeSampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );
    float3 rayOrigin;
    float3 rayDirection;
    generateCameraRay(id, resolution, uniforms.invViewProjectionMatrix, rayOrigin, rayDirection);
    EnvironmentSample primaryEnvironment = traceEnvironment(rayOrigin, rayDirection, uniforms);
    float3 color = primaryEnvironment.color;
    float depth = primaryEnvironment.hit
        ? deviceDepth(primaryEnvironment.position, uniforms.viewProjectionMatrix)
        : 1.0;
    SurfaceHit entry = raymarchTransition(
        rayOrigin, rayDirection, true, uniforms.bounds, volume,
        volumeSampler, uniforms.stepSize, uniforms.isoLevel
    );

    if (entry.hit && entry.t < primaryEnvironment.distance) {
        depth = deviceDepth(entry.position, uniforms.viewProjectionMatrix);
        float3 entryNormal = normalize(entry.normal);
        if (dot(entryNormal, rayDirection) > 0.0) {
            entryNormal = -entryNormal;
        }
        float entryFresnel = fresnelDielectric(rayDirection, entryNormal, 1.0, uniforms.waterIOR);
        float3 reflectedDirection = roughDirection(
            reflect(rayDirection, entryNormal), entry.position, uniforms.surfaceRoughness
        );
        float3 reflectedLight = sampleEnvironment(entry.position + entryNormal * 0.003, reflectedDirection, uniforms);
        float3 waterDirection = refract(rayDirection, entryNormal, 1.0 / uniforms.waterIOR);
        float3 waterLight = reflectedLight;

        if (dot(waterDirection, waterDirection) > 0.5) {
            waterDirection = normalize(waterDirection);
            float3 waterOrigin = entry.position + waterDirection * max(uniforms.stepSize * 0.25, 0.003);
            SurfaceHit exitHit = raymarchTransition(
                waterOrigin, waterDirection, false, uniforms.bounds, volume,
                volumeSampler, uniforms.stepSize, uniforms.isoLevel
            );
            EnvironmentSample submergedEnvironment = traceEnvironment(waterOrigin, waterDirection, uniforms);
            float3 extinction = max(float3(uniforms.scatterR, uniforms.scatterG, uniforms.scatterB), float3(0.0));
            if (submergedEnvironment.hit && (!exitHit.hit || submergedEnvironment.distance < exitHit.t)) {
                float opticalDepth = integrateDensity(
                    waterOrigin, waterDirection, submergedEnvironment.distance, uniforms.bounds, volume,
                    volumeSampler, uniforms.stepSize, uniforms.isoLevel, uniforms.densityMultiplier
                );
                float3 transmittance = exp(-extinction * opticalDepth);
                float absorbed = 1.0 - dot(transmittance, float3(0.333333));
                waterLight = submergedEnvironment.color * transmittance
                    + float3(0.008, 0.055, 0.075) * absorbed;
            } else if (exitHit.hit) {
                float opticalDepth = integrateDensity(
                    waterOrigin, waterDirection, exitHit.t, uniforms.bounds, volume,
                    volumeSampler, uniforms.stepSize, uniforms.isoLevel, uniforms.densityMultiplier
                );
                float3 transmittance = exp(-extinction * opticalDepth);
                float3 exitNormal = normalize(exitHit.normal);
                if (dot(exitNormal, waterDirection) > 0.0) {
                    exitNormal = -exitNormal;
                }
                float exitFresnel = fresnelDielectric(waterDirection, exitNormal, uniforms.waterIOR, 1.0);
                float3 outgoingDirection = refract(waterDirection, exitNormal, uniforms.waterIOR);
                float3 transmittedEnvironment = dot(outgoingDirection, outgoingDirection) > 0.5
                    ? sampleEnvironment(exitHit.position + normalize(outgoingDirection) * 0.004, normalize(outgoingDirection), uniforms)
                    : float3(0.0);
                float3 internalDirection = normalize(reflect(waterDirection, exitNormal));
                float3 internalOrigin = exitHit.position + internalDirection * max(uniforms.stepSize * 0.25, 0.003);
                SurfaceHit secondExit = raymarchTransition(
                    internalOrigin, internalDirection, false, uniforms.bounds, volume,
                    volumeSampler, uniforms.stepSize * 1.2, uniforms.isoLevel
                );
                float3 internalLight = sampleEnvironment(exitHit.position, internalDirection, uniforms);
                if (secondExit.hit) {
                    float3 secondNormal = normalize(secondExit.normal);
                    if (dot(secondNormal, internalDirection) > 0.0) {
                        secondNormal = -secondNormal;
                    }
                    float3 secondOutgoing = refract(internalDirection, secondNormal, uniforms.waterIOR);
                    if (dot(secondOutgoing, secondOutgoing) > 0.5) {
                        internalLight = sampleEnvironment(
                            secondExit.position + normalize(secondOutgoing) * 0.004,
                            normalize(secondOutgoing),
                            uniforms
                        );
                    }
                    float secondDepth = integrateDensity(
                        internalOrigin, internalDirection, secondExit.t, uniforms.bounds, volume,
                        volumeSampler, uniforms.stepSize * 1.5, uniforms.isoLevel, uniforms.densityMultiplier
                    );
                    internalLight *= exp(-extinction * secondDepth);
                }
                float3 exitLight = mix(transmittedEnvironment, internalLight, exitFresnel);
                float absorbed = 1.0 - dot(transmittance, float3(0.333333));
                waterLight = exitLight * transmittance
                    + float3(0.008, 0.055, 0.075) * absorbed;
                float exitFoam = foamMask(exitHit, uniforms);
                waterLight = mix(waterLight, float3(0.82, 0.9, 0.92), exitFoam * 0.55);
            }
        }

        color = mix(waterLight, reflectedLight, entryFresnel);
        float foam = foamMask(entry, uniforms);
        float foamFresnel = pow(1.0 - saturate(dot(-rayDirection, entryNormal)), 3.0);
        float3 foamColor = float3(0.86, 0.93, 0.95) * (0.76 + 0.24 * saturate(dot(entryNormal, sunDirection())));
        color = mix(color, foamColor, saturate(foam * (0.72 + foamFresnel * 0.28)));
    }

    color *= max(uniforms.brightnessMultiplier, 0.0);
    color = linearToSRGB(acesToneMap(color));
    outputTexture.write(float4(color, 1.0), id);
    outputDepth.write(float4(depth), id);
}
