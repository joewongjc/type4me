import AppKit
import SwiftUI

/// A SwiftUI bridge for native HUD / Popover frosted glass that samples behind its window.
struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat = 0
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var state: NSVisualEffectView.State = .active
    var isEmphasized: Bool = false
    var appearanceName: NSAppearance.Name? = .darkAqua

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.wantsLayer = true
        configure(view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
        if let appearanceName {
            view.appearance = NSAppearance(named: appearanceName)
        } else {
            view.appearance = nil
        }
    }
}
