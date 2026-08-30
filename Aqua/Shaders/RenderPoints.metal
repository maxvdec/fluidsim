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
    float3 viewCenter;
    float renderRadius;
};

struct FragmentOut {
    float4 color [[color(0)]];
    float depth [[depth(any)]];
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
    
    float pixelScale = projectionScale / distanceFromCamera * uniforms.viewportSize.y * 0.5;
    float radiusPixels = clamp(uniforms.particleSize * pixelScale, 2.0, 64.0);
    out.pointSize = radiusPixels * 2.0;
    
    out.speed = length(particle.velocity);
    out.worldPosition = particle.position;
    out.viewCenter = viewPosition.xyz;
    out.renderRadius = radiusPixels / max(pixelScale, 0.0001);
    
    return out;
}

fragment FragmentOut particleFragment(
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

    float maxSpeed = 6.0;

    float t = clamp(
        in.speed / maxSpeed,
        0.0,
        1.0
    );

    float3 blue = float3(0.015, 0.10, 0.85);
    float3 cyan = float3(0.0, 0.78, 0.88);
    float3 yellow = float3(1.0, 0.78, 0.02);
    float3 orange = float3(1.0, 0.18, 0.0);

    float3 baseColor;

    bool isSelected = uniforms.mouseMode != 0
        && distance(in.worldPosition, uniforms.mousePosition) < uniforms.mouseRadius;

    if (isSelected) {
        baseColor = float3(1.0, 0.25, 1.0);
    } else if (t < 0.4) {
        baseColor = mix(
            blue,
            cyan,
            t / 0.4
        );
    } else if (t < 0.8) {
        baseColor = mix(
            cyan,
            yellow,
            (t - 0.4) / 0.4
        );
    } else {
        baseColor = mix(
            yellow,
            orange,
            (t - 0.8) / 0.2
        );
    }

    float3 lightDirection = normalize(
        float3(-0.35, 0.8, 0.55)
    );

    float diffuse = max(
        dot(normal, lightDirection),
        0.0
    );

    float ambient = 0.22;

    float lighting =
        ambient +
        diffuse * 0.78;

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
            48.0
        );

    float rim = pow(
        1.0 - max(normal.z, 0.0),
        3.0
    );

    color += specular * 0.65;
    color += baseColor * rim * 0.2;

    float radius = sqrt(r2);
    float aa = fwidth(radius);

    float alpha =
        1.0 -
        smoothstep(
            1.0 - aa,
            1.0,
            radius
        );

    if (alpha < 0.02) {
        discard_fragment();
    }

    float3 surfaceViewPosition = in.viewCenter + normal * in.renderRadius;
    float4 surfaceClipPosition = uniforms.projectionMatrix * float4(surfaceViewPosition, 1.0);

    FragmentOut out;
    out.color = float4(color, alpha);
    out.depth = clamp(
        surfaceClipPosition.z / surfaceClipPosition.w,
        0.0,
        1.0
    );
    return out;
}

struct FoamVertexOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 viewCenter;
    float renderRadius;
    float lifetime;
    float scale;
};

vertex FoamVertexOut foamVertex(
    uint vertexID [[vertex_id]],
    device const FoamParticle *particles [[buffer(0)]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    FoamParticle particle = particles[vertexID];
    FoamVertexOut out;
    if (particle.lifetime <= 0.0) {
        out.position = float4(2.0, 2.0, 2.0, 1.0);
        out.pointSize = 0.0;
        out.viewCenter = float3(0.0);
        out.renderRadius = 0.0;
        out.lifetime = 0.0;
        out.scale = 0.0;
        return out;
    }
    float4 viewPosition = uniforms.viewMatrix * float4(particle.position, 1.0);
    out.position = uniforms.projectionMatrix * viewPosition;
    float radius = uniforms.foamScale * particle.scale * saturate(particle.lifetime / 1.5);
    float pixelScale = uniforms.projectionMatrix[1][1]
        / max(-viewPosition.z, 0.001) * uniforms.viewportSize.y * 0.5;
    out.pointSize = clamp(radius * pixelScale * 2.0, 1.5, 36.0);
    out.viewCenter = viewPosition.xyz;
    out.renderRadius = radius;
    out.lifetime = particle.lifetime;
    out.scale = particle.scale;
    return out;
}

fragment FragmentOut foamFragment(
    FoamVertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]],
    constant Uniforms &uniforms [[buffer(1)]]
) {
    float2 xy = pointCoord * 2.0 - 1.0;
    float radiusSquared = dot(xy, xy);
    if (radiusSquared > 1.0 || in.lifetime <= 0.0) {
        discard_fragment();
    }
    float z = sqrt(1.0 - radiusSquared);
    float3 normal = normalize(float3(xy.x, -xy.y, z));
    float3 lightDirection = normalize(float3(-0.42, 0.78, 0.46));
    float diffuse = saturate(dot(normal, lightDirection));
    float rim = pow(1.0 - z, 2.0);
    float specular = pow(max(dot(normalize(lightDirection + float3(0.0, 0.0, 1.0)), normal), 0.0), 48.0);
    float3 color = mix(float3(0.62, 0.79, 0.84), float3(0.96, 0.985, 1.0), 0.5 + diffuse * 0.5);
    color += specular * 0.65 + rim * float3(0.18, 0.3, 0.34);
    float edgeWidth = max(fwidth(sqrt(radiusSquared)), 0.002);
    float alpha = 1.0 - smoothstep(1.0 - edgeWidth, 1.0, sqrt(radiusSquared));
    float3 surfaceViewPosition = in.viewCenter + normal * in.renderRadius;
    float4 surfaceClip = uniforms.projectionMatrix * float4(surfaceViewPosition, 1.0);
    FragmentOut out;
    out.color = float4(color, alpha);
    out.depth = clamp(surfaceClip.z / surfaceClip.w, 0.0, 1.0);
    return out;
}
