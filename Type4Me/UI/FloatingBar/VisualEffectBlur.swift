import AppKit
import SwiftUI

/// Hosts the system compositor's glass implementation.
///
/// A `CALayer.backgroundFilters` Gaussian blur only processes pixels already in
/// the same layer tree. It cannot reliably blur windows belonging to other apps,
/// so using one here produces a costly opacity-like effect instead of a spatial
/// backdrop blur. On macOS 26 we use `NSGlassEffectView` directly; older systems
/// fall back to the supported behind-window `NSVisualEffectView` material.
final class RecordingGlassEffectHostView: NSView {
    private(set) var appliedBlurEffect = RecordingGlassBlurEffect.frosted
    private(set) var appliedTintColor: NSColor?

    @available(macOS 26.0, *)
    private var nativeGlassView: NSGlassEffectView? {
        subviews.first as? NSGlassEffectView
    }

    private var fallbackVisualEffectView: NSVisualEffectView? {
        subviews.first as? NSVisualEffectView
    }

    var usesNativeLiquidGlass: Bool {
        if #available(macOS 26.0, *) {
            return nativeGlassView != nil
        }
        return false
    }

    @available(macOS 26.0, *)
    var nativeGlassStyle: NSGlassEffectView.Style? {
        nativeGlassView?.style
    }

    @available(macOS 26.0, *)
    var nativeGlassTintColor: NSColor? {
        nativeGlassView?.tintColor
    }

    override func layout() {
        super.layout()
        subviews.first?.frame = bounds
    }

    func configure(
        cornerRadius: CGFloat,
        blendingMode: NSVisualEffectView.BlendingMode,
        appearanceName: NSAppearance.Name?,
        blurEffect: RecordingGlassBlurEffect,
        transparency: Double,
        tintColor: NSColor?
    ) {
        wantsLayer = true
        let resolvedOpacity = 1 - min(max(transparency, 0), 1)
        if alphaValue != resolvedOpacity {
            alphaValue = resolvedOpacity
        }

        let resolvedAppearance = appearanceName.flatMap(NSAppearance.init(named:))
        if appearance?.name != resolvedAppearance?.name {
            appearance = resolvedAppearance
        }

        if #available(macOS 26.0, *) {
            let glass: NSGlassEffectView
            if let existing = nativeGlassView {
                glass = existing
            } else {
                subviews.forEach { $0.removeFromSuperview() }
                glass = NSGlassEffectView(frame: bounds)
                glass.autoresizingMask = [.width, .height]
                addSubview(glass)
            }
            glass.cornerRadius = cornerRadius
            glass.style = blurEffect == .frosted ? .regular : .clear
            glass.tintColor = tintColor
        } else {
            let effect: NSVisualEffectView
            if let existing = fallbackVisualEffectView {
                effect = existing
            } else {
                subviews.forEach { $0.removeFromSuperview() }
                effect = NSVisualEffectView(frame: bounds)
                effect.autoresizingMask = [.width, .height]
                addSubview(effect)
            }
            effect.material = blurEffect == .frosted ? .popover : .menu
            effect.blendingMode = blendingMode
            effect.state = .active
            effect.isEmphasized = false
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.cornerCurve = .continuous
            effect.layer?.masksToBounds = cornerRadius > 0
            effect.layer?.backgroundColor = tintColor?.cgColor
        }

        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = cornerRadius > 0
        appliedBlurEffect = blurEffect
        appliedTintColor = tintColor
    }
}

/// AppKit-backed Control Center-style glass. The public system API intentionally
/// exposes semantic styles rather than an arbitrary pixel blur radius.
struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat = 0
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var appearanceName: NSAppearance.Name? = .darkAqua
    var blurEffect: RecordingGlassBlurEffect = .frosted
    var transparency: Double = 0
    var tintColor: NSColor?

    func makeNSView(context: Context) -> RecordingGlassEffectHostView {
        let view = RecordingGlassEffectHostView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: RecordingGlassEffectHostView, context: Context) {
        configure(nsView)
    }

    func configure(_ view: RecordingGlassEffectHostView) {
        view.configure(
            cornerRadius: cornerRadius,
            blendingMode: blendingMode,
            appearanceName: appearanceName,
            blurEffect: blurEffect,
            transparency: transparency,
            tintColor: tintColor
        )
    }
}
