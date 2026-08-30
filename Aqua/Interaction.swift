//
//  Interaction.swift
//  Aqua
//
//  Created by Max Van den Eynde on 30/08/2026.
//

import Metal
import SwiftUI
import MetalKit

enum MouseMode: UInt32 {
    case none = 0
    case repel = 1
    case grab = 2
}

struct MouseInteractionState {
    var isActive: Bool = false
    var mode: MouseMode = .none
    
    var currentSimPosition: SIMD2<Float> = .zero
    var previousSimPosition: SIMD2<Float> = .zero
    var simVelocity: SIMD2<Float> = .zero
    
    var radius: Float = 0.4
    var strength: Float = 20.0
}


final class SimulationMTKView: MTKView {
    var onLeftMouseDown: ((CGPoint) -> Void)?
    var onLeftMouseDragged: ((CGPoint) -> Void)?
    var onLeftMouseUp: (() -> Void)?
    
    var onRightMouseDown: ((CGPoint) -> Void)?
    var onRightMouseDragged: ((CGPoint) -> Void)?
    var onRightMouseUp: (() -> Void)?
    
    override var acceptsFirstResponder: Bool { true }
    
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onLeftMouseDown?(point)
    }
    
    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onLeftMouseDragged?(point)
    }
    
    override func mouseUp(with event: NSEvent) {
        onLeftMouseUp?()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightMouseDown?(point)
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        onRightMouseDragged?(point)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        onRightMouseUp?()
    }
}
