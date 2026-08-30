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

    unsigned int spatialEntryCount;
    
    simd_float3 mousePosition;
    simd_float3 mouseVelocity;
    float mouseRadius;
    float mouseStrength;
    unsigned int mouseMode; // 0 (none), 1 (repel), 2 (grab)
    
    float stepSize;
    float densityMultiplier;
    float isoLevel;
    
    float scatterR;
    float scatterG;
    float scatterB;
    float brightnessMultiplier;
    
    simd_float4x4 viewMatrix;
    simd_float4x4 projectionMatrix;
    simd_float4x4 viewProjectionMatrix;
    simd_float4x4 invViewProjectionMatrix;
};

struct SpatialLookupEntry {
    unsigned int particleIndex;
    unsigned int cellKey;
};


#endif /* BridgingHeader_h */
