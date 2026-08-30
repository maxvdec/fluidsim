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
import simd
import SwiftUI

struct SpawnRegion: Identifiable, Equatable {
    var id = UUID()
    var centerX: Float
    var centerY: Float
    var centerZ: Float
    var sizeX: Float
    var sizeY: Float
    var sizeZ: Float
}

@Observable
final class SimulationSettings {
    var paused = true

    var gravity: Float = 9.81 // m/s^2
    var particleRadius: Float = 0.05 // m

    var ppm: Float = 20

    var timeScale: Float = 1.0

    var boundsX: Float = 16.0 // m
    var boundsY: Float = 8.0 // m
    var boundsZ: Float = 10.0 // m
    var boundaryViewportPadding: Float = 10.0

    var particles: Int = 65536
    var particleSpacing: Float = 0.12
    var randomScattering: Bool = false
    var spawnJitter: Float = 0.018
    var spawnRegions: [SpawnRegion] = [
        SpawnRegion(
            centerX: 0.0,
            centerY: -1.35,
            centerZ: 0.0,
            sizeX: 5.0,
            sizeY: 5.0,
            sizeZ: 5.0
        )
    ]

    var smoothingRadius: Float = 0.21 // m

    var targetDensity: Float = 630.0
    var pressureMultiplier: Float = 220.0
    var viscosityStrength: Float = 0.018
    var nearPressureMultiplier: Float = 2.25
    var particleMass: Float = 1.2

    var mouseStrength: Float = 200.0
    var mouseRadius: Float = 4.0

    var densityResolution: Int = 128

    var stepSize: Float = 0.025
    var lightStepSize: Float = 0.1
    var densityMultiplier: Float = 0.00008
    var isoLevel: Float = 155.0
    
    var scatterR: Float = 12.0
    var scatterG: Float = 4.0
    var scatterB: Float = 4.0
    
    var brightnessMultiplier: Float = 1.15
    var waterIOR: Float = 1.333
    var surfaceRoughness: Float = 0.0

    var showBounds = false

    var colliderEnabled = true
    var colliderCollisions = true
    var colliderFloating = false
    var colliderX: Float = 4.5
    var colliderY: Float = -3.4
    var colliderZ: Float = 0.0
    var colliderSizeX: Float = 2.2
    var colliderSizeY: Float = 1.2
    var colliderSizeZ: Float = 2.2

    var foamEnabled = true
    var foamSpawnRate: Float = 70.0
    var foamVelocityMin: Float = 5.0
    var foamVelocityMax: Float = 25.0
    var foamKineticMin: Float = 15.0
    var foamKineticMax: Float = 80.0
    var foamScale: Float = 0.025
    var sprayEnabled = true
    var sprayMaxNeighbours: Int = 5
    var bubbleMinNeighbours: Int = 15
    var bubbleBuoyancy: Float = 1.5
    var bubbleScale: Float = 0.5
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

        view.onLeftMouseDown = { point, mode in
            renderer.beginMouseInteraction(
                at: point,
                in: view,
                mode: mode
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

func densityResolution(
    maxResolution: Int,
    bounds: SIMD3<Float>
) -> SIMD3<Int> {
    let largestDimension = max(
        bounds.x,
        bounds.y,
        bounds.z
    )

    let scale = Float(maxResolution) / largestDimension

    let x = max(1, Int(round(bounds.x * scale)))
    let y = max(1, Int(round(bounds.y * scale)))
    let z = max(1, Int(round(bounds.z * scale)))

    return SIMD3<Int>(x, y, z)
}

func createParticlesInSpawnRegions(
    n: Int,
    settings: SimulationSettings
) -> [Particle] {
    let requestedRegions = settings.spawnRegions.isEmpty
        ? [SpawnRegion(centerX: 0.0, centerY: 0.0, centerZ: 0.0, sizeX: 1.0, sizeY: 1.0, sizeZ: 1.0)]
        : settings.spawnRegions
    let regions = Array(requestedRegions.prefix(max(1, min(requestedRegions.count, n))))
    let volumes = regions.map {
        max($0.sizeX, 0.05) * max($0.sizeY, 0.05) * max($0.sizeZ, 0.05)
    }
    let totalVolume = max(volumes.reduce(0, +), 0.0001)
    var particles: [Particle] = []
    particles.reserveCapacity(n)
    var remaining = n
    let limit = SIMD3<Float>(
        settings.boundsX * 0.5 - settings.particleRadius,
        settings.boundsY * 0.5 - settings.particleRadius,
        settings.boundsZ * 0.5 - settings.particleRadius
    )

    for (regionIndex, region) in regions.enumerated() {
        let regionsLeft = regions.count - regionIndex - 1
        let proposed = regionIndex == regions.count - 1
            ? remaining
            : Int(round(Float(n) * volumes[regionIndex] / totalVolume))
        let count = max(1, min(remaining - regionsLeft, proposed))
        remaining -= count
        let size = SIMD3<Float>(
            max(region.sizeX, settings.particleSpacing),
            max(region.sizeY, settings.particleSpacing),
            max(region.sizeZ, settings.particleSpacing)
        )
        let scale = pow(Float(count) / max(size.x * size.y * size.z, 0.0001), 1.0 / 3.0)
        var dimensions = SIMD3<Int>(
            max(1, Int(round(size.x * scale))),
            max(1, Int(round(size.y * scale))),
            max(1, Int(round(size.z * scale)))
        )
        while dimensions.x * dimensions.y * dimensions.z < count {
            let spacing = size / SIMD3<Float>(
                Float(max(dimensions.x - 1, 1)),
                Float(max(dimensions.y - 1, 1)),
                Float(max(dimensions.z - 1, 1))
            )
            if spacing.x >= spacing.y && spacing.x >= spacing.z {
                dimensions.x += 1
            } else if spacing.y >= spacing.z {
                dimensions.y += 1
            } else {
                dimensions.z += 1
            }
        }
        let center = SIMD3<Float>(region.centerX, region.centerY, region.centerZ)
        let step = SIMD3<Float>(
            dimensions.x > 1 ? size.x / Float(dimensions.x - 1) : 0.0,
            dimensions.y > 1 ? size.y / Float(dimensions.y - 1) : 0.0,
            dimensions.z > 1 ? size.z / Float(dimensions.z - 1) : 0.0
        )
        for index in 0 ..< count {
            let gridCount = dimensions.x * dimensions.y * dimensions.z
            let sampleIndex = count > 1
                ? Int(round(Float(index) * Float(gridCount - 1) / Float(count - 1)))
                : 0
            let x = sampleIndex % dimensions.x
            let z = (sampleIndex / dimensions.x) % dimensions.z
            let y = sampleIndex / (dimensions.x * dimensions.z)
            let grid = SIMD3<Float>(Float(x), Float(y), Float(z))
            let extent = step * SIMD3<Float>(
                Float(dimensions.x - 1),
                Float(dimensions.y - 1),
                Float(dimensions.z - 1)
            )
            let jitter = SIMD3<Float>(
                Float.random(in: -1.0 ... 1.0),
                Float.random(in: -1.0 ... 1.0),
                Float.random(in: -1.0 ... 1.0)
            ) * min(settings.spawnJitter, settings.particleSpacing * 0.35)
            let position = simd_clamp(center - extent * 0.5 + grid * step + jitter, -limit, limit)
            particles.append(
                Particle(
                    position: position,
                    predictedPosition: position,
                    velocity: .zero,
                    density: 0,
                    nearDensity: 0
                )
            )
        }
    }
    return particles
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

func createParticles(n: Int, wantsRandom: Bool, settings: SimulationSettings) -> [Particle] {
    if wantsRandom {
        return scatterParticlesRandomly(n: n, settings: settings)
    } else {
        return createParticlesInSpawnRegions(n: n, settings: settings)
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
    descriptor.colorAttachments[0].isBlendingEnabled = true
    descriptor.colorAttachments[0].rgbBlendOperation = .add
    descriptor.colorAttachments[0].alphaBlendOperation = .add
    descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
    descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
    descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
    descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
    descriptor.depthAttachmentPixelFormat = .depth32Float
    descriptor.rasterSampleCount = 4

    return try device.makeRenderPipelineState(descriptor: descriptor)
}

func createDensityTexture(device: MTLDevice, width: Int, height: Int, depth: Int) -> MTLTexture {
    let descriptor = MTLTextureDescriptor()

    descriptor.textureType = .type3D
    descriptor.pixelFormat = .rgba16Float

    descriptor.width = max(width, 1)
    descriptor.height = max(height, 1)
    descriptor.depth = max(depth, 1)

    descriptor.mipmapLevelCount = 1

    descriptor.usage = [
        .shaderRead,
        .shaderWrite
    ]

    descriptor.storageMode = .private

    return device.makeTexture(descriptor: descriptor)!
}

func createFinalRenderTexture(
    device: MTLDevice,
    width: Int,
    height: Int
) -> MTLTexture {
    let descriptor =
        MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: max(1, width),
            height: max(1, height),
            mipmapped: false
        )

    descriptor.usage = [
        .shaderRead,
        .shaderWrite
    ]

    descriptor.storageMode = .private

    return device.makeTexture(
        descriptor: descriptor
    )!
}

func createFinalDepthTexture(
    device: MTLDevice,
    width: Int,
    height: Int
) -> MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r32Float,
        width: max(1, width),
        height: max(1, height),
        mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    return device.makeTexture(descriptor: descriptor)!
}

func createBounds(settings: SimulationSettings) -> [SIMD3<Float>] {
    let hx = settings.boundsX * 0.5
    let hy = settings.boundsY * 0.5
    let hz = settings.boundsZ * 0.5

    let lbf = SIMD3<Float>(-hx, -hy, hz)
    let rbf = SIMD3<Float>(hx, -hy, hz)
    let ltf = SIMD3<Float>(-hx, hy, hz)
    let rtf = SIMD3<Float>(hx, hy, hz)

    let lbb = SIMD3<Float>(-hx, -hy, -hz)
    let rbb = SIMD3<Float>(hx, -hy, -hz)
    let ltb = SIMD3<Float>(-hx, hy, -hz)
    let rtb = SIMD3<Float>(hx, hy, -hz)

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

func createCellStartIndices(particleCount: Int) -> [UInt32] {
    Array(repeating: UInt32.max, count: particleCount)
}

func createFoamParticles(count: Int) -> [FoamParticle] {
    Array(
        repeating: FoamParticle(
            position: .zero,
            velocity: .zero,
            lifetime: 0.0,
            scale: 1.0,
            kind: 0.0
        ),
        count: count
    )
}

@MainActor
final class Renderer: NSObject, MTKViewDelegate {
    let settings: SimulationSettings

    let device: MTLDevice

    private let commandQueue: MTLCommandQueue

    private let densityCalculationPipeline: MTLComputePipelineState
    private let simulationPipeline: MTLComputePipelineState
    private let densityClearPipeline: MTLComputePipelineState
    private let densitySplatPipeline: MTLComputePipelineState
    private let densityResolvePipeline: MTLComputePipelineState
    private let predictionPipeline: MTLComputePipelineState
    private let spatialClearPipeline: MTLComputePipelineState
    private let spatialLinkedListPipeline: MTLComputePipelineState
    private let finalRenderPipeline: MTLComputePipelineState
    private let foamUpdatePipeline: MTLComputePipelineState

    private let renderPipeline: MTLRenderPipelineState
    private let boundsPipeline: MTLRenderPipelineState
    private let finalTextureDisplayPipeline: MTLRenderPipelineState
    private let foamRenderPipeline: MTLRenderPipelineState

    private let depthStencilState: MTLDepthStencilState

    private var densityTexture: MTLTexture
    private var renderResult: MTLTexture
    private var renderDepthResult: MTLTexture

    var particles: MTLSyncBuffer<Particle>
    private var nextParticles: MTLSyncBuffer<Particle>
    var bounds: MTLSyncBuffer<SIMD3<Float>>
    private var particleNextIndices: MTLSyncBuffer<UInt32>
    private var cellStartIndices: MTLSyncBuffer<UInt32>
    private var foamParticles: MTLSyncBuffer<FoamParticle>
    private var foamCounter: MTLSyncBuffer<UInt32>
    private var densityAccumulation: MTLSyncBuffer<UInt32>

    private var uniforms: Uniforms = .init()
    private let simulationSubsteps = 2

    private var lastFrameTime: CFTimeInterval?

    private var lastRandomScattering: Bool = false
    private var lastParticleSpacing: Float = .nan
    private var lastParticleRadius: Float = .nan
    private var lastGenerationBounds: SIMD3<Float> = .zero
    private var lastSpawnRegions: [SpawnRegion] = []
    private var lastSpawnJitter: Float = .nan
    private var lastDensityConfiguration: [Float] = []
    private var densityVolumeDirty = true
    private var floatingColliderY: Float = 0.0
    private var floatingColliderVelocity: Float = 0.0
    private var wasColliderFloating = false

    private var mouseInteractionState: MouseInteractionState = .init()

    private var camera: Camera
    
    private let renderScale: CGFloat = 0.6

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

        let densityClearFunction = library.makeFunction(name: "clearDensityAccumulation")!
        self.densityClearPipeline = try! device.makeComputePipelineState(function: densityClearFunction)

        let densitySplatFunction = library.makeFunction(name: "splatDensity")!
        self.densitySplatPipeline = try! device.makeComputePipelineState(function: densitySplatFunction)

        let densityResolveFunction = library.makeFunction(name: "resolveDensity")!
        self.densityResolvePipeline = try! device.makeComputePipelineState(function: densityResolveFunction)

        let predictionFunction = library.makeFunction(name: "predictPositions")!
        self.predictionPipeline = try! device.makeComputePipelineState(function: predictionFunction)

        let spatialClearFunction = library.makeFunction(name: "clearCellStartIndices")!
        self.spatialClearPipeline = try! device.makeComputePipelineState(function: spatialClearFunction)

        let spatialLinkedListFunction = library.makeFunction(name: "buildSpatialLinkedList")!
        self.spatialLinkedListPipeline = try! device.makeComputePipelineState(function: spatialLinkedListFunction)

        let finalRenderFunction = library.makeFunction(name: "renderVolume")!
        self.finalRenderPipeline = try! device.makeComputePipelineState(function: finalRenderFunction)

        let foamUpdateFunction = library.makeFunction(name: "updateFoamParticles")!
        self.foamUpdatePipeline = try! device.makeComputePipelineState(function: foamUpdateFunction)

        self.renderPipeline = try! createRenderPipeline(vertex: "particleVertex", fragment: "particleFragment", device: device)
        self.boundsPipeline = try! createRenderPipeline(vertex: "boundsVertex", fragment: "boundsFragment", device: device)
        self.finalTextureDisplayPipeline = try! createRenderPipeline(
            vertex: "fullscreenVertex",
            fragment: "fullscreenFragment",
            device: device
        )
        self.foamRenderPipeline = try! createRenderPipeline(
            vertex: "foamVertex",
            fragment: "foamFragment",
            device: device
        )

        let depthDescriptor =
            MTLDepthStencilDescriptor()

        depthDescriptor.depthCompareFunction = .lessEqual
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

        let initialDensityResolution = densityResolution(
            maxResolution: settings.densityResolution,
            bounds: SIMD3<Float>(settings.boundsX, settings.boundsY, settings.boundsZ)
        )
        let initialParticles = createParticles(n: max(1, settings.particles), wantsRandom: settings.randomScattering, settings: settings)
        self.particles = MTLSyncBuffer(device: device, values: initialParticles)
        self.nextParticles = MTLSyncBuffer(device: device, values: initialParticles)
        self.bounds = MTLSyncBuffer(device: device, values: createBounds(settings: settings))
        self.particleNextIndices = MTLSyncBuffer(device: device, values: createCellStartIndices(particleCount: initialParticles.count))
        self.cellStartIndices = MTLSyncBuffer(device: device, values: createCellStartIndices(particleCount: initialParticles.count))
        self.foamParticles = MTLSyncBuffer(device: device, values: createFoamParticles(count: 16384))
        self.foamCounter = MTLSyncBuffer(device: device, values: [0])
        self.densityAccumulation = MTLSyncBuffer(
            device: device,
            values: Array(
                repeating: 0,
                count: initialDensityResolution.x * initialDensityResolution.y * initialDensityResolution.z
            )
        )

        self.lastRandomScattering = settings.randomScattering
        self.lastParticleSpacing = settings.particleSpacing
        self.lastParticleRadius = settings.particleRadius
        self.lastSpawnRegions = settings.spawnRegions
        self.lastSpawnJitter = settings.spawnJitter
        self.lastGenerationBounds = SIMD3<Float>(
            settings.boundsX,
            settings.boundsY,
            settings.boundsZ
        )

        self.densityTexture = createDensityTexture(
            device: device,
            width: initialDensityResolution.x,
            height: initialDensityResolution.y,
            depth: initialDensityResolution.z
        )
        self.renderResult = createFinalRenderTexture(device: device, width: 1, height: 1)
        self.renderDepthResult = createFinalDepthTexture(device: device, width: 1, height: 1)

        let initialCameraDistance =
            max(
                settings.boundsX,
                settings.boundsY,
                settings.boundsZ
            ) * 1.3

        self.camera = Camera(
            target: SIMD3<Float>(
                0,
                -settings.boundsY * 0.2,
                0
            ),
            distance: initialCameraDistance
        )
        camera.yaw = 0.55
        camera.pitch = 0.28

        super.init()
    }

    private func updateFinalRenderTextureSize(
        view: MTKView
    ) {
        let width =
            max(1, Int(view.drawableSize.width * renderScale))

        let height =
            max(1, Int(view.drawableSize.height * renderScale))

        guard
            renderResult.width != width ||
            renderResult.height != height
        else {
            return
        }

        renderResult =
            createFinalRenderTexture(
                device: device,
                width: width,
                height: height
            )
        renderDepthResult = createFinalDepthTexture(
            device: device,
            width: width,
            height: height
        )
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

        updateFinalRenderTextureSize(view: view)

        let boundaryViewportScale = max(0.01, 1.0 - settings.boundaryViewportPadding / 50.0)
        uniforms.ppm = min(uniforms.viewportSize.x / settings.boundsX, uniforms.viewportSize.y / settings.boundsY) * boundaryViewportScale
        updateDensityTextureSize()
        uniforms.bounds = SIMD3<Float>(settings.boundsX, settings.boundsY, settings.boundsZ)
        uniforms.smoothingRadius = settings.smoothingRadius
        uniforms.densityResolution = SIMD3<UInt32>(
            UInt32(densityTexture.width),
            UInt32(densityTexture.height),
            UInt32(densityTexture.depth)
        )
        
        uniforms.stepSize = settings.stepSize
        uniforms.lightStepSize = max(settings.lightStepSize, settings.stepSize)
        uniforms.densityMultiplier = settings.densityMultiplier
        uniforms.isoLevel = settings.isoLevel
        
        uniforms.scatterR = settings.scatterR
        uniforms.scatterG = settings.scatterG
        uniforms.scatterB = settings.scatterB
        uniforms.brightnessMultiplier = settings.brightnessMultiplier
        uniforms.waterIOR = max(settings.waterIOR, 1.0001)
        uniforms.surfaceRoughness = max(settings.surfaceRoughness, 0.0)
        uniforms.foamEnabled = settings.foamEnabled ? 1 : 0
        uniforms.foamDeltaTime = settings.paused ? 0.0 : min(dt, 1.0 / 30.0) * settings.timeScale
        uniforms.foamSpawnRate = max(settings.foamSpawnRate, 0.0)
        uniforms.foamVelocityMin = max(settings.foamVelocityMin, 0.0)
        uniforms.foamVelocityMax = max(settings.foamVelocityMax, uniforms.foamVelocityMin + 0.001)
        uniforms.foamKineticMin = max(settings.foamKineticMin, 0.0)
        uniforms.foamKineticMax = max(settings.foamKineticMax, uniforms.foamKineticMin + 0.001)
        uniforms.foamScale = max(settings.foamScale, 0.01)
        uniforms.foamParticleCapacity = UInt32(foamParticles.count)
        uniforms.sprayEnabled = settings.sprayEnabled ? 1 : 0
        uniforms.sprayMaxNeighbours = UInt32(max(settings.sprayMaxNeighbours, 0))
        uniforms.bubbleMinNeighbours = UInt32(max(settings.bubbleMinNeighbours, settings.sprayMaxNeighbours + 1))
        uniforms.bubbleBuoyancy = settings.bubbleBuoyancy
        uniforms.bubbleScale = max(settings.bubbleScale, 0.01)

        uniforms.colliderEnabled = settings.colliderEnabled ? 1 : 0
        uniforms.colliderCollisions = settings.colliderCollisions ? 1 : 0
        uniforms.colliderFloating = settings.colliderFloating ? 1 : 0
        if settings.colliderFloating {
            if !wasColliderFloating {
                floatingColliderY = settings.colliderY
                floatingColliderVelocity = 0.0
            }
            let fluidVolume = Float(particles.count)
                * settings.particleSpacing
                * settings.particleSpacing
                * settings.particleSpacing
            let fluidSurface = -settings.boundsY * 0.5
                + fluidVolume / max(settings.boundsX * settings.boundsZ, 0.001)
            let halfHeight = max(settings.colliderSizeY, 0.05) * 0.5
            let submerged = min(
                1.0,
                max(0.0, (fluidSurface - (floatingColliderY - halfHeight)) / (halfHeight * 2.0))
            )
            let acceleration = settings.gravity * (submerged * 2.0 - 1.0)
            let motionDeltaTime = settings.paused ? 0.0 : dt
            floatingColliderVelocity += acceleration * motionDeltaTime
            floatingColliderVelocity *= exp(-2.2 * motionDeltaTime)
            floatingColliderY += floatingColliderVelocity * motionDeltaTime
            floatingColliderY = max(
                floatingColliderY,
                -settings.boundsY * 0.5 + halfHeight
            )
        } else {
            floatingColliderY = settings.colliderY
            floatingColliderVelocity = 0.0
        }
        wasColliderFloating = settings.colliderFloating
        uniforms.colliderPosition = SIMD3<Float>(
            settings.colliderX,
            floatingColliderY,
            settings.colliderZ
        )
        uniforms.colliderVelocity = SIMD3<Float>(0.0, floatingColliderVelocity, 0.0)
        uniforms.colliderSize = SIMD3<Float>(
            max(settings.colliderSizeX, 0.05),
            max(settings.colliderSizeY, 0.05),
            max(settings.colliderSizeZ, 0.05)
        )

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

        uniforms.invViewProjectionMatrix = uniforms.viewProjectionMatrix.inverse

        uniforms.targetDensity = settings.targetDensity
        uniforms.pressureMultiplier = settings.pressureMultiplier
        uniforms.viscosityStrength = settings.viscosityStrength
        uniforms.nearPressureMultiplier = settings.nearPressureMultiplier

        updateMouseInteractionForFrame(
            dt: min(dt, 1.0 / 30.0) * settings.timeScale
        )

        uniforms.mousePosition = mouseInteractionState.currentSimPosition
        uniforms.mouseVelocity = mouseInteractionState.simVelocity
        uniforms.mouseRadius = settings.mouseRadius
        uniforms.mouseStrength = settings.mouseStrength
        uniforms.mouseMode = mouseInteractionState.isActive ? mouseInteractionState.mode.rawValue : MouseMode.none.rawValue

        if settings.paused {
            bounds.assign(new: createBounds(settings: settings))
            let requestedParticleCount = max(1, settings.particles)
            let generationBounds = SIMD3<Float>(
                settings.boundsX,
                settings.boundsY,
                settings.boundsZ
            )
            let shouldRegenerateParticles = lastRandomScattering != settings.randomScattering
                || particles.count != requestedParticleCount
                || lastParticleSpacing != settings.particleSpacing
                || lastParticleRadius != settings.particleRadius
                || lastGenerationBounds != generationBounds
                || lastSpawnRegions != settings.spawnRegions
                || lastSpawnJitter != settings.spawnJitter

            if shouldRegenerateParticles {
                regenerateParticles()
            }

            lastRandomScattering = settings.randomScattering
            lastParticleSpacing = settings.particleSpacing
            lastParticleRadius = settings.particleRadius
            lastGenerationBounds = generationBounds
            lastSpawnRegions = settings.spawnRegions
            lastSpawnJitter = settings.spawnJitter
        }

        uniforms.particleCount = UInt32(particles.count)
        uniforms.particleMass = max(settings.particleMass, 0.0001)

        let densityConfiguration = [
            settings.smoothingRadius,
            settings.targetDensity,
            settings.particleMass,
            settings.boundsX,
            settings.boundsY,
            settings.boundsZ,
            Float(settings.densityResolution)
        ]
        if densityConfiguration != lastDensityConfiguration {
            densityVolumeDirty = true
            lastDensityConfiguration = densityConfiguration
        }
    }

    private func updateDensityTextureSize() {
        let resolution = densityResolution(
            maxResolution: max(settings.densityResolution, 1),
            bounds: SIMD3<Float>(settings.boundsX, settings.boundsY, settings.boundsZ)
        )

        guard densityTexture.width != resolution.x ||
              densityTexture.height != resolution.y ||
              densityTexture.depth != resolution.z
        else {
            return
        }

        densityTexture = createDensityTexture(
            device: device,
            width: resolution.x,
            height: resolution.y,
            depth: resolution.z
        )
        densityAccumulation.assign(
            new: Array(repeating: 0, count: resolution.x * resolution.y * resolution.z)
        )
    }

    private func encodeFinalRender(
        _ commandBuffer: MTLCommandBuffer
    ) {
        guard let encoder =
            commandBuffer.makeComputeCommandEncoder()
        else {
            return
        }

        encoder.label =
            "Volume Render"

        encoder.setComputePipelineState(
            finalRenderPipeline
        )

        encoder.setTexture(
            densityTexture,
            index: 0
        )

        encoder.setTexture(
            renderResult,
            index: 1
        )

        encoder.setTexture(
            renderDepthResult,
            index: 2
        )

        encoder.setBytes(
            &uniforms,
            length: MemoryLayout<Uniforms>.stride,
            index: 0
        )

        let width =
            finalRenderPipeline
                .threadExecutionWidth

        let height =
            max(
                1,
                finalRenderPipeline
                    .maxTotalThreadsPerThreadgroup
                    / width
            )

        let threadsPerGroup =
            MTLSize(
                width: width,
                height: height,
                depth: 1
            )

        let threads =
            MTLSize(
                width: renderResult.width,
                height: renderResult.height,
                depth: 1
            )

        encoder.dispatchThreads(
            threads,
            threadsPerThreadgroup:
            threadsPerGroup
        )

        encoder.endEncoding()
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

        buildEncoder.setComputePipelineState(spatialLinkedListPipeline)
        particles.setAtEncoder(buildEncoder, index: 0)
        cellStartIndices.setAtEncoder(buildEncoder, index: 1)
        particleNextIndices.setAtEncoder(buildEncoder, index: 2)
        buildEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)

        let buildWidth = spatialLinkedListPipeline.threadExecutionWidth
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
        particleNextIndices.setAtEncoder(encoder, index: 2)
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

    private func encodeFoamUpdate(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.setComputePipelineState(foamUpdatePipeline)
        foamParticles.setAtEncoder(encoder, index: 0)
        particles.setAtEncoder(encoder, index: 1)
        particleNextIndices.setAtEncoder(encoder, index: 2)
        cellStartIndices.setAtEncoder(encoder, index: 3)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 4)
        let width = foamUpdatePipeline.threadExecutionWidth
        encoder.dispatchThreads(
            MTLSize(width: foamParticles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
    }

    private func encodeSimulation(_ commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(simulationPipeline)

        nextParticles.setAtEncoder(encoder, index: 0)
        particles.setAtEncoder(encoder, index: 1)
        particleNextIndices.setAtEncoder(encoder, index: 2)
        cellStartIndices.setAtEncoder(encoder, index: 3)
        foamParticles.setAtEncoder(encoder, index: 5)
        foamCounter.setAtEncoder(encoder, index: 6)

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
        guard let clearEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        clearEncoder.label = "Clear Density Volume"
        clearEncoder.setComputePipelineState(densityClearPipeline)
        densityAccumulation.setAtEncoder(clearEncoder, index: 0)
        clearEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        let clearWidth = densityClearPipeline.threadExecutionWidth
        clearEncoder.dispatchThreads(
            MTLSize(width: densityAccumulation.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: clearWidth, height: 1, depth: 1)
        )
        clearEncoder.endEncoding()

        guard let splatEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        splatEncoder.label = "Splat Particle Density"
        splatEncoder.setComputePipelineState(densitySplatPipeline)
        particles.setAtEncoder(splatEncoder, index: 0)
        densityAccumulation.setAtEncoder(splatEncoder, index: 1)
        splatEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 2)
        let splatWidth = densitySplatPipeline.threadExecutionWidth
        splatEncoder.dispatchThreads(
            MTLSize(width: particles.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: splatWidth, height: 1, depth: 1)
        )
        splatEncoder.endEncoding()

        guard let resolveEncoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        resolveEncoder.label = "Resolve Density Volume"
        resolveEncoder.setComputePipelineState(densityResolvePipeline)
        densityAccumulation.setAtEncoder(resolveEncoder, index: 0)
        resolveEncoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        resolveEncoder.setTexture(densityTexture, index: 0)
        let resolveWidth = densityResolvePipeline.threadExecutionWidth
        resolveEncoder.dispatchThreads(
            MTLSize(width: densityAccumulation.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: resolveWidth, height: 1, depth: 1)
        )
        resolveEncoder.endEncoding()
    }

    private func encodeRendering(_ commandBuffer: MTLCommandBuffer, descriptor: MTLRenderPassDescriptor) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        

        encoder.setRenderPipelineState(
            finalTextureDisplayPipeline
        )

        encoder.setFragmentTexture(
            renderResult,
            index: 0
        )

        encoder.setFragmentTexture(
            renderDepthResult,
            index: 1
        )

        encoder.setDepthStencilState(depthStencilState)

        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6
        )
        
//        encoder.setRenderPipelineState(renderPipeline)
//
//        particles.setAtVertexBuffer(encoder, index: 0)
//
//        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
//        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
//
//        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particles.count)

        if settings.foamEnabled {
            encoder.setRenderPipelineState(foamRenderPipeline)
            foamParticles.setAtVertexBuffer(encoder, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: foamParticles.count)
        }

        if settings.showBounds {
            encoder.setRenderPipelineState(boundsPipeline)
            bounds.setAtVertexBuffer(encoder, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: bounds.count)
        }

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

        uniforms.time += min(dt, 1.0 / 15.0)
        updateUniforms(
            view: view,
            dt: dt
        )

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            return
        }

        if settings.paused {
            if densityVolumeDirty {
                encodePrediction(commandBuffer)
                encodeCellStartIndices(commandBuffer)
                encodeDensityCalculation(commandBuffer)
                encodeDensityPass(commandBuffer)
                densityVolumeDirty = false
            }
        } else {
            for _ in 0 ..< simulationSubsteps {
                encodePrediction(commandBuffer)
                encodeCellStartIndices(commandBuffer)

                encodeDensityCalculation(commandBuffer)

                encodeSimulation(commandBuffer)
            }
            if settings.foamEnabled {
                encodeFoamUpdate(commandBuffer)
            }
            encodeDensityPass(commandBuffer)
            densityVolumeDirty = false
        }

        encodeFinalRender(commandBuffer)

        encodeRendering(
            commandBuffer,
            descriptor: descriptor
        )

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    private func mouseRay(
        at point: CGPoint,
        in view: MTKView
    ) -> (origin: SIMD3<Float>, direction: SIMD3<Float>)? {
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            return nil
        }

        let normalizedX = Float(
            (point.x - view.bounds.minX) / view.bounds.width
        )
        let normalizedY = view.isFlipped
            ? Float((view.bounds.maxY - point.y) / view.bounds.height)
            : Float((point.y - view.bounds.minY) / view.bounds.height)
        let ndcX = normalizedX * 2.0 - 1.0
        let ndcY = normalizedY * 2.0 - 1.0
        let aspect = Float(view.bounds.width / view.bounds.height)
        let halfHeight = tan(camera.fovY * 0.5)
        let halfWidth = halfHeight * aspect
        let direction = simd_normalize(
            camera.forward
                + camera.right * ndcX * halfWidth
                + camera.up * ndcY * halfHeight
        )

        return (camera.position, direction)
    }

    private func rayBoxInterval(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>
    ) -> (entry: Float, exit: Float)? {
        let halfBounds = SIMD3<Float>(
            settings.boundsX,
            settings.boundsY,
            settings.boundsZ
        ) * 0.5
        var entry = -Float.infinity
        var exit = Float.infinity

        for axis in 0 ..< 3 {
            if abs(direction[axis]) < 0.000001 {
                if origin[axis] < -halfBounds[axis]
                    || origin[axis] > halfBounds[axis]
                {
                    return nil
                }
                continue
            }

            let first = (-halfBounds[axis] - origin[axis]) / direction[axis]
            let second = (halfBounds[axis] - origin[axis]) / direction[axis]
            entry = max(entry, min(first, second))
            exit = min(exit, max(first, second))

            if exit < entry {
                return nil
            }
        }

        guard exit >= max(entry, 0.0) else {
            return nil
        }

        return (max(entry, 0.0), exit)
    }

    private func interactionPosition(
        at point: CGPoint,
        in view: MTKView
    ) -> SIMD3<Float>? {
        guard let ray = mouseRay(at: point, in: view) else {
            return nil
        }

        let normal = mouseInteractionState.interactionPlaneNormal
        let denominator = simd_dot(ray.direction, normal)

        guard abs(denominator) > 0.000001 else {
            return nil
        }

        let distance = simd_dot(
            mouseInteractionState.interactionPlanePoint - ray.origin,
            normal
        ) / denominator

        guard distance >= 0 else {
            return nil
        }

        return ray.origin + ray.direction * distance
    }

    func beginMouseInteraction(at point: CGPoint, in view: MTKView, mode: MouseMode) {
        guard let ray = mouseRay(at: point, in: view),
              let interval = rayBoxInterval(
                  origin: ray.origin,
                  direction: ray.direction
              )
        else {
            return
        }

        let planeNormal = camera.forward
        let planeDenominator = simd_dot(ray.direction, planeNormal)
        let targetDistance = abs(planeDenominator) > 0.000001
            ? simd_dot(camera.target - ray.origin, planeNormal) / planeDenominator
            : (interval.entry + interval.exit) * 0.5
        let interactionDistance = min(
            interval.exit,
            max(interval.entry, targetDistance)
        )
        let simPosition = ray.origin + ray.direction * interactionDistance

        mouseInteractionState.isActive = true
        mouseInteractionState.mode = mode
        mouseInteractionState.currentSimPosition = simPosition
        mouseInteractionState.previousSimPosition = simPosition
        mouseInteractionState.simVelocity = .zero
        mouseInteractionState.interactionPlanePoint = simPosition
        mouseInteractionState.interactionPlaneNormal = planeNormal
    }

    func updateMouseInteraction(at point: CGPoint, in view: MTKView) {
        guard mouseInteractionState.isActive,
              let simPosition = interactionPosition(at: point, in: view)
        else {
            return
        }

        mouseInteractionState.currentSimPosition = simPosition
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
        if mouseInteractionState.isActive {
            let depthDelta = delta * max(camera.distance * 0.002, 0.01)
            let offset = mouseInteractionState.interactionPlaneNormal * depthDelta
            mouseInteractionState.interactionPlanePoint += offset
            mouseInteractionState.currentSimPosition += offset
            mouseInteractionState.previousSimPosition = mouseInteractionState.currentSimPosition
            mouseInteractionState.simVelocity = .zero
            return
        }

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
    
    @MainActor
    func resetSimulation() {
        regenerateParticles()
        mouseInteractionState = .init()
    }
    
    private func regenerateParticles() {
        let particleCount = max(1, settings.particles)

        let newParticles = createParticles(
            n: particleCount,
            wantsRandom: settings.randomScattering,
            settings: settings
        )

        particles.assign(new: newParticles)
        nextParticles.assign(new: newParticles)

        particleNextIndices.assign(
            new: createCellStartIndices(particleCount: particleCount)
        )

        cellStartIndices.assign(
            new: createCellStartIndices(particleCount: particleCount)
        )

        foamParticles.assign(new: createFoamParticles(count: foamParticles.count))
        foamCounter.assign(new: [0])
        floatingColliderY = settings.colliderY
        floatingColliderVelocity = 0.0

        lastRandomScattering = settings.randomScattering
        lastParticleSpacing = settings.particleSpacing
        lastParticleRadius = settings.particleRadius
        lastSpawnRegions = settings.spawnRegions
        lastSpawnJitter = settings.spawnJitter
        lastGenerationBounds = SIMD3(
            settings.boundsX,
            settings.boundsY,
            settings.boundsZ
        )
        densityVolumeDirty = true
    }
}
