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
    simd_float2 velocity;
    float density;
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
};


#endif /* BridgingHeader_h */
