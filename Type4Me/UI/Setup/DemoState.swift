import Foundation
import SwiftUI

/// Timeline-driven animation controller that cycles FloatingBarView through
/// a demo loop: preparing -> recording (text flows in) -> processing -> done -> hidden -> repeat.
@Observable
@MainActor
final class DemoState {

    // MARK: FloatingBarState properties

    var barPhase: FloatingBarPhase = .hidden
    var segments: [TranscriptionSegment] = []
    @ObservationIgnored let audioLevel = AudioLevelMeter()
    var currentMode: ProcessingMode = .direct
    var feedbackMessage: String = L("已完成", "Done")
    var processingFinishTime: Date?
    var recordingStartDate: Date?

    var transcriptionText: String {
        segments.map(\.text).joined()
    }
    var effectiveProcessingLabel: String {
        currentMode.processingLabel
    }

    // MARK: Private

    private var demoTask: Task<Void, Never>?
    private var audioTimer: Timer?

    // MARK: Demo Control

    /// Starts the auto-looping quick mode demo animation.
    func startQuickModeDemo() {
        stop()
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOneCycle()
            }
        }
    }

    /// Stops all timers and resets state.
    func stop() {
        demoTask?.cancel()
        demoTask = nil
        stopAudioSimulation()
        barPhase = .hidden
        segments = []
        audioLevel.current = 0
        recordingStartDate = nil
        processingFinishTime = nil
    }

    // MARK: - One Demo Cycle

    private func runOneCycle() async {
        // 1. Preparing (spinner dot) for 0.8s
        barPhase = .preparing
        guard await sleep(0.8) else { return }

        // 2. Recording: text flows in 3 segments
        segments = []
        audioLevel.current = 0
        recordingStartDate = Date()
        barPhase = .recording
        startAudioSimulation()

        let demoSegments = [
            L("今天下午三点", "Meeting at three"),
            L("今天下午三点开会讨论", "Meeting at three to discuss"),
            L("今天下午三点开会讨论新版本发布计划", "Meeting at three to discuss the new release plan"),
        ]

        for text in demoSegments {
            guard !Task.isCancelled else { return }
            segments = [TranscriptionSegment(text: text, isConfirmed: text == demoSegments.last)]
            guard await sleep(0.8) else { return }
        }

        stopAudioSimulation()

        // 3. Processing for 0.5s
        processingFinishTime = nil
        barPhase = .processing
        guard await sleep(0.5) else { return }

        // 4. Done "已完成" for 1.5s
        feedbackMessage = L("已完成", "Done")
        barPhase = .done
        guard await sleep(1.5) else { return }

        // 5. Hidden for 1.5s
        barPhase = .hidden
        segments = []
        recordingStartDate = nil
        guard await sleep(1.5) else { return }
    }

    // MARK: - Audio Simulation

    private func startAudioSimulation() {
        stopAudioSimulation()
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.audioLevel.current = Float.random(in: 0.15...0.5)
            }
        }
    }

    private func stopAudioSimulation() {
        audioTimer?.invalidate()
        audioTimer = nil
        audioLevel.current = 0
    }

    // MARK: - Helpers

    /// Returns false if cancelled during sleep.
    private func sleep(_ seconds: Double) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            return !Task.isCancelled
        } catch {
            return false
        }
    }
}

// MARK: - FloatingBarState Conformance

extension DemoState: FloatingBarState {
    var isQwen3OnlyMode: Bool { false }
}
