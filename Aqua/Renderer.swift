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
    
    var boundsX: Float = 40.0 // m
    var boundsY: Float = 20.0 // m
    var boundsZ: Float = 20.0 // m
    var boundaryViewportPadding: Float = 10.0
    
    var particles: Int = 10000
    var particleSpacing: Float = 0.142
    var randomScattering: Bool = false
    
    var smoothingRadius: Float = 0.5 // m
    
    var targetDensity: Float = 100.0
    var pressureMultiplier: Float = 500.0
    var viscosityStrength: Float = 0.5
    var nearPressureMultiplier: Float = 0.1
    var particleMass: Float = 2.0
    
    var mouseStrength: Float = 200.0
    var mouseRadius: Float = 1.2
}

struct MetalView: NSViewRepresentable {
    let renderer: Renderer

    func makeNSView(
        context: Context
    ) -> SimulationMTKView {
        let view = SimulationMTKView()

        view.device = renderer.device
        view.delegate = renderer

        view.colorPixelFormat = .bgra8Unorm

        view.clearColor = MTLClearColor(
            red: 0,
            green: 0,
            blue: 0,
            alpha: 1
        )

        view.sampleCount = 4
        
        view.depthStencilPixelFormat = .depth32Float
        view.clearDepth = 1.0

        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false

        view.onLeftMouseDown = { point in
            renderer.beginMouseInteraction(
                at: point,
                in: view,
                mode: .repel
            )
        }

        view.onLeftMouseDragged = { point in
            renderer.updateMouseInteraction(
                at: point,
                in: view
            )
        }

        view.onLeftMouseUp = {
            renderer.endMouseInteraction()
        }

        view.onCameraRotate = { dx, dy in
            renderer.rotateCamera(
                deltaX: dx,
                deltaY: dy
            )
        }

        view.onCameraZoom = { delta in
            renderer.zoomCamera(
                delta: delta
            )
        }

        view.onCameraMoveChanged = { direction, active in
            renderer.setCameraMovement(
                direction,
                active: active
            )
        }

        return view
    }

    func updateNSView(
        _ nsView: SimulationMTKView,
        context: Context
    ) {}
}

func createParticlesInGrid(
    n: Int,
    settings: SimulationSettings,
    spacing: Float = 0.1
) -> [Particle] {
    guard n > 0 else {
        return []
    }

    let side = max(
        1,
        Int(ceil(pow(Double(n), 1.0 / 3.0)))
    )

    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(n)

    for zIndex in 0 ..< side {
        for yIndex in 0 ..< side {
            for xIndex in 0 ..< side {
                guard positions.count < n else {
                    break
                }

                let x =
                    (
                        Float(xIndex)
                        - Float(side - 1) * 0.5
                    ) * spacing

                let y =
                    (
                        Float(yIndex)
                        - Float(side - 1) * 0.5
                    ) * spacing

                let z =
                    (
                        Float(zIndex)
                        - Float(side - 1) * 0.5
                    ) * spacing

                positions.append(
                    SIMD3<Float>(x, y, z)
                )
            }
        }
    }

    return positions.map { position in
        Particle(
            position: position,
            predictedPosition: position,
            velocity: .zero,
            density: 0.0,
            nearDensity: 0.0
        )
    }
}

func scatterParticlesRandomly(
    n: Int,
    settings: SimulationSettings
) -> [Particle] {
    let halfBounds = SIMD3<Float>(
        settings.boundsX * 0.5 - settings.particleRadius,
        settings.boundsY * 0.5 - settings.particleRadius,
        settings.boundsZ * 0.5 - settings.particleRadius
    )

    var positions: [SIMD3<Float>] = []
    positions.reserveCapacity(n)

    for _ in 0 ..< n {
        let x = Float.random(
            in: -halfBounds.x ... halfBounds.x
        )

        let y = Float.random(
            in: -halfBounds.y ... halfBounds.y
        )

        let z = Float.random(
            in: -halfBounds.z ... halfBounds.z
        )

        positions.append(
            SIMD3<Float>(
                x,
                y,
                z
            )
        )
    }

    return positions.map { position in
        Particle(
            position: position,
            predictedPosition: position,
            velocity: SIMD3<Float>.zero,
            density: 0.0,
            nearDensity: 0.0
        )
    }
}

func createParticles(n: Int, wantsRandom: Bool, settings: SimulationSettings, spacing: Float = 0.1) -> [Particle] {
    if wantsRandom {
        return scatterParticlesRandomly(n: n, settings: settings)
    } else {
        return createParticlesInGrid(n: n, settings: settings, spacing: spacing)
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
    descriptor.depthAttachmentPixelFormat = .depth32Float
    descriptor.rasterSampleCount = 4
    
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

func createBounds(settings: SimulationSettings) -> [SIMD3<Float>] {
    let hx = settings.boundsX * 0.5
    let hy = settings.boundsY * 0.5
    let hz = settings.boundsZ * 0.5

    let lbf = SIMD3<Float>(-hx, -hy,  hz)
    let rbf = SIMD3<Float>( hx, -hy,  hz)
    let ltf = SIMD3<Float>(-hx,  hy,  hz)
    let rtf = SIMD3<Float>( hx,  hy,  hz)

    let lbb = SIMD3<Float>(-hx, -hy, -hz)
    let rbb = SIMD3<Float>( hx, -hy, -hz)
    let ltb = SIMD3<Float>(-hx,  hy, -hz)
    let rtb = SIMD3<Float>( hx,  hy, -hz)

    return [
        lbf, rbf,
        rbf, rtf,
        rtf, ltf,
        ltf, lbf,

        lbb, rbb,
        rbb, rtb,
        rtb, ltb,
        ltb, lbb,

        lbf, lbb,
        rbf, rbb,
        rtf, rtb,
        ltf, ltb
    ]
}

func spatialEntryCount(for particleCount: Int) -> Int {
    var count = 1
    while count < particleCount {
        count <<= 1
    }
    return count
}

func createLookupEntries(particleCount: Int) -> [SpatialLookupEntry] {
    let lookup = SpatialLookupEntry(particleIndex: UInt32.max, cellKey: UInt32.max)
    return Array(repeating: lookup, count: spatialEntryCount(for: particleCount))
}

func createCellStartIndices(particleCount: Int) -> [UInt32] {
    Array(repeating: UInt32.max, count: particleCount)
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let settings: SimulationSettings
    
    let device: MTLDevice
    
    private let commandQueue: MTLCommandQueue
    
    private let densityCalculationPipeline: MTLComputePipelineState
    private let simulationPipeline: MTLComputePipelineState
    private let densityRenderPipeline: MTLComputePipelineState
    private let predictionPipeline: MTLComputePipelineState
    private let spatialLookupPipeline: MTLComputePipelineState
    private let spatialSortPipeline: MTLComputePipelineState
    private let spatialClearPipeline: MTLComputePipelineState
    private let spatialStartPipeline: MTLComputePipelineState
    
    private let renderPipeline: MTLRenderPipelineState
    private let boundsPipeline: MTLRenderPipelineState
    private let densityDisplayPipeline: MTLRenderPipelineState
    
    private let depthStencilState: MTLDepthStencilState
    
    private var densityTexture: MTLTexture
    
    var particles: MTLSyncBuffer<Particle>
    private var nextParticles: MTLSyncBuffer<Particle>
    var bounds: MTLSyncBuffer<SIMD3<Float>>
    var lookupEntries: MTLSyncBuffer<SpatialLookupEntry>
    private var cellStartIndices: MTLSyncBuffer<UInt32>
    
    private var uniforms: Uniforms = .init()
    private let simulationSubsteps = 2
    
    private var lastFrameTime: CFTimeInterval?
    
    private var lastRandomScattering: Bool = false
    
    private var mouseInteractionState: MouseInteractionState = .init()
    
    private var camera: Camera
    
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
        
        let predictionFunction = library.makeFunction(name: "predictPositions")!
        self.predictionPipeline = try! device.makeComputePipelineState(function: predictionFunction)

        let lookupEntriesCompute = library.makeFunction(name: "updateSpatialLookup")!
        self.spatialLookupPipeline = try! device.makeComputePipelineState(function: lookupEntriesCompute)

        let spatialSortFunction = library.makeFunction(name: "sortSpatialLookup")!
        self.spatialSortPipeline = try! device.makeComputePipelineState(function: spatialSortFunction)

        let spatialClearFunction = library.makeFunction(name: "clearCellStartIndices")!
        self.spatialClearPipeline = try! device.makeComputePipelineState(function: spatialClearFunction)

        let spatialStartFunction = library.makeFunction(name: "buildCellStartIndices")!
        self.spatialStartPipeline = try! device.makeComputePipelineState(function: spatialStartFunction)

        self.renderPipeline = try! createRenderPipeline(vertex: "particleVertex", fragment: "particleFragment", device: device)
        self.boundsPipeline = try! createRenderPipeline(vertex: "boundsVertex", fragment: "boundsFragment", device: device)
        self.densityDisplayPipeline = try! createRenderPipeline(
            vertex: "densityVertex",
            fragment: "densityFragment",
            device: device
        )
        
        let depthDescriptor =
            MTLDepthStencilDescriptor()

        depthDescriptor.depthCompareFunction = .less
        depthDescriptor.isDepthWriteEnabled = true

        guard let depthState =
            device.makeDepthStencilState(
                descriptor: depthDescriptor
            )
        else {
            fatalError(
                "Could not create depth stencil state"
            )
        }

        self.depthStencilState = depthState
        
        let initialParticles = createParticles(n: max(1, settings.particles), wantsRandom: settings.randomScattering, settings: settings, spacing: settings.particleSpacing)
        self.particles = MTLSyncBuffer(device: device, values: initialParticles)
        self.nextParticles = MTLSyncBuffer(device: device, values: initialParticles)
        self.bounds = MTLSyncBuffer(device: device, values: createBounds(settings: settings))
        self.lookupEntries = MTLSyncBuffer(device: device, values: createLookupEntries(particleCount: initialParticles.count))
        self.cellStartIndices = MTLSyncBuffer(device: device, values: createCellStartIndices(particleCount: initialParticles.count))
        
        self.lastRandomScattering = settings.randomScattering
        
        self.densityTexture = createDensityTexture(device: device, width: 1, height: 1)
        
        let initialCameraDistance =
            max(
                settings.boundsX,
                settings.boundsY,
                settings.boundsZ
            ) * 1.3

        self.camera = Camera(
            target: .zero,
            distance: initialCameraDistance
        )
        
        super.init()
    }
    
    private func updateUniforms(view: MTKView, dt: Float) {
        camera.update(dt: dt)
        uniforms.dt = settings.paused
            ? 0.0
            : min(dt, 1.0 / 30.0) * settings.timeScale / Float(simulationSubsteps)
        
        uniforms.gravity = settings.gravity
        uniforms.particleSize = settings.particleRadius
        
        uniforms.viewportSize = SIMD2<Float>(
            Float(view.drawableSize.width),
            Float(view.drawableSize.height)
        )
        
        let boundaryViewportScale = max(0.01, 1.0 - settings.boundaryViewportPadding / 50.0)
        uniforms.ppm = min(uniforms.viewportSize.x / settings.boundsX, uniforms.viewportSize.y / settings.boundsY) * boundaryViewportScale
        updateDensityTextureSize()
        uniforms.bounds = SIMD3<Float>(settings.boundsX, settings.boundsY, settings.boundsZ)
        uniforms.smoothingRadius = settings.smoothingRadius
        
        let aspectRatio =
            max(
                uniforms.viewportSize.x /
                    max(uniforms.viewportSize.y, 1),
                0.0001
            )

        let viewMatrix =
            camera.viewMatrix()

        let projectionMatrix =
            camera.projectionMatrix(
                aspectRatio: aspectRatio
            )

        uniforms.viewMatrix =
            viewMatrix

        uniforms.projectionMatrix =
            projectionMatrix

        uniforms.viewProjectionMatrix =
            projectionMatrix * viewMatrix
        
        uniforms.targetDensity = settings.targetDensity
        uniforms.pressureMultiplier = settings.pressureMultiplier
        uniforms.viscosityStrength = settings.viscosityStrength
        uniforms.nearPressureMultiplier = settings.nearPressureMultiplier
        
        updateMouseInteractionForFrame(dt: uniforms.dt)
        
        uniforms.mousePosition = mouseInteractionState.currentSimPosition
        uniforms.mouseVelocity = mouseInteractionState.simVelocity
        uniforms.mouseRadius = settings.mouseRadius
        uniforms.mouseStrength = settings.mouseStrength
        uniforms.mouseMode = mouseInteractionState.isActive ? mouseInteractionState.mode.rawValue : MouseMode.none.rawValue
        
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

                lookupEntries.assign(new: createLookupEntries(particleCount: requestedParticleCount))
                cellStartIndices.assign(new: createCellStartIndices(particleCount: requestedParticleCount))
            }

            lastRandomScattering = settings.randomScattering
        }

        uniforms.particleCount = UInt32(particles.count)
        uniforms.spatialEntryCount = UInt32(lookupEntries.count)
        uniforms.particleMass = max(settings.particleMass, 0.0001)
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

    private func encodePrediction(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(predictionPipeline)
        particles.setAtEncoder(encoder, index: 0)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        let width = predictionPipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: particles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private func encodeLookupUpdate(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(spatialLookupPipeline)

        particles.setAtEncoder(encoder, index: 0)
        lookupEntries.setAtEncoder(encoder, index: 1)

        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

        let width = spatialLookupPipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: lookupEntries.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private func encodeLookupSort(_ commandBuffer: MTLCommandBuffer) {
        var sequenceLength: UInt32 = 2

        while sequenceLength <= UInt32(lookupEntries.count) {
            var comparisonDistance = sequenceLength >> 1

            while comparisonDistance > 0 {
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    return
                }

                encoder.setComputePipelineState(spatialSortPipeline)
                lookupEntries.setAtEncoder(encoder, index: 0)
                encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
                encoder.setBytes(&comparisonDistance, length: MemoryLayout<UInt32>.stride, index: 2)
                encoder.setBytes(&sequenceLength, length: MemoryLayout<UInt32>.stride, index: 3)

                let width = spatialSortPipeline.threadExecutionWidth
                encoder.dispatchThreads(
                    MTLSize(width: lookupEntries.count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
                )
                encoder.endEncoding()
                comparisonDistance >>= 1
            }

            sequenceLength <<= 1
        }
    }

    private func encodeCellStartIndices(_ commandBuffer: MTLCommandBuffer) {
        guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        clearEncoder.setComputePipelineState(spatialClearPipeline)
        cellStartIndices.setAtEncoder(clearEncoder, index: 0)
        clearEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

        let clearWidth = spatialClearPipeline.threadExecutionWidth
        clearEncoder.dispatchThreads(
            MTLSize(width: particles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: clearWidth, height: 1, depth: 1)
        )
        clearEncoder.endEncoding()

        guard let buildEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        buildEncoder.setComputePipelineState(spatialStartPipeline)
        lookupEntries.setAtEncoder(buildEncoder, index: 0)
        cellStartIndices.setAtEncoder(buildEncoder, index: 1)
        buildEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)

        let buildWidth = spatialStartPipeline.threadExecutionWidth
        buildEncoder.dispatchThreads(
            MTLSize(width: particles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: buildWidth, height: 1, depth: 1)
        )
        buildEncoder.endEncoding()
    }
    
    private func encodeDensityCalculation(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        
        encoder.setComputePipelineState(densityCalculationPipeline)
        
        particles.setAtEncoder(encoder, index: 0)
        nextParticles.setAtEncoder(encoder, index: 1)
        lookupEntries.setAtEncoder(encoder, index: 2)
        cellStartIndices.setAtEncoder(encoder, index: 3)
        
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
        
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
        lookupEntries.setAtEncoder(encoder, index: 2)
        cellStartIndices.setAtEncoder(encoder, index: 3)
        
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
        
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
        lookupEntries.setAtEncoder(encoder, index: 1)
        cellStartIndices.setAtEncoder(encoder, index: 2)

        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 3
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
        
        encoder.setDepthStencilState(depthStencilState)
        
//        encoder.setRenderPipelineState(
//            densityDisplayPipeline
//        )
//
//        encoder.setVertexBytes(
//            &uniforms,
//            length: MemoryLayout<Uniforms>.stride,
//            index: 1
//        )
//
//        encoder.setFragmentTexture(
//            densityTexture,
//            index: 0
//        )
//
//        encoder.setFragmentBytes(
//            &uniforms,
//            length: MemoryLayout<Uniforms>.stride,
//            index: 1
//        )
//
//        encoder.drawPrimitives(
//            type: .triangle,
//            vertexStart: 0,
//            vertexCount: 6
//        )
        
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
        
        if settings.paused {
            encodePrediction(commandBuffer)
            encodeLookupUpdate(commandBuffer)
            encodeLookupSort(commandBuffer)
            encodeCellStartIndices(commandBuffer)
        } else {
            for _ in 0 ..< simulationSubsteps {
                encodePrediction(commandBuffer)
                encodeLookupUpdate(commandBuffer)
                encodeLookupSort(commandBuffer)
                encodeCellStartIndices(commandBuffer)
                encodeDensityCalculation(commandBuffer)
                encodeSimulation(commandBuffer)
            }
        }
        
        encodeDensityPass(commandBuffer)
        encodeRendering(commandBuffer, descriptor: descriptor)
        
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    
    func beginMouseInteraction(at point: CGPoint, in view: MTKView, mode: MouseMode) {
        mouseInteractionState.isActive = true
        mouseInteractionState.mode = mode
        mouseInteractionState.simVelocity = .zero
    }
    
    func updateMouseInteraction(at point: CGPoint, in view: MTKView) {
    }
    
    func endMouseInteraction() {
        mouseInteractionState.isActive = false
        mouseInteractionState.mode = .none
        mouseInteractionState.simVelocity = .zero
    }
    
    func updateMouseInteractionForFrame(dt: Float) {
        guard mouseInteractionState.isActive else {
            mouseInteractionState.simVelocity = .zero
            return
        }
        
        let velocity = (mouseInteractionState.currentSimPosition - mouseInteractionState.previousSimPosition) / max(0.0001, dt)
        
        var clampedVelocity = velocity
        let maxSpeed: Float = 15.0
        let speed = simd_length(clampedVelocity)
        
        if speed > maxSpeed {
            clampedVelocity *= maxSpeed / speed
        }
        
        mouseInteractionState.simVelocity = clampedVelocity
        mouseInteractionState.previousSimPosition = mouseInteractionState.currentSimPosition
    }
    
    func rotateCamera(
        deltaX: Float,
        deltaY: Float
    ) {
        camera.orbit(
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    func zoomCamera(
        delta: Float
    ) {
        camera.zoom(delta: delta)
    }

    func setCameraMovement(
        _ direction: CameraMoveDirection,
        active: Bool
    ) {
        camera.setMoving(
            direction,
            active: active
        )
    }
}
