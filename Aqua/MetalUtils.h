//
//  MetalUtils.h
//  Aqua
//
//  Created by Max Van den Eynde on 29/08/2026.
//

#ifndef MetalUtils_h
#define MetalUtils_h
#include "metal_stdlib"
using namespace metal;

#define PI 3.14159265358979323846

inline float2 siToNDC(float2 position, float ppm, float2 viewportSize) {
    float2 pixelPosition = position * ppm;
    
    float2 ndc = float2(
        pixelPosition.x / (viewportSize.x * 0.5),
        pixelPosition.y / (viewportSize.y * 0.5));
    
    return ndc;
}

inline bool insideOriginRectangle(float2 pos, float2 rect, float radius) {
    float2 limit = rect * 0.5 - radius;
    if (pos.x > limit.x || pos.x < -limit.x) {
        return false;
    }
    
    if (pos.y > limit.y || pos.y < -limit.y) {
        return false;
    }
    
    return true;
}

inline float2 getBoundContactPosition(float2 pos, float2 rect, float radius) {
    float2 limit = rect * 0.5 - radius;
    float partX = pos.x;
    float partY = pos.y;
    if (pos.x > limit.x) {
        return float2(limit.x, partY);
    }
    
    if (pos.x < -limit.x) {
        return float2(-limit.x, partX);
    }
    
    if (pos.y > limit.y) {
        return float2(partX, limit.y);
    }
    
    if (pos.y < -limit.y) {
        return float2(partX, -limit.y);
    }
    
    return float2(0.0, 0.0);
}

inline float smoothingKernel(float radius, float dst) {
    float volume = PI * pow(radius, 8) / 4;
    float value = max(0.0, radius * radius - dst * dst);
    return value * value * value / volume;
}

#endif /* MetalUtils_h */
