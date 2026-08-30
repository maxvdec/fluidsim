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
    simd_float2 position;
    simd_float2 predictedPosition;
    simd_float2 velocity;
    float density;
    float nearDensity;
};

struct Uniforms {
    float dt;
    float time;
    
    simd_float2 viewportSize;
    simd_float2 bounds;
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
};

struct SpatialLookupEntry {
    unsigned int particleIndex;
    unsigned int cellKey;
};


#endif /* BridgingHeader_h */
