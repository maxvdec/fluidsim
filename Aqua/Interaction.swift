//
//  Interaction.swift
//  Aqua
//
//  Created by Max Van den Eynde on 30/08/2026.
//

import AppKit
import Metal
import MetalKit
import SwiftUI

enum MouseMode: UInt32 {
    case none = 0
    case repel = 1
    case grab = 2
}

struct MouseInteractionState {
    var isActive: Bool = false
    var mode: MouseMode = .none
    
    var currentSimPosition: SIMD3<Float> = .zero
    var previousSimPosition: SIMD3<Float> = .zero
    var simVelocity: SIMD3<Float> = .zero
    var interactionPlanePoint: SIMD3<Float> = .zero
    var interactionPlaneNormal: SIMD3<Float> = SIMD3<Float>(0, 0, -1)

    var radius: Float = 0.4
    var strength: Float = 20.0
}

final class SimulationMTKView: MTKView {
    var onLeftMouseDown: ((CGPoint, MouseMode) -> Void)?
    var onLeftMouseDragged: ((CGPoint) -> Void)?
    var onLeftMouseUp: (() -> Void)?

    var onCameraRotate: ((_ deltaX: Float, _ deltaY: Float) -> Void)?
    var onCameraZoom: ((_ delta: Float) -> Void)?

    var onCameraMoveChanged: ((
        _ direction: CameraMoveDirection,
        _ active: Bool
    ) -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        let point = convert(
            event.locationInWindow,
            from: nil
        )

        let mode: MouseMode = event.modifierFlags.contains(.shift)
            ? .repel
            : .grab

        onLeftMouseDown?(point, mode)
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(
            event.locationInWindow,
            from: nil
        )

        onLeftMouseDragged?(point)
    }

    override func mouseUp(with event: NSEvent) {
        onLeftMouseUp?()
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func rightMouseDragged(with event: NSEvent) {
        onCameraRotate?(
            Float(event.deltaX),
            Float(event.deltaY)
        )
    }

    override func rightMouseUp(with event: NSEvent) {
    }

    override func scrollWheel(with event: NSEvent) {
        onCameraZoom?(
            Float(event.scrollingDeltaY)
        )
    }

    override func keyDown(with event: NSEvent) {
        guard !event.isARepeat else {
            return
        }

        guard let direction = cameraDirection(
            for: event.keyCode
        ) else {
            super.keyDown(with: event)
            return
        }

        onCameraMoveChanged?(
            direction,
            true
        )
    }

    override func keyUp(with event: NSEvent) {
        guard let direction = cameraDirection(
            for: event.keyCode
        ) else {
            super.keyUp(with: event)
            return
        }

        onCameraMoveChanged?(
            direction,
            false
        )
    }

    private func cameraDirection(
        for keyCode: UInt16
    ) -> CameraMoveDirection? {
        switch keyCode {
        case 126:
            return .forward     // up

        case 125:
            return .backward    // down

        case 123:
            return .left        // left

        case 124:
            return .right       // right

        default:
            return nil
        }
    }
}
