//
//  LiquidGlassOrb.swift
//  Type4Me iOS
//
//  UIKit port of the Mac `LiquidGlassOrb`. The shader source, presets and
//  speech envelope are the Mac files compiled in verbatim
//  (`OrbMetalSource.swift`, `OrbPreset.swift`, `LiquidGlassMotion.swift`), so
//  both platforms render the same orb from the same uniforms.
//
//  Shader: LerSent001/orb, MIT License, pinned commit
//  fbf6eb81ad85e1125ed62027769bcfefc01d3613.
//

import MetalKit
import QuartzCore
import SwiftUI
import UIKit

// MARK: - Shared Metal Pipeline

final class LiquidOrbPipeline: @unchecked Sendable {
    static let shared = LiquidOrbPipeline()

    let device: MTLDevice?
    private(set) var pipeline: MTLRenderPipelineState?
    private let lock = NSLock()
    private var compiling = false

    private init() {
        device = MTLCreateSystemDefaultDevice()
    }

    /// Compiles the shader off the main thread. The keyboard calls this as
    /// soon as it appears so the first press never waits for the compiler.
    func warmUp() {
        lock.lock()
        guard pipeline == nil, !compiling, let device else { lock.unlock(); return }
        compiling = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let built = Self.build(device: device)
            self.lock.lock()
            self.pipeline = built
            self.compiling = false
            self.lock.unlock()
        }
    }

    /// The compiled pipeline, or nil while it is still compiling. Never
    /// blocks the render loop.
    var current: MTLRenderPipelineState? {
        lock.lock()
        defer { lock.unlock() }
        return pipeline
    }

    private static func build(device: MTLDevice) -> MTLRenderPipelineState? {
        do {
            let library = try device.makeLibrary(source: orbMetalShaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "vs_main"),
                  let fragment = library.makeFunction(name: "fs_main") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("[LiquidGlassOrb] pipeline error: \(error)")
            return nil
        }
    }
}

// MARK: - Supersampled MTKView

/// Renders above native resolution so a 40pt orb keeps a clean edge and
/// unstepped fluid detail, as on Mac.
private final class LiquidOrbMetalView: MTKView {
    static let superSample: CGFloat = 1.5

    /// Caps the frame rate below the display's; nil follows the display.
    var frameRateCap: Int? {
        didSet { syncFrameRate() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        syncDrawableSize()
        syncFrameRate()
    }

    private func syncFrameRate() {
        let display = window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        preferredFramesPerSecond = min(display, frameRateCap ?? display)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    private func syncDrawableSize() {
        let scale = (window?.windowScene?.screen.scale ?? traitCollection.displayScale) * Self.superSample
        layer.contentsScale = scale / Self.superSample
        let target = CGSize(
            width: min(2048, max(1, bounds.width * scale)),
            height: min(2048, max(1, bounds.height * scale))
        )
        if drawableSize != target { drawableSize = target }
    }
}

// MARK: - Renderer

private final class LiquidOrbRenderer: NSObject, MTKViewDelegate {
    private let commandQueue: MTLCommandQueue
    private var baseUniforms: [Float]
    private var lastFrameTime: CFTimeInterval = CACurrentMediaTime()
    private var envelope = OrbSpeechEnvelope()
    private var motionScale: Float
    private let meter: AudioLevelMeter
    private(set) var isAnimated: Bool

    init?(view: MTKView, preset: OrbPreset, meter: AudioLevelMeter) {
        guard let device = LiquidOrbPipeline.shared.device,
              let queue = device.makeCommandQueue() else { return nil }
        commandQueue = queue
        baseUniforms = preset.uniforms
        self.meter = meter
        isAnimated = preset.isAnimated
        motionScale = OrbUniformShaping.motionScale(flowResponse: preset.flowResponse)
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.autoResizeDrawable = false
        view.isOpaque = false
        view.backgroundColor = .clear
        view.layer.isOpaque = false
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func update(preset: OrbPreset, isAnimated: Bool) {
        if baseUniforms != preset.uniforms {
            baseUniforms = preset.uniforms
            motionScale = OrbUniformShaping.motionScale(flowResponse: preset.flowResponse)
        }
        if self.isAnimated != isAnimated {
            self.isAnimated = isAnimated
            if !isAnimated { envelope.reset() }
            lastFrameTime = CACurrentMediaTime()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipeline = LiquidOrbPipeline.shared.current else {
            // Still compiling: a paused (static) orb gets no further frames on
            // its own, so ask again shortly.
            LiquidOrbPipeline.shared.warmUp()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak view] in view?.setNeedsDisplay() }
            return
        }
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        let now = CACurrentMediaTime()
        let dt = Float(min(0.05, max(0, now - lastFrameTime)))
        lastFrameTime = now
        if isAnimated {
            envelope.advance(rawLevel: meter.current, deltaTime: dt, motionScale: motionScale)
        }

        let w = Float(view.drawableSize.width > 0 ? view.drawableSize.width : 120)
        let h = Float(view.drawableSize.height > 0 ? view.drawableSize.height : 120)
        let uniforms = OrbUniformShaping.shape(
            base: baseUniforms,
            envelope: envelope,
            drawableWidth: w,
            drawableHeight: h,
            isAnimated: isAnimated
        )

        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

// MARK: - SwiftUI Bridge

private struct LiquidOrbMetalSurface: UIViewRepresentable {
    let preset: OrbPreset
    let meter: AudioLevelMeter
    let isAnimated: Bool
    let size: CGFloat
    let frameRateCap: Int?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = LiquidOrbMetalView(
            frame: CGRect(x: 0, y: 0, width: size, height: size),
            device: LiquidOrbPipeline.shared.device
        )
        if let renderer = LiquidOrbRenderer(view: view, preset: preset, meter: meter) {
            context.coordinator.renderer = renderer
            view.delegate = renderer
        }
        apply(to: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.renderer?.update(preset: preset, isAnimated: isAnimated)
        apply(to: view)
    }

    private func apply(to view: MTKView) {
        (view as? LiquidOrbMetalView)?.frameRateCap = frameRateCap
        view.isPaused = !isAnimated
        view.enableSetNeedsDisplay = !isAnimated
        if !isAnimated { view.setNeedsDisplay() }
    }

    final class Coordinator {
        var renderer: LiquidOrbRenderer?
    }
}

/// The Mac recording orb. Pass `isFrozen` to hold the resting pose (the orb
/// then draws one frame and stops costing GPU time).
struct LiquidGlassOrb: View {
    var style: RecordingVisualStyle = .siri
    let meter: AudioLevelMeter
    var size: CGFloat = 40
    var isFrozen = false
    var showsStop = false
    /// Decorative orbs (Home) run at 30 fps; the keyboard orb follows the display.
    var frameRateCap: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // No clipShape: the shader fades its own alpha at the rim, and a
            // mask cuts through that gradient into visible jaggies.
            LiquidOrbMetalSurface(
                preset: style.preset,
                meter: meter,
                isAnimated: style.isAnimated && !reduceMotion && !isFrozen,
                size: size,
                frameRateCap: frameRateCap
            )
            .frame(width: size, height: size)

            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Color.white.opacity(0.95))
                .frame(width: size * 0.24, height: size * 0.24)
                .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                .opacity(showsStop ? 1 : 0)
                .animation(.easeInOut(duration: 0.15), value: showsStop)
        }
        .frame(width: size, height: size)
        .allowsHitTesting(false)
    }
}
