import Foundation
import SwiftUI

/// Timeline-driven animation controller that cycles FloatingBarView through
/// a demo loop: recording (text flows in) -> processing -> done -> hidden -> repeat.
@Observable
@MainActor
final class DemoState {

    // MARK: FloatingBarState properties

    var barPhase: FloatingBarPhase = .hidden
    var segments: [TranscriptionSegment] = []
    @ObservationIgnored let audioLevel = AudioLevelMeter()
    var currentMode: ProcessingMode = .direct
    var recordingProvider: ASRProvider? { .cartesia }
    var recordingModelName: String? { "ink-2" }
    var feedbackMessage: String = L("已完成", "Done")
    var feedbackKind: FeedbackKind = .standard
    var processingFinishTime: Date?
    var recordingStartDate: Date?

    var transcriptionText: String {
        segments.map(\.text).joined()
    }
    var effectiveProcessingLabel: String {
        currentMode.processingLabel
    }

    // MARK: Private

    enum DemoMode {
        case quickLoop
        case appearancePreview
    }

    private(set) var demoMode: DemoMode = .quickLoop
    private var demoTask: Task<Void, Never>?
    private var audioTimer: Timer?

    // MARK: Demo Control

    /// Starts the auto-looping quick mode demo animation.
    func startQuickModeDemo() {
        stop()
        demoMode = .quickLoop
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOneCycle()
            }
        }
    }

    /// Starts a stable recording state with simulated audio for Appearance Preview.
    func startAppearancePreview(sampleText: String) {
        stop()
        demoMode = .appearancePreview
        segments = Self.makePreviewSegments(from: sampleText)
        recordingStartDate = Date()
        barPhase = .recording
        startAudioSimulation()
    }

    /// Starts a stable processing state for Appearance Preview.
    func startProcessingPreview() {
        stop()
        demoMode = .appearancePreview
        barPhase = .processing
        audioLevel.current = 0
    }

    /// Updates the sample text shown in Appearance Preview without resetting timers.
    func updateAppearancePreview(sampleText: String) {
        guard demoMode == .appearancePreview, barPhase == .recording else { return }
        segments = Self.makePreviewSegments(from: sampleText)
    }

    static func makePreviewSegments(from text: String) -> [TranscriptionSegment] {
        if text.contains("，") {
            let parts = text.components(separatedBy: "，")
            if parts.count >= 2 {
                let confirmed = parts.dropLast().joined(separator: "，") + "，"
                let active = parts.last ?? ""
                return [
                    TranscriptionSegment(text: confirmed, isConfirmed: true),
                    TranscriptionSegment(text: active, isConfirmed: false),
                ]
            }
        } else if text.contains(",") {
            let parts = text.components(separatedBy: ",")
            if parts.count >= 2 {
                let confirmed = parts.dropLast().joined(separator: ",") + ","
                let active = (parts.last ?? "").trimmingCharacters(in: .whitespaces)
                return [
                    TranscriptionSegment(text: confirmed + " ", isConfirmed: true),
                    TranscriptionSegment(text: active, isConfirmed: false),
                ]
            }
        }

        let count = text.count
        if count > 10 {
            let splitIndex = text.index(text.startIndex, offsetBy: Int(Double(count) * 0.55))
            let confirmed = String(text[..<splitIndex])
            let active = String(text[splitIndex...])
            return [
                TranscriptionSegment(text: confirmed, isConfirmed: true),
                TranscriptionSegment(text: active, isConfirmed: false),
            ]
        } else {
            return [TranscriptionSegment(text: text, isConfirmed: false)]
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
        demoMode = .quickLoop
    }

    // MARK: - One Demo Cycle

    private func runOneCycle() async {
        // 1. Recording: text flows in 3 segments
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

        // 2. Processing for 0.5s
        processingFinishTime = nil
        barPhase = .processing
        guard await sleep(0.5) else { return }

        // 3. Done "已完成" for 1.5s
        feedbackMessage = L("已完成", "Done")
        barPhase = .done
        guard await sleep(1.5) else { return }

        // 4. Hidden for 1.5s
        barPhase = .hidden
        segments = []
        recordingStartDate = nil
        guard await sleep(1.5) else { return }
    }

    // MARK: - Audio Simulation

    private var simulationStep: Double = 0

    private func startAudioSimulation() {
        stopAudioSimulation()
        simulationStep = 0
        audioTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.simulationStep += 0.05
                let wave1 = sin(self.simulationStep * 3.0) * 0.5 + 0.5
                let wave2 = sin(self.simulationStep * 7.2) * 0.2 + 0.5
                let energy = Float(wave1 * 0.7 + wave2 * 0.3) * 0.5 + 0.15
                self.audioLevel.current = max(0.15, min(0.65, energy))
            }
        }
    }

    private func stopAudioSimulation() {
        audioTimer?.invalidate()
        audioTimer = nil
        audioLevel.current = 0
        simulationStep = 0
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
    var pinsTranscriptPopup: Bool { false }
    var isQwen3OnlyMode: Bool { false }
    var activityKind: RecordingActivityKind { .standard }
    var latestReviseUndoTicketID: UUID? { nil }

    func performRecordingControlAction(_ action: RecordingControlAction) {
        guard barPhase == .preparing || barPhase == .recording else { return }
        guard demoMode == .quickLoop else { return }
        switch action {
        case .finish:
            barPhase = .processing
        case .cancel:
            feedbackMessage = L("已取消", "Cancelled")
            barPhase = .done
        }
    }

    func performReviseUndo() {}
}
