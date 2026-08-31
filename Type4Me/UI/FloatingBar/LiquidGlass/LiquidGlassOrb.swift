//
//  LiquidGlassOrb.swift
//  Type4Me
//
//  Native Metal Liquid Glass Orb renderer ported directly from LerSent001/orb.
//  Copyright (c) 2026 LerSent001 (MIT License)
//  Pinned commit: fbf6eb81ad85e1125ed62027769bcfefc01d3613
//

import AppKit
import MetalKit
import QuartzCore
import SwiftUI

// MARK: - Shared Metal Pipeline Cache

private final class LiquidOrbPipelineManager {
    static let shared = LiquidOrbPipelineManager()

    let device: MTLDevice?
    let pipeline: MTLRenderPipelineState?
    let commandQueue: MTLCommandQueue?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.pipeline = nil
            self.commandQueue = nil
            return
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()
        do {
            let library = try device.makeLibrary(source: orbMetalShaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "vs_main"),
                  let fragment = library.makeFunction(name: "fs_main") else {
                self.pipeline = nil
                return
            }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("[LiquidGlassOrb] Metal pipeline initialization error: \(error)")
            self.pipeline = nil
        }
    }
}

extension LiquidGlassOrb {
    /// Compile the embedded shader and create its render pipeline after launch,
    /// before the first recording indicator needs to draw it on the main thread.
    static func prewarmRenderer() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = LiquidOrbPipelineManager.shared.pipeline
        }
    }
}

// MARK: - Metal MTKView Renderer

private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var baseUniforms: [Float]
    private var currentUniforms: [Float]
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var integratedTime: Float = 0.0
    private var smoothedEnergy: Float = 0.0

    var audioEnergy: Float = 0.0
    var isAnimated: Bool = true

    init?(view: MTKView, preset: OrbPreset) {
        guard let device = LiquidOrbPipelineManager.shared.device,
              let pipeline = LiquidOrbPipelineManager.shared.pipeline,
              let queue = LiquidOrbPipelineManager.shared.commandQueue else {
            return nil
        }
        self.commandQueue = queue
        self.pipeline = pipeline
        self.baseUniforms = preset.uniforms
        self.currentUniforms = preset.uniforms
        self.isAnimated = preset.isAnimated

        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = !preset.isAnimated
        view.isPaused = !preset.isAnimated
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func updatePreset(_ preset: OrbPreset, audioEnergy: Float, isAnimated: Bool) {
        self.baseUniforms = preset.uniforms
        self.audioEnergy = audioEnergy
        self.isAnimated = isAnimated
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, max(0.0, now - lastFrameTime)))
        lastFrameTime = now

        // 1. Noise gate & dynamic curve: filter background room noise below 0.15
        let gate: Float = 0.15
        let rawNormalized = max(0.0, (audioEnergy - gate) / (1.0 - gate))
        let targetEnergy = pow(min(1.0, rawNormalized * 1.25), 1.2)

        // 2. Attack / decay ballistics for organic elasticity (snappy attack, soft decay)
        let decayRate: Float = targetEnergy > smoothedEnergy ? 22.0 : 7.0
        smoothedEnergy += (targetEnergy - smoothedEnergy) * min(1.0, dt * decayRate)

        // 3. Continuous numerical integration of phase velocity (1.0x baseline -> up to 2.5x during speech)
        if isAnimated {
            let speedMultiplier = 1.0 + smoothedEnergy * 1.5
            integratedTime += dt * speedMultiplier
        }

        let w = Float(view.drawableSize.width > 0 ? view.drawableSize.width : 90.0)
        let h = Float(view.drawableSize.height > 0 ? view.drawableSize.height : 90.0)

        currentUniforms = baseUniforms
        currentUniforms[0] = w
        currentUniforms[1] = h
        currentUniforms[2] = integratedTime

        // 4. Modulate exposure smoothly with audio energy (+70% boost on speech peaks)
        if isAnimated {
            let baseExposure = baseUniforms[14]
            currentUniforms[14] = baseExposure * (1.0 + smoothedEnergy * 0.70)
        }

        encoder.setRenderPipelineState(pipeline)
        currentUniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - NSViewRepresentable Bridge

private struct LiquidOrbMetalSurface: NSViewRepresentable {
    let preset: OrbPreset
    let audioEnergy: Float
    let isAnimated: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        if let existingView = context.coordinator.mtkView {
            return existingView
        }
        let view = MTKView(frame: CGRect(x: 0, y: 0, width: 45, height: 45), device: LiquidOrbPipelineManager.shared.device)
        view.drawableSize = CGSize(width: 90, height: 90)
        if let renderer = LiquidOrbRenderer(view: view, preset: preset) {
            context.coordinator.renderer = renderer
            context.coordinator.mtkView = view
            view.delegate = renderer
        }
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        view.isPaused = !isAnimated
        view.enableSetNeedsDisplay = !isAnimated
        context.coordinator.renderer?.updatePreset(
            preset,
            audioEnergy: audioEnergy,
            isAnimated: isAnimated
        )
        if !isAnimated {
            view.setNeedsDisplay(view.bounds)
        }
    }

    final class Coordinator {
        var mtkView: MTKView?
        var renderer: LiquidOrbRenderer?
    }
}

// MARK: - Public LiquidGlassOrb SwiftUI View

struct LiquidGlassOrb: View {
    let style: RecordingVisualStyle
    let audioEnergy: Float
    var isHovered: Bool = false
    var isPressed: Bool = false
    var isActive: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let orbSize: CGFloat = TF.recordingFinishControlSize // 45pt

    var body: some View {
        ZStack {
            LiquidOrbMetalSurface(
                preset: style.preset,
                audioEnergy: max(0.0, min(1.0, audioEnergy)),
                isAnimated: isActive && style.isAnimated && !reduceMotion
            )
            .frame(width: orbSize, height: orbSize)
            .clipShape(Circle())

            // Stop Affordance on hover / press
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .fill(Color.white.opacity(isPressed ? 0.75 : 0.95))
                .frame(width: 10, height: 10)
                .shadow(color: Color.black.opacity(0.6), radius: 2, x: 0, y: 1)
                .opacity(isHovered || isPressed ? 1.0 : 0.0)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .animation(.easeInOut(duration: 0.15), value: isPressed)
        }
        .frame(width: orbSize, height: orbSize)
    }
}
