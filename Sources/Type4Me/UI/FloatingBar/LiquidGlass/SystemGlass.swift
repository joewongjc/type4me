//
//  SystemGlass.swift
//  Type4Me
//

import AppKit
import SwiftUI

/// AppKit's Liquid Glass with two private `NSGlassEffectView` settings: the
/// variant Notification Center uses, and the subdued state macOS gives glass in
/// an app that is not frontmost. Type4Me is never frontmost while recording, so
/// public glass always draws flat and frosted. Both settings are private and may
/// change with macOS; when either is missing, callers keep the public glass.
enum SystemGlass {
    /// Notification Center's glass: clear, with the bright rim and lensing of
    /// the system's own floating panels.
    static let notificationCenterVariant = 9

    private static let setters = ["set_variant:", "set_subduedState:"]

    /// Whether this macOS still has both private settings.
    static var isAvailable: Bool {
        guard #available(macOS 26.0, *) else { return false }
        return setters.allSatisfy { NSGlassEffectView.instancesRespond(to: NSSelectorFromString($0)) }
    }
}

/// Glass that holds its private settings. AppKit sets the subdued state again
/// whenever the window gains or loses focus or the app comes and goes from the
/// front, so it is turned back off right after each of those.
@available(macOS 26.0, *)
final class SteadyGlassEffectView: NSGlassEffectView {
    private var observers: [NSObjectProtocol] = []

    init(variant: Int = SystemGlass.notificationCenterVariant) {
        super.init(frame: .zero)
        setValue(variant, forKey: "_variant")
        holdFullLook()
    }

    required init?(coder: NSCoder) { nil }

    /// A backdrop only: clicks and drags go to the SwiftUI content above it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Observers are dropped here when the view leaves its window, so a rebuilt
    /// surface leaves none behind.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        guard let window else { return }
        let center = NotificationCenter.default
        let focusChanges: [(Notification.Name, AnyObject?)] = [
            (NSWindow.didBecomeKeyNotification, window), (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil), (NSApplication.didResignActiveNotification, nil),
        ]
        for (name, object) in focusChanges {
            observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.holdFullLookAfterAppKit() }
            })
        }
        holdFullLook()
    }

    private func holdFullLook() {
        setValue(0, forKey: "_subduedState")
    }

    /// Now, and again once AppKit has finished reacting to the same change.
    private func holdFullLookAfterAppKit() {
        holdFullLook()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.holdFullLook() }
        }
    }
}

/// `SteadyGlassEffectView` as a SwiftUI backdrop. `tint` is laid inside the
/// glass, so it decides the surface's tone whatever is behind the bar.
@available(macOS 26.0, *)
struct SystemGlassBackground: NSViewRepresentable {
    let cornerRadius: CGFloat
    let tint: NSColor?

    func makeNSView(context: Context) -> SteadyGlassEffectView {
        let glass = SteadyGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.tintColor = tint
        return glass
    }

    func updateNSView(_ glass: SteadyGlassEffectView, context: Context) {
        if glass.cornerRadius != cornerRadius { glass.cornerRadius = cornerRadius }
        if glass.tintColor != tint { glass.tintColor = tint }
    }
}
