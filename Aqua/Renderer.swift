//
//  Renderer.swift
//  Aqua
//
//  Created by Max Van den Eynde on 28/08/2026.
//

import Foundation
import Metal
import MetalKit
import SwiftUI
import Observation
import Combine
import QuartzCore

@Observable
final class SimulationSettings {
    var paused = true
    
    var gravity: Float = 4.00 // m/s^2
    var particleRadius: Float = 0.3 // m
    
    var ppm: Float = 20
    
    var timeScale: Float = 1.0
    
    var boundsX: Float = 2.0 // m
    var boundsY: Float = 1.0 // m
}

struct MetalView: NSViewRepresentable {
    let renderer: Renderer
    
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        
        view.delegate = renderer
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.0, green: 0.0, blue: 0.0, alpha: 1.0)
        
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        
        return view
    }
    
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

func createParticlesInGrid(n: Int, spacing: Float = 0.1) -> [Particle] {
    let columns = Int(ceil(sqrt(Double(n))))
    let rows = Int(ceil(Double(n) / Double(columns)))
    
    var positions: [SIMD2<Float>] = []
    positions.reserveCapacity(n)
    
    for i in 0 ..< n {
        let xIndex = i % columns
        let yIndex = i / columns
        
        let x = (Float(xIndex) - Float(columns - 1) / 2.0) * spacing
        let y = (Float(yIndex) - Float(rows - 1) / 2.0) * spacing
        
        positions.append(SIMD2<Float>(x, y))
    }
    
    return positions.map { pos in
        Particle(position: pos, velocity: SIMD2<Float>(0.0, 0.0))
    }
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let settings: SimulationSettings
    
    let device: MTLDevice
    
    private let commandQueue: MTLCommandQueue
    
    private let simulationPipeline: MTLComputePipelineState
    private let renderPipeline: MTLRenderPipelineState
    
    var particles: MTLSyncBuffer<Particle>
    
    private var uniforms: Uniforms = Uniforms()
    
    private var lastFrameTime: CFTimeInterval?
    
    init(settings: SimulationSettings) {
        self.settings = settings
        
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not available")
        }
        
        self.device = device
        
        guard let queue = self.device.makeCommandQueue() else {
            fatalError("Could not allocate a command queue")
        }
        
        self.commandQueue = queue
        
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load Metal Library")
        }
        
        let simulationFunction = library.makeFunction(name: "simulateParticles")!
        
        self.simulationPipeline = try! device.makeComputePipelineState(function: simulationFunction)
        
        let vertexFunction = library.makeFunction(name: "particleVertex")!
        let fragmentFunction = library.makeFunction(name: "particleFragment")!
        
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        self.renderPipeline = try! device.makeRenderPipelineState(descriptor: descriptor)
        self.particles = MTLSyncBuffer(device: device, values: createParticlesInGrid(n: 1))
        
        super.init()
    }
    
    private func updateUniforms(view: MTKView, dt: Float) {
        uniforms.dt = dt * settings.timeScale
        
        uniforms.gravity = settings.gravity
        uniforms.particleSize = settings.particleRadius
        
        uniforms.viewportSize = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        
        uniforms.ppm = settings.ppm
    }
    
    private func encodeSimulation(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        encoder.setComputePipelineState(simulationPipeline)
        
        particles.setAtEncoder(encoder, index: 0)
        
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        let particleCount = particles.count
        
        let threadsPerGroup = MTLSize(width: simulationPipeline.threadExecutionWidth, height: 1, depth: 1)
        
        let groups = MTLSize(
            width: (
                particleCount +
                threadsPerGroup.width - 1
            ) / threadsPerGroup.width,
            height: 1,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        
        encoder.endEncoding()
    }
    
    private func encodeParticlePointRendering(_ commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        encoder.setRenderPipelineState(renderPipeline)
        
        particles.setAtVertexBuffer(encoder, index: 0)
        
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particles.count)
        
        encoder.endEncoding()
    }
    
    private func calculateDeltaTime() -> Float {
        let now = CACurrentMediaTime()
        
        guard let lastFrameTime else {
            self.lastFrameTime = now
            return 0
        }
        
        let dt = now - lastFrameTime
        self.lastFrameTime = now
        return Float(dt)
    }
    
    func draw(in view: MTKView) {
        defer {
            particles.syncBufferToList()
        }
        
        let dt = calculateDeltaTime()
        
        updateUniforms(view: view, dt: dt)
            
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            return
        }
        
        if !settings.paused {
            encodeSimulation(commandBuffer)
        }
        
        encodeParticlePointRendering(commandBuffer, descriptor: descriptor)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
