//
//  LiquidGlassOrb.swift
//  Type4Me
//
//  Native Metal Liquid Glass Orb renderer ported directly from LerSent001/orb.
//  Copyright (c) 2026 LerSent001 (MIT License)
//  Pinned commit: fbf6eb81ad85e1125ed62027769bcfefc01d3613
//
//  The shader source is kept byte-identical to upstream. Everything Type4Me
//  adds — speech reactivity, the resting pose, the resolution-aware edge — is
//  expressed as per-frame uniform writes in `OrbUniformShaping`.
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

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            self.device = nil
            self.pipeline = nil
            return
        }
        self.device = device
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

// MARK: - Supersampled MTKView

/// An `MTKView` that renders above native resolution and lets the compositor
/// filter it back down.
///
/// At 45pt the orb is only ~90 native pixels across, which is not enough for
/// the shader's own edge to look clean and leaves the internal fluid detail
/// visibly stair-stepped. Rendering at 2x the backing scale and letting the
/// layer minify is a cheap, exact supersample for a surface this small.
private final class LiquidOrbMetalView: MTKView {
    /// Supersampling factor on top of the display's backing scale.
    static let superSample: CGFloat = 2.0

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(
            self,
            name: NSWindow.didChangeScreenNotification,
            object: nil
        )
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowScreenDidChange(_:)),
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
        }
        syncDrawableSize()
        syncRefreshRate()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
        syncRefreshRate()
    }

    override func layout() {
        super.layout()
        syncDrawableSize()
    }

    @objc private func windowScreenDidChange(_ notification: Notification) {
        syncDrawableSize()
        syncRefreshRate()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    private func syncDrawableSize() {
        let backingScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2.0
        layer?.contentsScale = backingScale
        let scale = backingScale * Self.superSample
        let width = max(1.0, bounds.width * scale)
        let height = max(1.0, bounds.height * scale)
        let target = CGSize(width: min(width, 4096), height: min(height, 4096))
        if drawableSize != target {
            drawableSize = target
        }
    }

    private func syncRefreshRate() {
        // Matching the display avoids the beat frequency a fixed 60 produces on
        // a 120Hz panel, which is a large part of why the orb reads as jittery.
        let maxFPS = window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond
            ?? 60
        preferredFramesPerSecond = max(30, min(120, maxFPS))
    }
}

// MARK: - Metal MTKView Renderer

private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var baseUniforms: [Float]
    private var currentUniforms: [Float]
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var envelope = OrbSpeechEnvelope()
    private var motionScale: Float

    private let audioLevelMeter: AudioLevelMeter
    private(set) var isAnimated: Bool

    init?(view: MTKView, preset: OrbPreset, audioLevelMeter: AudioLevelMeter) {
        guard let device = LiquidOrbPipelineManager.shared.device,
              let pipeline = LiquidOrbPipelineManager.shared.pipeline,
              let queue = device.makeCommandQueue() else {
            return nil
        }
        self.commandQueue = queue
        self.pipeline = pipeline
        self.baseUniforms = preset.uniforms
        self.currentUniforms = preset.uniforms
        self.audioLevelMeter = audioLevelMeter
        self.isAnimated = preset.isAnimated
        self.motionScale = OrbUniformShaping.motionScale(
            flowResponse: preset.flowResponse
        )

        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.enableSetNeedsDisplay = !preset.isAnimated
        view.isPaused = !preset.isAnimated
        view.layer?.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func updatePreset(_ preset: OrbPreset, isAnimated: Bool) {
        if baseUniforms != preset.uniforms {
            baseUniforms = preset.uniforms
            motionScale = OrbUniformShaping.motionScale(
                flowResponse: preset.flowResponse
            )
        }
        if self.isAnimated != isAnimated {
            self.isAnimated = isAnimated
            if !isAnimated {
                envelope.reset()
            }
            lastFrameTime = CACurrentMediaTime()
        }
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

        if isAnimated {
            // The meter is read every render frame. Passing a Float through
            // SwiftUI only ever produced an occasional snapshot, because the
            // meter is deliberately not observable at audio-callback rate.
            envelope.advance(
                rawLevel: audioLevelMeter.current,
                deltaTime: dt,
                motionScale: motionScale
            )
        }

        let w = Float(view.drawableSize.width > 0 ? view.drawableSize.width : 180.0)
        let h = Float(view.drawableSize.height > 0 ? view.drawableSize.height : 180.0)

        currentUniforms = OrbUniformShaping.shape(
            base: baseUniforms,
            envelope: envelope,
            drawableWidth: w,
            drawableHeight: h,
            isAnimated: isAnimated
        )

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
    let audioLevelMeter: AudioLevelMeter
    let isAnimated: Bool
    let size: CGFloat

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        if let existingView = context.coordinator.mtkView {
            return existingView
        }
        let view = LiquidOrbMetalView(
            frame: CGRect(x: 0, y: 0, width: size, height: size),
            device: LiquidOrbPipelineManager.shared.device
        )
        if let renderer = LiquidOrbRenderer(
            view: view,
            preset: preset,
            audioLevelMeter: audioLevelMeter
        ) {
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
    let audioLevelMeter: AudioLevelMeter
    var isHovered: Bool = false
    var isPressed: Bool = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let orbSize: CGFloat = TF.recordingFinishControlSize // 45pt

    var body: some View {
        ZStack {
            // No `clipShape(Circle())`. The shader already fades its own alpha
            // to zero inside the frame, and SwiftUI's mask was cutting through
            // that gradient — which is where the visible jaggies came from.
            LiquidOrbMetalSurface(
                preset: style.preset,
                audioLevelMeter: audioLevelMeter,
                isAnimated: style.isAnimated && !reduceMotion,
                size: orbSize
            )
            .frame(width: orbSize, height: orbSize)

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
