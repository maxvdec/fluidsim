//
//  RenderDensityMap.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct DensityVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex DensityVertexOut densityVertex(
    uint vertexID [[vertex_id]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constexpr float2 positions[] = {
        float2(-0.5, -0.5),
        float2( 0.5, -0.5),
        float2(-0.5,  0.5),
        float2( 0.5, -0.5),
        float2( 0.5,  0.5),
        float2(-0.5,  0.5)
    };

    constexpr float2 uvs[] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 1.0),
        float2(1.0, 0.0),
        float2(0.0, 0.0)
    };

    DensityVertexOut out;

    float2 siPosition = positions[vertexID] * uniforms.bounds;
    out.position = float4(siToNDC(siPosition, uniforms.ppm, uniforms.viewportSize), 0.0, 1.0);

    out.uv = uvs[vertexID];

    return out;
}

fragment float4 densityFragment(
    DensityVertexOut in [[stage_in]],
    texture2d<float> densityTexture [[texture(0)]],
    constant Uniforms& uniforms [[buffer(1)]]
) {
    constexpr sampler densitySampler(
        mag_filter::linear,
        min_filter::linear,
        address::clamp_to_edge
    );

    float density = densityTexture.sample(
        densitySampler,
        in.uv
    ).r;
    float targetDensity = max(uniforms.targetDensity, 0.0001);
    float pressure = densityToPressure(density, targetDensity, uniforms.pressureMultiplier);
    float pressureRange = max(abs(targetDensity * uniforms.pressureMultiplier), 0.0001);
    float normalizedPressure = abs(uniforms.pressureMultiplier) < 0.0001
        ? 0.0
        : clamp(pressure / pressureRange, -1.0, 1.0);
    float whiteTolerance = 0.1;
    float colorMagnitude = clamp(
        (abs(normalizedPressure) - whiteTolerance) / (1.0 - whiteTolerance),
        0.0,
        1.0
    );
    float t = copysign(colorMagnitude, normalizedPressure);

    float3 blue = float3(0.0, 0.25, 1.0);
    float3 white = float3(1.0);
    float3 red = float3(1.0, 0.1, 0.0);
    float3 color = t < 0.0 ? mix(white, blue, -t) : mix(white, red, t);

    return float4(color, 1.0);
}
