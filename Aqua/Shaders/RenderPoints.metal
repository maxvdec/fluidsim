//
//  RenderPoints.metal
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#include <metal_stdlib>
#include "../BridgingHeader.h"
#include "../MetalUtils.h"
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    
    float speed;
    float3 worldPosition;
};

vertex VertexOut particleVertex(uint vertexID [[vertex_id]], device const Particle *particles [[buffer(0)]],
                                constant Uniforms &uniforms [[buffer(1)]]) {
    Particle particle = particles[vertexID];
    
    VertexOut out;
        
    float4 worldPosition = float4(particle.position, 1.0);
    
    float4 viewPosition = uniforms.viewMatrix * worldPosition;
    out.position = uniforms.projectionMatrix * viewPosition;
    
    float projectionScale = uniforms.projectionMatrix[1][1];
    
    float distanceFromCamera = max(-viewPosition.z, 0.001);
    
    float radiusPixels = uniforms.particleSize * projectionScale / distanceFromCamera * uniforms.viewportSize.y * 0.5;
    out.pointSize = radiusPixels * 2;
    
    out.speed = length(particle.velocity);
    out.worldPosition = particle.position;
    
    return out;
}

fragment float4 particleFragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    float2 xy = pointCoord * 2.0 - 1.0;

    float r2 = dot(xy, xy);

    if (r2 > 1.0) {
        discard_fragment();
    }

    float z = sqrt(1.0 - r2);

    float3 normal = normalize(float3(
        xy.x,
        -xy.y,
        z
    ));

    float maxSpeed = 5.0;

    float t = clamp(
        in.speed / maxSpeed,
        0.0,
        1.0
    );

    float3 blue  = float3(0.0, 0.0, 1.0);
    float3 green = float3(0.0, 1.0, 0.0);
    float3 red   = float3(1.0, 0.0, 0.0);

    float3 baseColor;

    if (t < 0.5) {
        baseColor = mix(
            blue,
            green,
            t * 2.0
        );
    } else {
        baseColor = mix(
            green,
            red,
            (t - 0.5) * 2.0
        );
    }

    float3 lightDirection = normalize(
        float3(-0.4, 0.7, 1.0)
    );

    float diffuse = max(
        dot(normal, lightDirection),
        0.0
    );

    float ambient = 0.25;

    float lighting =
        ambient +
        diffuse * 0.75;

    float3 color =
        baseColor * lighting;

    float3 viewDirection =
        float3(0.0, 0.0, 1.0);

    float3 halfwayDirection =
        normalize(
            lightDirection +
            viewDirection
        );

    float specular =
        pow(
            max(
                dot(normal, halfwayDirection),
                0.0
            ),
            32.0
        );

    color += specular * 0.35;

    float radius = sqrt(r2);
    float aa = fwidth(radius);

    float alpha =
        1.0 -
        smoothstep(
            1.0 - aa,
            1.0,
            radius
        );

    return float4(
        color,
        alpha
    );
}
