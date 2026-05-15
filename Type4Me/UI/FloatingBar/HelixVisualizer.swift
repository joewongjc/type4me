import SwiftUI

/// DNA double-helix audio visualizer geometry + rendering.
///
/// `HelixGeometry` is a pure namespace — no stored state. It provides:
/// - testable particle-position math (`computeParticles`, `baseAmplitude`, `rungIndices`)
/// - a `render(into:size:time:audioLevel:)` draw routine used by `AudioRipple.drawHelix`
///
/// The render output is deterministic given `(time, audioLevel)` — no randomness, no physics.
enum HelixGeometry {

    struct Particle {
        let x: CGFloat
        let y: CGFloat
        let depth: Double   // -1 (back) .. +1 (front) = sin(angle)
        let pairIdx: Int
        let strand: Strand
    }

    enum Strand { case a, b }

    /// Computes deterministic particle positions for one helix frame.
    /// Returns 2 × pairs particles, ordered (pair0.a, pair0.b, pair1.a, …).
    /// x is centered at origin: xStart = -helixSpan/2. Caller translates to canvas center.
    static func computeParticles(
        pairs: Int,
        turns: Double,
        phase: Double,
        amp: Double,
        helixSpan: Double,
        cy: Double,
        time: Double
    ) -> [Particle] {
        guard pairs > 1 else { return [] }
        var result: [Particle] = []
        result.reserveCapacity(pairs * 2)

        let drawPhase = phase + 0.04 * sin(time * 1.6)   // gentle phase microperturbation
        let xStart = -helixSpan / 2

        for i in 0..<pairs {
            let t = Double(i) / Double(pairs - 1)
            let x = xStart + t * helixSpan
            let angleA = t * turns * 2 * .pi + drawPhase
            let angleB = angleA + .pi

            // Per-pair amplitude harmonic — "breathing" along the helix length
            let localAmp = amp * (0.92 + 0.08 * sin(time * 2.4 + Double(i) * 0.18))

            let yA = cy + cos(angleA) * localAmp
            let yB = cy + cos(angleB) * localAmp

            result.append(Particle(x: CGFloat(x), y: CGFloat(yA), depth: sin(angleA), pairIdx: i, strand: .a))
            result.append(Particle(x: CGFloat(x), y: CGFloat(yB), depth: sin(angleB), pairIdx: i, strand: .b))
        }
        return result
    }

    /// Maps audio level (0..1) to helix amplitude.
    /// audio is expected pre-clamped to [0, 1] by the caller.
    static func baseAmplitude(audio: Double, ampMax: Double, ampScale: Double) -> Double {
        ampMax * (ampScale + (1 - ampScale) * audio)
    }

    /// Evenly-spaced pair indices where rungs (cross-strand connectors) are drawn.
    static func rungIndices(rungs: Int, pairs: Int) -> [Int] {
        guard rungs > 0, pairs > 1 else { return [] }
        return (0..<rungs).map { r in
            let t = (Double(r) + 0.5) / Double(rungs)
            return Int((t * Double(pairs - 1)).rounded())
        }
    }

    /// Draws one helix frame into the given Canvas context.
    /// - audioLevel: smoothed audio amplitude, 0..1 (caller pre-smooths).
    static func render(
        into context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        audioLevel: Double,
        pairs: Int = 22,
        turns: Double = 2.4,
        rungs: Int = 6,
        ampScale: Double = 0.4,
        rFront: CGFloat = 1.7,
        rBack: CGFloat = 0.6
    ) {
        let cy = Double(size.height) / 2
        let helixSpan = Double(size.width) * 0.94

        // Cool ambient halo — drawn first, behind everything
        let haloCenter = CGPoint(x: size.width / 2, y: size.height / 2)
        let haloRadius = CGFloat(helixSpan) * 0.55
        let haloGradient = Gradient(stops: [
            .init(color: Color(red: 100/255, green: 130/255, blue: 165/255).opacity(0.06), location: 0),
            .init(color: Color(red:  60/255, green:  80/255, blue: 110/255).opacity(0.02), location: 0.6),
            .init(color: Color.clear, location: 1),
        ])
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(haloGradient, center: haloCenter, startRadius: 0, endRadius: haloRadius)
        )

        let ampMax = min(Double(size.height) * 0.42, 38)
        let baseAmp = baseAmplitude(audio: audioLevel, ampMax: ampMax, ampScale: ampScale)
        // Constant rate: render() is stateless (no cross-frame phase accumulation),
        // so an audio-varying multiplier makes phase (= time × rate) jump erratically
        // when audioLevel changes — time is huge (seconds since 2001).
        let phase = time * 0.4

        let raw = computeParticles(
            pairs: pairs, turns: turns, phase: phase,
            amp: baseAmp, helixSpan: helixSpan, cy: cy, time: time
        )

        // computeParticles centers x at origin; translate to canvas center
        let xCenter = size.width / 2
        let particles = raw.map {
            Particle(x: $0.x + xCenter, y: $0.y, depth: $0.depth, pairIdx: $0.pairIdx, strand: $0.strand)
        }

        // Back-to-front for correct occlusion
        let sorted = particles.sorted { $0.depth < $1.depth }

        // Rungs (cross-strand connectors) — drawn before particles so dots sit on top
        var pairLookup: [Int: (a: Particle, b: Particle)] = [:]
        for p in particles {
            var e = pairLookup[p.pairIdx] ?? (a: p, b: p)
            if p.strand == .a { e.a = p } else { e.b = p }
            pairLookup[p.pairIdx] = e
        }

        for idx in rungIndices(rungs: rungs, pairs: pairs) {
            guard let pair = pairLookup[idx] else { continue }
            let sep = abs(pair.a.y - pair.b.y)
            let sepNorm = min(1.0, Double(sep) / (baseAmp * 2))
            let rungAlpha = pow(sepNorm, 1.0) * 0.65
            guard rungAlpha >= 0.04 else { continue }

            let gradient = Gradient(stops: [
                .init(color: Color(red: 232/255, green: 236/255, blue: 242/255).opacity(rungAlpha), location: 0),
                .init(color: Color(red: 229/255, green: 9/255,   blue: 20/255).opacity(rungAlpha), location: 1),
            ])
            let shading = GraphicsContext.Shading.linearGradient(
                gradient,
                startPoint: CGPoint(x: pair.a.x, y: pair.a.y),
                endPoint: CGPoint(x: pair.b.x, y: pair.b.y)
            )
            var path = Path()
            path.move(to: CGPoint(x: pair.a.x, y: pair.a.y))
            path.addLine(to: CGPoint(x: pair.b.x, y: pair.b.y))
            context.stroke(path, with: shading, style: StrokeStyle(lineWidth: 0.85, lineCap: .round))
        }

        for p in sorted {
            let depthT = (p.depth + 1) / 2   // 0 = back, 1 = front
            let r = rBack + (rFront - rBack) * CGFloat(depthT)
            let alpha = 0.18 + depthT * 0.78

            let color: Color = p.strand == .a
                ? Color(red: 232/255, green: 236/255, blue: 242/255).opacity(alpha)
                : Color(red: 229/255, green: 9/255,   blue: 20/255).opacity(alpha)

            let rect = CGRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))

            if depthT > 0.5 {
                let hAlpha = (depthT - 0.5) * 1.1
                let hr = r * 0.35
                let hx = p.x - r * 0.25
                let hy = p.y - r * 0.3
                let hColor: Color = p.strand == .a
                    ? Color.white.opacity(hAlpha * 0.6)
                    : Color(red: 1.0, green: 200/255, blue: 200/255).opacity(hAlpha * 0.55)
                let hRect = CGRect(x: hx - hr, y: hy - hr, width: hr * 2, height: hr * 2)
                context.fill(Path(ellipseIn: hRect), with: .color(hColor))
            }
        }
    }
}

#if DEBUG
private struct HelixPreviewHarness: View {
    var audioLevel: Double
    var pairs: Int = 22
    var turns: Double = 2.4
    var rungs: Int = 6
    var ampScale: Double = 0.4
    var rFront: CGFloat = 1.7
    var rBack: CGFloat = 0.6

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                HelixGeometry.render(
                    into: &context, size: size, time: time, audioLevel: audioLevel,
                    pairs: pairs, turns: turns, rungs: rungs,
                    ampScale: ampScale, rFront: rFront, rBack: rBack
                )
            }
        }
    }
}

#Preview("Helix · production slim 96×38") {
    HelixPreviewHarness(audioLevel: 0.5)
        .frame(width: 96, height: 38)
        .background(Color(red: 10/255, green: 11/255, blue: 14/255))
}

#Preview("Helix · hero 760×160") {
    HelixPreviewHarness(audioLevel: 0.7, pairs: 40, turns: 3.2, rungs: 12,
                        ampScale: 0.45, rFront: 2.8, rBack: 0.9)
        .frame(width: 760, height: 160)
        .background(Color(red: 10/255, green: 11/255, blue: 14/255))
}
#endif
