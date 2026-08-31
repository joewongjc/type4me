//
//  LiquidGlassText.swift
//  Type4Me
//

import QuartzCore
import SwiftUI

struct RecordingTextParts: Equatable {
    let confirmed: String
    let active: String

    static func build(
        segments: [TranscriptionSegment],
        defaultListeningText: String
    ) -> RecordingTextParts {
        if segments.isEmpty {
            return RecordingTextParts(confirmed: "", active: defaultListeningText)
        }
        let confirmedSegments = segments.filter(\.isConfirmed)
        let unconfirmedSegments = segments.filter { !$0.isConfirmed }

        let confirmedText = confirmedSegments.map(\.text).joined()
        if let lastUnconfirmed = unconfirmedSegments.last, !lastUnconfirmed.text.isEmpty {
            return RecordingTextParts(confirmed: confirmedText, active: lastUnconfirmed.text)
        } else {
            return RecordingTextParts(confirmed: confirmedText, active: "")
        }
    }
}

struct LiquidGlassText: View {
    let text: String
    let style: RecordingVisualStyle
    var theme: RecordingTheme = .dark
    var audioEnergy: Float = 0
    var font: Font = .system(size: 14, weight: .medium)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startTime: CFTimeInterval? = nil

    var body: some View {
        if style.isAnimated && !reduceMotion {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                let now = CACurrentMediaTime()
                styledText(time: now, energy: max(0.0, min(1.0, audioEnergy)))
            }
        } else {
            styledText(time: 0, energy: 0)
        }
    }

    private func styledText(time: CFTimeInterval, energy: Float) -> some View {
        let isAnimated = style.isAnimated && !reduceMotion

        // Fast metallic specular sheen with a 2-second interval between rounds
        // 0.55s swift sweep + 2.0s idle pause = 2.55s total cycle period
        let sweepDuration: Double = 0.55
        let idleInterval: Double = 2.0
        let cycleDuration: Double = sweepDuration + idleInterval

        let origin = startTime ?? time
        let relativeTime = max(0.0, time - origin)
        let elapsedInCycle = relativeTime.truncatingRemainder(dividingBy: cycleDuration)

        let isSweeping = isAnimated && (elapsedInCycle < sweepDuration)
        let glintWidth: CGFloat = 0.18
        let progress = isSweeping ? CGFloat(elapsedInCycle / sweepDuration) : 0.0
        let sweepGlowFactor = isSweeping ? max(0.0, sin(Double(progress) * .pi)) : 0.0

        let startPoint: UnitPoint
        let endPoint: UnitPoint

        if isSweeping {
            let phase = -0.30 + progress * 1.6
            startPoint = UnitPoint(x: Double(phase - glintWidth), y: 0.5)
            endPoint = UnitPoint(x: Double(phase + glintWidth), y: 0.5)
        } else {
            // Off-screen during the 2.0s idle period (text remains clean high-contrast silver at 0.70 opacity)
            startPoint = UnitPoint(x: -2.0, y: 0.5)
            endPoint = UnitPoint(x: -1.7, y: 0.5)
        }

        let textColor = theme == .light ? TF.floatingTextLight : Color.white.opacity(0.70)
        let gradientStops: [Gradient.Stop] = theme == .light ? [
            .init(color: textColor, location: 0.0),
            .init(color: textColor.opacity(0.75), location: 0.32),
            .init(color: Color.white, location: 0.50),
            .init(color: textColor.opacity(0.75), location: 0.68),
            .init(color: textColor, location: 1.0),
        ] : [
            .init(color: Color.white.opacity(0.70), location: 0.0),
            .init(color: Color.white.opacity(0.85), location: 0.35),
            .init(color: Color.white, location: 0.50),
            .init(color: Color.white.opacity(0.85), location: 0.65),
            .init(color: Color.white.opacity(0.70), location: 1.0),
        ]

        return Text(text)
            .font(font)
            .lineLimit(1)
            .foregroundStyle(
                LinearGradient(
                    stops: gradientStops,
                    startPoint: startPoint,
                    endPoint: endPoint
                )
            )
            .shadow(
                color: theme == .light
                    ? Color.white.opacity(sweepGlowFactor * (0.85 + Double(energy) * 0.15))
                    : Color.white.opacity(sweepGlowFactor * (0.30 + Double(energy) * 0.30)),
                radius: CGFloat(2.0 + energy * 1.5)
            )
            .onAppear {
                startTime = CACurrentMediaTime()
            }
            .onChange(of: text) { _, _ in
                startTime = CACurrentMediaTime()
            }
    }
}
