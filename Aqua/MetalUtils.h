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

inline float4 siToClipSpace(float3 position, float4x4 viewProjectionMatrix) {
    return viewProjectionMatrix * float4(position, 1.0);
}

inline bool insideOriginBox(
    float3 pos,
    float3 box,
    float radius
) {
    float3 limit = box * 0.5 - radius;

    return all(abs(pos) <= limit);
}

inline float3 getBoundContactPosition(
    float3 pos,
    float3 box,
    float radius
) {
    float3 limit = box * 0.5 - radius;

    return clamp(pos, -limit, limit);
}

inline float smoothingKernel(float radius, float dst) {
    if (dst >= radius) {
        return 0.0;
    }

    float value = radius - dst;

    return 15.0 * value * value
         / (2.0 * PI * pow(radius, 5.0));
}

inline float smoothingKernelDerivative(
    float radius,
    float dst
) {
    if (dst >= radius) {
        return 0.0;
    }

    return -15.0 * (radius - dst)
         / (PI * pow(radius, 5.0));
}

inline float nearDensityKernel(
    float radius,
    float dst
) {
    if (dst >= radius) {
        return 0.0;
    }

    float value = radius - dst;

    return 15.0 * value * value * value
         / (PI * pow(radius, 6.0));
}

inline float nearDensityKernelDerivative(
    float radius,
    float dst
) {
    if (dst >= radius) {
        return 0.0;
    }

    float value = radius - dst;

    return -45.0 * value * value
         / (PI * pow(radius, 6.0));
}

inline float densityToPressure(float density, float targetDensity, float pressureMultiplier) {
    float densityError = density - targetDensity;
    float pressure = densityError * pressureMultiplier;
    return pressure;
}

inline float calculateSharedPressure(float densityA, float densityB, float targetDensity, float pressureMultiplier) {
    float pressureA = densityToPressure(densityA, targetDensity, pressureMultiplier);
    float pressureB = densityToPressure(densityB, targetDensity, pressureMultiplier);
    return (pressureA + pressureB) / 2;
}

inline float calculateSharedNearPressure(float nearDensityA, float nearDensityB, float nearPressureMultiplier) {
    float pressureA = nearDensityA * nearPressureMultiplier;
    float pressureB = nearDensityB * nearPressureMultiplier;
    return (pressureA + pressureB) / 2;
}

inline bool boundaryGhostIsActive(
    float3 samplePos,
    float3 bounds,
    float radius,
    int3 direction
) {
    float3 halfBounds = bounds * 0.5;

    if (
        direction.x < 0 &&
        samplePos.x + halfBounds.x >= radius
    ) {
        return false;
    }

    if (
        direction.x > 0 &&
        halfBounds.x - samplePos.x >= radius
    ) {
        return false;
    }

    if (
        direction.y < 0 &&
        samplePos.y + halfBounds.y >= radius
    ) {
        return false;
    }

    if (
        direction.y > 0 &&
        halfBounds.y - samplePos.y >= radius
    ) {
        return false;
    }

    if (
        direction.z < 0 &&
        samplePos.z + halfBounds.z >= radius
    ) {
        return false;
    }

    if (
        direction.z > 0 &&
        halfBounds.z - samplePos.z >= radius
    ) {
        return false;
    }

    return true;
}

inline float3 boundaryGhostPosition(
    float3 position,
    float3 bounds,
    int3 direction
) {
    float3 ghost = position;

    if (direction.x < 0) {
        ghost.x = -bounds.x - position.x;
    } else if (direction.x > 0) {
        ghost.x = bounds.x - position.x;
    }

    if (direction.y < 0) {
        ghost.y = -bounds.y - position.y;
    } else if (direction.y > 0) {
        ghost.y = bounds.y - position.y;
    }

    if (direction.z < 0) {
        ghost.z = -bounds.z - position.z;
    } else if (direction.z > 0) {
        ghost.z = bounds.z - position.z;
    }

    return ghost;
}

inline int3 getBoundaryGhostDirection(uint index) {

    uint encodedIndex = index;

    if (encodedIndex >= 13) {
        encodedIndex++;
    }

    int x = int(encodedIndex % 3) - 1;
    int y = int((encodedIndex / 3) % 3) - 1;
    int z = int(encodedIndex / 9) - 1;

    return int3(x, y, z);
}

#define HASHK1 15823u
#define HASHK2 9737333u
#define HASHK3 440817757u

inline int3 getSpatialNeighborOffset(uint index) {
    int x = int(index % 3) - 1;
    int y = int((index / 3) % 3) - 1;
    int z = int(index / 9) - 1;

    return int3(x, y, z);
}

inline int3 getCell3D(float3 pos, float radius) {
    return int3(floor(pos / radius));
}

inline uint hashCell3D(int3 cell) {
    uint x = uint(cell.x) * HASHK1;
    uint y = uint(cell.y) * HASHK2;
    uint z = uint(cell.z) * HASHK3;

    return x ^ y ^ z;
}

inline uint keyFromHash(
    uint hash,
    uint tableSize
) {
    return hash % tableSize;
}

#endif /* MetalUtils_h */
