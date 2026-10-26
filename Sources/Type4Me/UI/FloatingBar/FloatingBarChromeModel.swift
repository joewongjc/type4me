import Combine
import Foundation


/// What the floating bar looked like when its exit fade began.
struct FloatingBarExitSnapshot: Equatable {
    /// `FloatingBarController.panelGeneration` at capture time.
    let generation: Int
    let phase: FloatingBarPhase
    let segments: [TranscriptionSegment]
    let processingLabel: String
    let feedbackMessage: String
    let feedbackKind: FeedbackKind
    let activityKind: RecordingActivityKind
    let showsReviseUndo: Bool
    let pinsTranscriptPopup: Bool

    @MainActor
    static func capture(from state: AppState, generation: Int) -> FloatingBarExitSnapshot {
        let segments = (state.barPhase == .finishing && state.finishingSnapshotSegments != nil)
            ? state.finishingSnapshotSegments!
            : state.segments
        return FloatingBarExitSnapshot(
            generation: generation,
            phase: state.barPhase,
            segments: segments,
            processingLabel: state.effectiveProcessingLabel,
            feedbackMessage: state.feedbackMessage,
            feedbackKind: state.feedbackKind,
            activityKind: state.activityKind,
            showsReviseUndo: state.latestReviseUndoTicketID != nil,
            pinsTranscriptPopup: state.pinsTranscriptPopup
        )
    }
}
/// Coordinates UI chrome states (handle visibility, vertical anchor, drag status)
/// between FloatingBarController and FloatingBarView.
@MainActor
final class FloatingBarChromeModel: ObservableObject {
    @Published var verticalAnchor: FloatingBarVerticalAnchor = .bottom
    @Published private(set) var isHandleVisible = false
    @Published var isDragging = false {
        didSet {
            if isDragging {
                hideTask?.cancel()
                hideTask = nil
                isHandleVisible = true
            }
        }
    }
    @Published var snappedAxes: FloatingBarSnapAxes = []
    /// True only while a drag outlives its session.
    @Published var isRetainedForDrag = false
    @Published private(set) var exitSnapshot: FloatingBarExitSnapshot?

    func setExitSnapshot(_ snapshot: FloatingBarExitSnapshot?) {
        exitSnapshot = snapshot
    }

    private var hideTask: Task<Void, Never>?

    func setHovering(_ hovering: Bool) {
        hideTask?.cancel()
        hideTask = nil
        if hovering {
            isHandleVisible = true
        } else {
            guard !isDragging else { return }
            hideTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: TF.barPlacementHandleHideDelay)
                guard !Task.isCancelled, let self, !self.isDragging else { return }
                self.isHandleVisible = false
            }
        }
    }

    func cancelPendingHide() {
        hideTask?.cancel()
        hideTask = nil
    }

    func resetHover() {
        hideTask?.cancel()
        hideTask = nil
        guard !isDragging else { return }
        isHandleVisible = false
    }

    func forceHandleVisible(_ visible: Bool) {
        hideTask?.cancel()
        hideTask = nil
        isHandleVisible = visible
    }
}
