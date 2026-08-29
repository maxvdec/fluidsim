//
//  Renderer.swift
//  Aqua
//
//  Created by Max Van den Eynde on 28/08/2026.
//

import Combine
import Foundation
import Metal
import MetalKit
import Observation
import QuartzCore
import SwiftUI

@Observable
final class SimulationSettings {
    var paused = true
    
    var gravity: Float = 9.81 // m/s^2
    var particleRadius: Float = 0.025 // m
    
    var ppm: Float = 20
    
    var timeScale: Float = 1.0
    
    var boundsX: Float = 5.0 // m
    var boundsY: Float = 3.0 // m
    var boundaryViewportPadding: Float = 10.0
    
    var particles: Int = 600
    var particleSpacing: Float = 0.1
    var randomScattering: Bool = false
    
    var smoothingRadius: Float = 0.2 // m
    
    var targetDensity: Float = 100.0
    var pressureMultiplier: Float = 10
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
        Particle(position: pos, velocity: SIMD2<Float>(0.0, 0.0), density: 0.0)
    }
}

func scatterParticlesRandomly(n: Int, settings: SimulationSettings) -> [Particle] {
    let boundsHalf = ((settings.boundsX / 2) - settings.particleRadius, (settings.boundsY / 2) - settings.particleRadius)
    
    var positions: [SIMD2<Float>] = []
    positions.reserveCapacity(n)
    
    for _ in 0 ..< n {
        let randX = Float.random(in: -boundsHalf.0...boundsHalf.0)
        let randY = Float.random(in: -boundsHalf.1...boundsHalf.1)
        
        positions.append(SIMD2<Float>(randX, randY))
    }
    
    return positions.map { pos in
        Particle(position: pos, velocity: SIMD2<Float>(0.0, 0.0), density: 0.0)
    }
}

func createParticles(n: Int, wantsRandom: Bool, settings: SimulationSettings, spacing: Float = 0.1) -> [Particle] {
    if wantsRandom {
        return scatterParticlesRandomly(n: n, settings: settings)
    } else {
        return createParticlesInGrid(n: n, spacing: spacing)
    }
}

func createRenderPipeline(vertex: String, fragment: String, device: MTLDevice) throws -> MTLRenderPipelineState {
    guard let library = device.makeDefaultLibrary() else {
        fatalError("Could not load Metal Library")
    }
    
    let vertexFunction = library.makeFunction(name: vertex)!
    let fragmentFunction = library.makeFunction(name: fragment)!
    
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = vertexFunction
    descriptor.fragmentFunction = fragmentFunction
    descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
    
    return try device.makeRenderPipelineState(descriptor: descriptor)
}

func createDensityTexture(device: MTLDevice, width: Int, height: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float,
        width: max(1, width),
        height: max(1, height),
        mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    return device.makeTexture(descriptor: descriptor)!
}

func createBounds(settings: SimulationSettings) -> [SIMD2<Float>] {
    let w = settings.boundsX
    let h = settings.boundsY
    
    let vertices: [(Float, Float)] = [
        (-w / 2, -h / 2),
        (w / 2, -h / 2),
        (w / 2, -h / 2),
        (w / 2, h / 2),
        (w / 2, h / 2),
        (-w / 2, h / 2),
        (-w / 2, h / 2),
        (-w / 2, -h / 2)
    ]
    
    let verticesSIMD = vertices.map { t in SIMD2(t.0, t.1) }
    
    return verticesSIMD
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let settings: SimulationSettings
    
    let device: MTLDevice
    
    private let commandQueue: MTLCommandQueue
    
    private let densityCalculationPipeline: MTLComputePipelineState
    private let simulationPipeline: MTLComputePipelineState
    private let densityRenderPipeline: MTLComputePipelineState
    
    private let renderPipeline: MTLRenderPipelineState
    private let boundsPipeline: MTLRenderPipelineState
    private let densityDisplayPipeline: MTLRenderPipelineState
    
    private var densityTexture: MTLTexture
    
    var particles: MTLSyncBuffer<Particle>
    private var nextParticles: MTLSyncBuffer<Particle>
    var bounds: MTLSyncBuffer<SIMD2<Float>>
    
    private var uniforms: Uniforms = .init()
    
    private var lastFrameTime: CFTimeInterval?
    
    private var lastRandomScattering: Bool = false
    
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
        
        let densityCalculationFunction = library.makeFunction(name: "calculateDensities")!
        self.densityCalculationPipeline = try! device.makeComputePipelineState(function: densityCalculationFunction)
        
        let simulationFunction = library.makeFunction(name: "simulateParticles")!
        self.simulationPipeline = try! device.makeComputePipelineState(function: simulationFunction)
        
        let densityRenderFunction = library.makeFunction(name: "renderDensity")!
        self.densityRenderPipeline = try! device.makeComputePipelineState(function: densityRenderFunction)
        
        self.renderPipeline = try! createRenderPipeline(vertex: "particleVertex", fragment: "particleFragment", device: device)
        self.boundsPipeline = try! createRenderPipeline(vertex: "boundsVertex", fragment: "boundsFragment", device: device)
        self.densityDisplayPipeline = try! createRenderPipeline(
            vertex: "densityVertex",
            fragment: "densityFragment",
            device: device
        )
        let initialParticles = createParticles(n: max(1, settings.particles), wantsRandom: settings.randomScattering, settings: settings, spacing: settings.particleSpacing)
        self.particles = MTLSyncBuffer(device: device, values: initialParticles)
        self.nextParticles = MTLSyncBuffer(device: device, values: initialParticles)
        self.bounds = MTLSyncBuffer(device: device, values: createBounds(settings: settings))
        
        self.lastRandomScattering = settings.randomScattering
        
        self.densityTexture = createDensityTexture(device: device, width: 1, height: 1)
        
        super.init()
    }
    
    private func updateUniforms(view: MTKView, dt: Float) {
        uniforms.dt = min(dt, 1.0 / 60.0) * settings.timeScale
        
        uniforms.gravity = settings.gravity
        uniforms.particleSize = settings.particleRadius
        
        uniforms.viewportSize = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        
        let boundaryViewportScale = max(0.01, 1.0 - settings.boundaryViewportPadding / 50.0)
        uniforms.ppm = min(uniforms.viewportSize.x / settings.boundsX, uniforms.viewportSize.y / settings.boundsY) * boundaryViewportScale
        updateDensityTextureSize()
        uniforms.bounds = SIMD2<Float>(settings.boundsX, settings.boundsY)
        uniforms.smoothingRadius = settings.smoothingRadius
        
        uniforms.targetDensity = settings.targetDensity
        uniforms.pressureMultiplier = settings.pressureMultiplier
        
        if settings.paused {
            bounds.assign(new: createBounds(settings: settings))
            let requestedParticleCount = max(1, settings.particles)
            let shouldRegenerateParticles = !settings.randomScattering
                || lastRandomScattering != settings.randomScattering
                || particles.count != requestedParticleCount

            if shouldRegenerateParticles {
                let newParticles = createParticles(n: requestedParticleCount, wantsRandom: settings.randomScattering, settings: settings, spacing: settings.particleSpacing)
                particles.assign(new: newParticles)
                nextParticles.assign(new: newParticles)
            }

            lastRandomScattering = settings.randomScattering
        }

        uniforms.particleCount = UInt32(particles.count)
    }

    private func updateDensityTextureSize() {
        let densityScale: Float = 0.75
        let width = max(1, Int((settings.boundsX * uniforms.ppm * densityScale).rounded(.up)))
        let height = max(1, Int((settings.boundsY * uniforms.ppm * densityScale).rounded(.up)))

        guard densityTexture.width != width || densityTexture.height != height else {
            return
        }

        densityTexture = createDensityTexture(
            device: device,
            width: width,
            height: height
        )
    }
    
    private func encodeDensityCalculation(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        encoder.setComputePipelineState(densityCalculationPipeline)
        
        particles.setAtEncoder(encoder, index: 0)
        nextParticles.setAtEncoder(encoder, index: 1)
        
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        
        let particleCount = particles.count
        
        let threadsPerGroup = MTLSize(width: densityCalculationPipeline.threadExecutionWidth, height: 1, depth: 1)
        
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
    
    private func encodeSimulation(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        encoder.setComputePipelineState(simulationPipeline)
        
        nextParticles.setAtEncoder(encoder, index: 0)
        particles.setAtEncoder(encoder, index: 1)
        
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        
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
    
    func encodeDensityPass(
        _ commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.label = "Density Compute Pass"

        encoder.setComputePipelineState(densityRenderPipeline)
        
        particles.setAtEncoder(encoder, index: 0)

        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 1
        )

        encoder.setTexture(
            densityTexture,
            index: 0
        )

        let width = densityRenderPipeline.threadExecutionWidth

        let height =
            densityRenderPipeline.maxTotalThreadsPerThreadgroup
                / width

        let threadsPerGroup = MTLSize(
            width: width,
            height: height,
            depth: 1
        )

        let threads = MTLSize(
            width: densityTexture.width,
            height: densityTexture.height,
            depth: 1
        )

        encoder.dispatchThreads(
            threads,
            threadsPerThreadgroup: threadsPerGroup
        )

        encoder.endEncoding()
    }
    
    private func encodeRendering(_ commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        
        encoder.setRenderPipelineState(
            densityDisplayPipeline
        )

        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 1
        )

        encoder.setFragmentTexture(
            densityTexture,
            index: 0
        )

        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 1
        )

        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6
        )
        
        encoder.setRenderPipelineState(renderPipeline)
        
        particles.setAtVertexBuffer(encoder, index: 0)
        
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particles.count)
        
        // Bounds
        encoder.setRenderPipelineState(boundsPipeline)
       
        bounds.setAtVertexBuffer(encoder, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        
        encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: bounds.count)
        
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
        let dt = calculateDeltaTime()
        
        updateUniforms(view: view, dt: dt)
            
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else {
            return
        }
        
        if !settings.paused {
            encodeDensityCalculation(commandBuffer)
            encodeSimulation(commandBuffer)
        }
        
        encodeDensityPass(commandBuffer)
        encodeRendering(commandBuffer, descriptor: descriptor)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
