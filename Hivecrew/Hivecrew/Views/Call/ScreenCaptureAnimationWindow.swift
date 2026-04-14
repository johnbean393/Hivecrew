//
//  ScreenCaptureAnimationWindow.swift
//  Hivecrew
//
//  Full-screen overlay that renders a captured screenshot being warped and
//  sucked into the Compact HUD / Dynamic Notch using a Metal shader on a
//  dense mesh, producing a smooth cloth-into-black-hole effect.
//

import AppKit
import ImageIO
import MetalKit

// MARK: - Uniforms (must match Metal struct)

struct SuckUniforms {
    var sinkPoint: SIMD2<Float>
    var progress: Float
    var aspectRatio: Float
    var flashIntensity: Float
    var _pad: Float = 0
}

// MARK: - Public API

@MainActor
final class ScreenCaptureAnimationController {

    static let shared = ScreenCaptureAnimationController()
    private var animationWindow: ScreenCaptureAnimationWindow?

    func playCaptureAnimation(imageData: Data, sinkRect: NSRect, screen: NSScreen) {
        animationWindow?.close()
        animationWindow = nil

        guard let imageSource = CGImageSourceCreateWithData(imageData as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return }

        let window = ScreenCaptureAnimationWindow(screen: screen)
        animationWindow = window
        window.orderFrontRegardless()

        window.runSuckAnimation(image: cgImage, sinkRect: sinkRect, screen: screen) { [weak self] in
            self?.animationWindow?.close()
            self?.animationWindow = nil
        }
    }
}

// MARK: - Overlay Window

private final class ScreenCaptureAnimationWindow: NSWindow {

    var renderer: SuckAnimationRenderer?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isReleasedWhenClosed = false
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        setFrame(screen.frame, display: false)
    }

    func runSuckAnimation(
        image: CGImage,
        sinkRect: NSRect,
        screen: NSScreen,
        completion: @escaping () -> Void
    ) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            completion()
            return
        }

        guard let renderer = SuckAnimationRenderer(
            image: image,
            screenFrame: screen.frame,
            sinkRect: sinkRect,
            device: device,
            completion: completion
        ) else {
            completion()
            return
        }
        self.renderer = renderer

        let metalView = MTKView(
            frame: NSRect(origin: .zero, size: frame.size),
            device: device
        )
        metalView.delegate = renderer
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.layer?.isOpaque = false
        metalView.isPaused = false
        metalView.enableSetNeedsDisplay = false
        contentView = metalView
    }
}

// MARK: - Metal Renderer

private final class SuckAnimationRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let texture: MTLTexture
    private let samplerState: MTLSamplerState

    private let sinkPoint: SIMD2<Float>
    private let aspectRatio: Float
    private let startTime: CFTimeInterval
    private let duration: CFTimeInterval = 0.85
    private let completion: () -> Void
    private var finished = false

    private static let gridW = 120
    private static let gridH = 80

    init?(
        image: CGImage,
        screenFrame: NSRect,
        sinkRect: NSRect,
        device: MTLDevice,
        completion: @escaping () -> Void
    ) {
        self.device = device
        guard let cq = device.makeCommandQueue() else { return nil }
        self.commandQueue = cq

        // Sink point in normalised mesh space (bottom-left origin)
        let sx = Float((sinkRect.midX - screenFrame.origin.x) / screenFrame.width)
        let sy = Float((sinkRect.midY - screenFrame.origin.y) / screenFrame.height)
        self.sinkPoint = SIMD2(sx, sy)
        self.aspectRatio = Float(screenFrame.width / screenFrame.height)

        // Texture from CGImage
        let loader = MTKTextureLoader(device: device)
        guard let tex = try? loader.newTexture(
            cgImage: image,
            options: [.textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue),
                      .SRGB: false]
        ) else { return nil }
        self.texture = tex

        // Render pipeline
        guard let library  = device.makeDefaultLibrary(),
              let vertFunc = library.makeFunction(name: "suckVertexShader"),
              let fragFunc = library.makeFunction(name: "suckFragmentShader") else { return nil }

        let vertexDesc = MTLVertexDescriptor()
        vertexDesc.attributes[0].format      = .float2
        vertexDesc.attributes[0].offset      = 0
        vertexDesc.attributes[0].bufferIndex = 0
        vertexDesc.attributes[1].format      = .float2
        vertexDesc.attributes[1].offset      = MemoryLayout<Float>.stride * 2
        vertexDesc.attributes[1].bufferIndex = 0
        vertexDesc.layouts[0].stride         = MemoryLayout<Float>.stride * 4

        let pipelineDesc = MTLRenderPipelineDescriptor()
        pipelineDesc.vertexFunction   = vertFunc
        pipelineDesc.fragmentFunction = fragFunc
        pipelineDesc.vertexDescriptor = vertexDesc

        let ca = pipelineDesc.colorAttachments[0]!
        ca.pixelFormat                 = .bgra8Unorm
        ca.isBlendingEnabled           = true
        ca.sourceRGBBlendFactor        = .sourceAlpha
        ca.destinationRGBBlendFactor   = .oneMinusSourceAlpha
        ca.sourceAlphaBlendFactor      = .one
        ca.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let ps = try? device.makeRenderPipelineState(descriptor: pipelineDesc) else { return nil }
        self.pipelineState = ps

        // Grid mesh
        let (vb, ib, ic) = Self.buildMesh(device: device, gridW: Self.gridW, gridH: Self.gridH)
        guard let vb, let ib else { return nil }
        self.vertexBuffer = vb
        self.indexBuffer  = ib
        self.indexCount   = ic

        // Sampler
        let samplerDesc = MTLSamplerDescriptor()
        samplerDesc.minFilter    = .linear
        samplerDesc.magFilter    = .linear
        samplerDesc.sAddressMode = .clampToEdge
        samplerDesc.tAddressMode = .clampToEdge
        guard let ss = device.makeSamplerState(descriptor: samplerDesc) else { return nil }
        self.samplerState = ss

        self.startTime  = CACurrentMediaTime()
        self.completion = completion
        super.init()
    }

    // MARK: MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !finished else { return }

        let elapsed = CACurrentMediaTime() - startTime
        let t = Float(min(elapsed / duration, 1.0))
        let flash = max(0, 0.35 * (1.0 - Float(elapsed / 0.2)))

        if t >= 1.0 {
            finished = true
            view.isPaused = true
            DispatchQueue.main.async { [completion] in completion() }
            return
        }

        guard let drawable       = view.currentDrawable,
              let rpd            = view.currentRenderPassDescriptor,
              let commandBuffer  = commandQueue.makeCommandBuffer(),
              let encoder        = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else { return }

        var uniforms = SuckUniforms(
            sinkPoint: sinkPoint,
            progress: t,
            aspectRatio: aspectRatio,
            flashIntensity: flash
        )

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SuckUniforms>.stride, index: 1)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(samplerState, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SuckUniforms>.stride, index: 1)

        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: Mesh Construction

    /// Builds a (gridW+1)×(gridH+1) vertex grid with position + texcoord
    /// and a triangle-list index buffer.
    private static func buildMesh(
        device: MTLDevice,
        gridW: Int,
        gridH: Int
    ) -> (MTLBuffer?, MTLBuffer?, Int) {

        let vertexCount = (gridW + 1) * (gridH + 1)
        var vertices = [Float]()
        vertices.reserveCapacity(vertexCount * 4)

        for row in 0...gridH {
            for col in 0...gridW {
                let u = Float(col) / Float(gridW)
                let v = Float(row) / Float(gridH)
                vertices.append(u)          // position.x  (0 = left, 1 = right)
                vertices.append(v)          // position.y  (0 = bottom, 1 = top)
                vertices.append(u)          // texcoord.u
                vertices.append(1.0 - v)    // texcoord.v  (flip: 0 = top of image)
            }
        }

        let cellCount = gridW * gridH
        var indices = [UInt32]()
        indices.reserveCapacity(cellCount * 6)

        for row in 0..<gridH {
            for col in 0..<gridW {
                let tl = UInt32(row * (gridW + 1) + col)
                let tr = tl + 1
                let bl = tl + UInt32(gridW + 1)
                let br = bl + 1
                indices.append(contentsOf: [tl, bl, tr, tr, bl, br])
            }
        }

        let vb = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.stride,
            options: .storageModeShared
        )
        let ib = device.makeBuffer(
            bytes: indices,
            length: indices.count * MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        )
        return (vb, ib, indices.count)
    }
}
