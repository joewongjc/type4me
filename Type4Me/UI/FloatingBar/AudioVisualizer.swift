import SwiftUI

/// Mini audio level visualizer: 4 bars that pulse with the audio level.
/// Uses .primary color to integrate with Liquid Glass vibrancy.
struct AudioVisualizer: View {

    let level: Float

    private let barCount = 4
    private let barWidth: CGFloat = 3.5
    private let barSpacing: CGFloat = 3
    private let maxHeight: CGFloat = 22
    private let minHeight: CGFloat = 5

    // Each bar has a different phase offset for organic movement
    private let phaseOffsets: [Double] = [0.0, 0.7, 1.4, 2.1]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    singleBar(index: index, time: time)
                }
            }
            .frame(height: maxHeight)
        }
    }

    private func singleBar(index: Int, time: Double) -> some View {
        let phase = phaseOffsets[index]
        // Primary wave + secondary harmonic for non-mechanical movement
        let wave = sin(time * 4.5 + phase * .pi) * 0.5 + 0.5
        let harmonic = sin(time * 7.2 + phase * 1.3) * 0.2 + 0.5
        let combined = (wave * 0.7 + harmonic * 0.3)

        let levelFactor = CGFloat(max(0.2, min(1.0, level)))
        let height = minHeight + (maxHeight - minHeight) * combined * levelFactor

        return RoundedRectangle(cornerRadius: barWidth / 2)
            .fill(.primary.opacity(0.5 + combined * 0.5))
            .frame(width: barWidth, height: height)
    }
}

// MARK: - Preview

#if canImport(PreviewsMacros)
#Preview("AudioVisualizer") {
    VStack(spacing: 20) {
        AudioVisualizer(level: 0.8)
        AudioVisualizer(level: 0.3)
        AudioVisualizer(level: 0.1)
    }
    .padding()
    .frame(width: 100, height: 120)
}
#endif
