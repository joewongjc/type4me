import SwiftUI

/// Apple-style frosted liquid glass cancel button with liquid press & drag deformation physics.
struct LiquidGlassCancelButton: View {
    var theme: RecordingTheme = .dark
    var isHovered: Bool = false
    var isPressed: Bool = false
    var dragOffset: CGSize = .zero

    private let buttonSize: CGFloat = TF.recordingCancelControlSize // 35pt

    // Liquid Drag Dynamics
    private var clampedOffset: CGSize {
        guard isPressed else { return .zero }
        let distance = hypot(dragOffset.width, dragOffset.height)
        guard distance > 0 else { return .zero }
        let maxFollow: CGFloat = 2.5
        // Smooth logarithmic damping so offset gracefully plateaus at maxFollow
        let dampedDistance = min(maxFollow, distance * 0.08)
        let ratio = dampedDistance / distance
        return CGSize(width: dragOffset.width * ratio, height: dragOffset.height * ratio)
    }

    /// Continuous 2D stretch transform without angle branch cuts or 360° wrap discontinuities
    private var liquidStretchTransform: CGAffineTransform {
        guard isPressed else { return .identity }
        let dx = dragOffset.width
        let dy = dragOffset.height
        let distance = hypot(dx, dy)
        guard distance > 0.001 else { return .identity }

        let ux = dx / distance
        let uy = dy / distance

        let factor = min(1.0, distance / 50.0)
        let sx = 1.0 + factor * 0.04 // subtle stretch along drag axis
        let sy = 1.0 - factor * 0.025 // subtle compress across orthogonal axis

        // R(-θ) * S(sx, sy) * R(θ)
        let a = sx * ux * ux + sy * uy * uy
        let b = (sx - sy) * ux * uy
        let c = (sx - sy) * ux * uy
        let d = sx * uy * uy + sy * ux * ux

        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: 0, ty: 0)
    }

    var body: some View {
        ZStack {
            if theme == .light {
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // Light Theme: Frosted Liquid Glass Optics
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

                // 1. Translucent glass base
                Circle()
                    .fill(Color.white.opacity(isPressed ? 0.65 : (isHovered ? 0.50 : 0.35)))

                // 2. 3D Radial Refractive glass dome
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isPressed ? [
                                Color.white.opacity(0.95),
                                Color.white.opacity(0.70),
                                Color.black.opacity(0.12),
                            ] : [
                                Color.white.opacity(isHovered ? 0.80 : 0.65),
                                Color.white.opacity(isHovered ? 0.45 : 0.30),
                                Color.black.opacity(isHovered ? 0.08 : 0.04),
                            ],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 2,
                            endRadius: buttonSize * 0.55
                        )
                    )

                // 3. Delicate Fresnel reflection specular rim
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            stops: isPressed ? [
                                .init(color: Color.white.opacity(0.98), location: 0.0),
                                .init(color: Color.white.opacity(0.60), location: 0.45),
                                .init(color: Color.black.opacity(0.20), location: 1.0),
                            ] : [
                                .init(color: Color.white.opacity(isHovered ? 0.95 : 0.85), location: 0.0),
                                .init(color: Color.white.opacity(isHovered ? 0.45 : 0.30), location: 0.45),
                                .init(color: Color.black.opacity(isHovered ? 0.16 : 0.10), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isPressed ? 1.0 : 0.75
                    )

                // 4. Top-left specular gloss sheen ellipse
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isPressed ? 0.85 : (isHovered ? 0.70 : 0.50)),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: buttonSize * 0.55, height: buttonSize * 0.22)
                    .offset(x: -buttonSize * 0.08, y: -buttonSize * 0.22)

                // 5. Crisp SF Symbol xmark
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: isPressed ? .bold : .semibold))
                    .foregroundStyle(
                        Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
                            .opacity(isPressed ? 1.0 : (isHovered ? 0.92 : 0.78))
                    )
                    .shadow(color: Color.white.opacity(isPressed ? 0.8 : 0.4), radius: 0.5, x: 0, y: 0.5)

            } else {
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
                // Dark Theme: Frosted Liquid Glass Optics
                // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

                // 1. Dark translucent glass backdrop
                Circle()
                    .fill(Color.black.opacity(isPressed ? 0.45 : 0.38))

                // 2. Translucent glass fill with dynamic liquid brightness boost (0.12 -> 0.45 on press)
                Circle()
                    .fill(
                        RadialGradient(
                            colors: isPressed ? [
                                Color.white.opacity(0.55),
                                Color.white.opacity(0.38),
                                Color.white.opacity(0.22),
                            ] : [
                                Color.white.opacity(isHovered ? 0.22 : 0.12),
                                Color.white.opacity(isHovered ? 0.14 : 0.06),
                                Color.white.opacity(isHovered ? 0.08 : 0.02),
                            ],
                            center: UnitPoint(x: 0.35, y: 0.30),
                            startRadius: 2,
                            endRadius: buttonSize * 0.55
                        )
                    )

                // 3. Delicate glass outer rim (Fresnel reflection)
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            stops: isPressed ? [
                                .init(color: Color.white.opacity(0.75), location: 0.0),
                                .init(color: Color.white.opacity(0.45), location: 0.45),
                                .init(color: Color.white.opacity(0.25), location: 1.0),
                            ] : [
                                .init(color: Color.white.opacity(isHovered ? 0.45 : 0.30), location: 0.0),
                                .init(color: Color.white.opacity(isHovered ? 0.22 : 0.14), location: 0.45),
                                .init(color: Color.white.opacity(isHovered ? 0.10 : 0.06), location: 1.0),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isPressed ? 1.0 : 0.75
                    )

                // 4. Top-left specular gloss sheen
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isPressed ? 0.50 : (isHovered ? 0.35 : 0.22)),
                                Color.white.opacity(0.0),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: buttonSize * 0.55, height: buttonSize * 0.22)
                    .offset(x: -buttonSize * 0.08, y: -buttonSize * 0.22)

                // 5. Crisp SF Symbol xmark
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: isPressed ? .bold : .semibold))
                    .foregroundStyle(Color.white.opacity(isPressed ? 1.0 : (isHovered ? 0.95 : 0.82)))
                    .shadow(color: Color.black.opacity(isPressed ? 0.6 : 0.4), radius: 1, x: 0, y: 0.5)
            }
        }
        .frame(width: buttonSize, height: buttonSize)
        .transformEffect(liquidStretchTransform)
        .scaleEffect(isPressed ? 1.10 : (isHovered ? 1.04 : 1.0))
        .offset(clampedOffset)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isPressed)
        .animation(.spring(response: 0.24, dampingFraction: 0.75), value: isHovered)
        .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.8), value: clampedOffset)
    }
}
