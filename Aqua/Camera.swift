//
//  Camera.swift
//  Aqua
//
//  Created by Max Van den Eynde on 30/08/2026.
//

import Foundation
import simd

enum CameraMoveDirection: Hashable {
    case forward
    case backward
    case left
    case right
}

struct Camera {
    var target = SIMD3<Float>(0, 0, 0)
    var distance: Float = 30.0
    var moveSpeed: Float = 8.0


    var yaw: Float = 0.0
    var pitch: Float = 0.0
    var fovY: Float = 60.0 * .pi / 180.0
    var nearPlane: Float = 0.05
    var farPlane: Float = 2000.0

    var orbitSensitivity: Float = 0.006
    var zoomSensitivity: Float = 0.02

    var minDistance: Float = 0.15
    var maxDistance: Float = 500.0

    private var moving: Set<CameraMoveDirection> = []

    static let worldUp = SIMD3<Float>(0, 1, 0)
    
    init(
        target: SIMD3<Float> = .zero,
        distance: Float = 30.0
    ) {
        self.target = target
        self.distance = distance
    }

    var position: SIMD3<Float> {
        let cosPitch = cos(pitch)

        let offset = SIMD3<Float>(
            sin(yaw) * cosPitch,
            sin(pitch),
            cos(yaw) * cosPitch
        ) * distance

        return target + offset
    }

    var forward: SIMD3<Float> {
        simd_normalize(target - position)
    }

    var right: SIMD3<Float> {
        simd_normalize(
            simd_cross(forward, Self.worldUp)
        )
    }

    mutating func setMoving(
        _ direction: CameraMoveDirection,
        active: Bool
    ) {
        if active {
            moving.insert(direction)
        } else {
            moving.remove(direction)
        }
    }

    mutating func orbit(
        deltaX: Float,
        deltaY: Float
    ) {
        yaw -= deltaX * orbitSensitivity
        pitch += deltaY * orbitSensitivity

        let maxPitch = Float.pi * 0.49

        pitch = max(
            -maxPitch,
            min(maxPitch, pitch)
        )
    }

    mutating func zoom(delta: Float) {
        distance *= exp(-delta * zoomSensitivity)

        distance = max(
            minDistance,
            min(maxDistance, distance)
        )
    }

    mutating func update(dt: Float) {
        guard dt > 0 else {
            return
        }

        var groundForward = SIMD3<Float>(
            forward.x,
            0,
            forward.z
        )

        if simd_length_squared(groundForward) > 0.000001 {
            groundForward = simd_normalize(groundForward)
        }

        let groundRight = simd_normalize(
            simd_cross(
                groundForward,
                Self.worldUp
            )
        )

        var movement = SIMD3<Float>.zero

        if moving.contains(.forward) {
            movement += groundForward
        }

        if moving.contains(.backward) {
            movement -= groundForward
        }

        if moving.contains(.right) {
            movement += groundRight
        }

        if moving.contains(.left) {
            movement -= groundRight
        }

        if simd_length_squared(movement) > 0.000001 {
            movement = simd_normalize(movement)

            target += movement * moveSpeed * dt
        }
    }

    func viewMatrix() -> simd_float4x4 {
        let eye = position

        let zAxis = simd_normalize(eye - target)

        let xAxis = simd_normalize(
            simd_cross(Self.worldUp, zAxis)
        )

        let yAxis = simd_cross(
            zAxis,
            xAxis
        )

        return simd_float4x4(
            columns: (
                SIMD4<Float>(
                    xAxis.x,
                    yAxis.x,
                    zAxis.x,
                    0
                ),
                SIMD4<Float>(
                    xAxis.y,
                    yAxis.y,
                    zAxis.y,
                    0
                ),
                SIMD4<Float>(
                    xAxis.z,
                    yAxis.z,
                    zAxis.z,
                    0
                ),
                SIMD4<Float>(
                    -simd_dot(xAxis, eye),
                    -simd_dot(yAxis, eye),
                    -simd_dot(zAxis, eye),
                    1
                )
            )
        )
    }

    func projectionMatrix(
        aspectRatio: Float
    ) -> simd_float4x4 {
        let yScale =
            1.0 / tan(fovY * 0.5)

        let xScale =
            yScale / aspectRatio

        let zScale =
            farPlane / (nearPlane - farPlane)

        return simd_float4x4(
            columns: (
                SIMD4<Float>(
                    xScale, 0, 0, 0
                ),
                SIMD4<Float>(
                    0, yScale, 0, 0
                ),
                SIMD4<Float>(
                    0, 0, zScale, -1
                ),
                SIMD4<Float>(
                    0,
                    0,
                    nearPlane * zScale,
                    0
                )
            )
        )
    }
}
