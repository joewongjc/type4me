import Combine
import Foundation

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

    func forceHandleVisible(_ visible: Bool) {
        hideTask?.cancel()
        hideTask = nil
        isHandleVisible = visible
    }
}
