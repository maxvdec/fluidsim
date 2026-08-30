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
    return clamp(pos, -limit, limit);
}

inline float smoothingKernel(float radius, float dst) {
    if (dst >= radius) return 0;
    float volume = (PI * pow(radius, 4)) / 6;
    return (radius - dst) * (radius - dst) / volume;
}

inline float smoothingKernelDerivative(float radius, float dst) {
    if (dst >= radius) return 0;
    
    float scale = 12 / (pow(radius, 4) * PI);
    return (dst - radius) * scale;
}

inline float nearDensityKernel(float radius, float dst) {
    if (dst >= radius) return 0;
    float volume = PI * pow(radius, 5) / 10;
    float value = radius - dst;
    return value * value * value / volume;
}

inline float nearDensityKernelDerivative(float radius, float dst) {
    if (dst >= radius) return 0;
    float value = radius - dst;
    return -30 * value * value / (PI * pow(radius, 5));
}

inline float densityToPressure(float density, float targetDensity, float pressureMultiplier) {
    float densityError = density - targetDensity;
    float pressure = densityError * pressureMultiplier;
    return pressure;
}

inline float calculateSharedPressure(float densityA, float densityB, float targetDensity, float pressureMultiplier) {
    float pressureA = max(0.0, densityToPressure(densityA, targetDensity, pressureMultiplier));
    float pressureB = max(0.0, densityToPressure(densityB, targetDensity, pressureMultiplier));
    return (pressureA + pressureB) / 2;
}

inline float calculateSharedNearPressure(float nearDensityA, float nearDensityB, float nearPressureMultiplier) {
    float pressureA = nearDensityA * nearPressureMultiplier;
    float pressureB = nearDensityB * nearPressureMultiplier;
    return (pressureA + pressureB) / 2;
}

#define HASHK1 15823
#define HASHK2 9737333

inline int2 getSpatialNeighborOffset(uint index) {
    constexpr int2 offsets[9] = {
        int2(-1, 1), int2(0, 1), int2(1, 1),
        int2(-1, 0), int2(0, 0), int2(1, 0),
        int2(-1, -1), int2(0, -1), int2(1, -1)
    };
    return offsets[index];
}

inline int2 getCell2D(float2 pos, float radius) {
    return (int2)floor(pos / radius);
}

inline uint hashCell2D(int2 cell) {
    uint a = uint(cell.x) * HASHK1;
    uint b = uint(cell.y) * HASHK2;
    return a + b;
}

inline uint keyFromHash(uint hash, uint tableSize) {
    return hash % tableSize;
}

#endif /* MetalUtils_h */
