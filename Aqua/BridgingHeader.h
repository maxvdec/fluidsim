//
//  BridgingHeader.h
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#ifndef BridgingHeader_h
#define BridgingHeader_h

#include <simd/simd.h>

struct Particle {
    simd_float3 position;
    simd_float3 predictedPosition;
    simd_float3 velocity;
    float density;
    float nearDensity;
};

struct FoamParticle {
    simd_float3 position;
    simd_float3 velocity;
    float lifetime;
    float scale;
    float kind;
};

struct Uniforms {
    float dt;
    float time;
    
    simd_float2 viewportSize;
    simd_float3 bounds;
    float ppm;
    
    float gravity;
    float particleSize;
    
    unsigned int particleCount;
    
    float smoothingRadius;
    
    float targetDensity;
    float pressureMultiplier;
    float viscosityStrength;
    float nearPressureMultiplier;
    float particleMass;

    simd_float3 mousePosition;
    simd_float3 mouseVelocity;
    float mouseRadius;
    float mouseStrength;
    unsigned int mouseMode; // 0 (none), 1 (repel), 2 (grab)
    
    float stepSize;
    float lightStepSize;
    float densityMultiplier;
    float isoLevel;
    
    float scatterR;
    float scatterG;
    float scatterB;
    float brightnessMultiplier;

    float waterIOR;
    float surfaceRoughness;
    unsigned int foamEnabled;
    float foamDeltaTime;
    float foamSpawnRate;
    float foamVelocityMin;
    float foamVelocityMax;
    float foamKineticMin;
    float foamKineticMax;
    float foamScale;
    unsigned int foamParticleCapacity;
    unsigned int sprayEnabled;
    unsigned int sprayMaxNeighbours;
    unsigned int bubbleMinNeighbours;
    float bubbleBuoyancy;
    float bubbleScale;

    simd_uint3 densityResolution;

    unsigned int colliderEnabled;
    unsigned int colliderCollisions;
    unsigned int colliderFloating;
    simd_float3 colliderPosition;
    simd_float3 colliderVelocity;
    simd_float3 colliderSize;
    
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float4x4 viewProjectionMatrix;
    simd_float4x4 invViewProjectionMatrix;
};

#endif /* BridgingHeader_h */
