import SwiftUI

/// Audio sample captured for the scrolling waveform history.
private struct CompactWaveSample {
    let height: CGFloat
    let isActive: Bool
}

/// Helper model managing the rolling audio history buffer.
@MainActor
private final class CompactAudioHistoryModel {
    var samples: [CompactWaveSample] = []
    var lastSampleTime: TimeInterval = 0
    let sampleInterval: TimeInterval = 0.13
    let maxSamples: Int = 50

    func update(currentTime: TimeInterval, level: Float) -> CGFloat {
        if lastSampleTime == 0 {
            lastSampleTime = currentTime
        }

        let elapsed = currentTime - lastSampleTime
        if elapsed >= sampleInterval {
            let steps = Int(elapsed / sampleInterval)
            for _ in 0..<min(steps, 10) {
                let normalized = max(0.0, min(1.0, CGFloat(level)))
                let silenceThreshold: CGFloat = 0.045
                let sample: CompactWaveSample
                if normalized <= silenceThreshold {
                    sample = CompactWaveSample(height: TF.compactIndicatorWaveMinHeight, isActive: false)
                } else {
                    let effective = (normalized - silenceThreshold) / (1.0 - silenceThreshold)
                    let dynamicGain = min(1.0, pow(effective, 0.95) * 0.85)
                    let barHeight = TF.compactIndicatorWaveMinHeight + dynamicGain * (TF.compactIndicatorWaveMaxHeight - TF.compactIndicatorWaveMinHeight)
                    sample = CompactWaveSample(
                        height: min(TF.compactIndicatorWaveMaxHeight, max(3.0, barHeight)),
                        isActive: true
                    )
                }
                samples.insert(sample, at: 0)
                if samples.count > maxSamples {
                    samples.removeLast()
                }
            }
            lastSampleTime += Double(steps) * sampleInterval
        }

        let fraction = max(0.0, min(1.0, (currentTime - lastSampleTime) / sampleInterval))
        return CGFloat(fraction)
    }

    func reset() {
        samples.removeAll()
        lastSampleTime = 0
    }
}

/// Dynamic audio waveform indicator for the compact recording bar.
///
/// Features a right-to-left scrolling history track:
/// - Inactive track starts with 2pt quiescent dots.
/// - Active recording samples stream in from the right and scroll steadily to the left.
/// - Silence appears as 2pt dots (`TF.compactIndicatorInactive`).
/// - Audio volume elevates dots into vertical bars up to 18pt (`TF.compactIndicatorActive`).
/// - Past recorded audio preserves its waveform as it travels leftward.
struct CompactAudioIndicator: View {

    let meter: AudioLevelMeter
    var theme: RecordingTheme = .dark

    @State private var history = CompactAudioHistoryModel()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let fraction = history.update(currentTime: time, level: meter.current)

                let barWidth = TF.compactIndicatorWaveBarWidth
                let minHeight = TF.compactIndicatorWaveMinHeight
                let pitch: CGFloat = 4.5 // 2pt bar + 2.5pt spacing

                guard size.width >= barWidth else { return }

                let rightEdge = size.width - 1.0 - fraction * pitch
                let totalColumns = Int(ceil((size.width + pitch) / pitch)) + 1

                let activeColor = theme == .light ? TF.floatingTextLight : TF.compactIndicatorActive
                let inactiveColor = theme == .light ? Color.black.opacity(0.18) : TF.compactIndicatorInactive

                for i in 0..<totalColumns {
                    let x = rightEdge - CGFloat(i) * pitch
                    guard x >= -barWidth && x <= size.width else { continue }

                    let barHeight: CGFloat
                    let barColor: Color

                    if i < history.samples.count {
                        let sample = history.samples[i]
                        barHeight = sample.height
                        barColor = sample.isActive ? activeColor : inactiveColor
                    } else {
                        // Unreached / idle track dots
                        barHeight = minHeight
                        barColor = inactiveColor
                    }

                    let y = (size.height - barHeight) / 2
                    let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
                    let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
                    context.fill(path, with: .color(barColor))
                }
            }
        }
        .frame(height: TF.compactIndicatorHeight)
        .onDisappear {
            history.reset()
        }
    }
}
