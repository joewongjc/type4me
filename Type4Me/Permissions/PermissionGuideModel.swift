import AppKit
import AVFoundation
import Observation

/// Coordinates the state + side-effects of the unified permission guide
/// window. Owned by `AppDelegate` so the window can be closed and re-opened
/// without losing state (SwiftUI Window scenes re-instantiate views on each
/// open). The guide window and the setup wizard both bind to this model.
@MainActor
@Observable
final class PermissionGuideModel {

    // MARK: - Observable State

    /// Microphone authorization — the standard system prompt handles first-
    /// time grant; a denied state sends the user to Settings.
    var micGranted: Bool = false

    /// Whether the app has Accessibility (`AXIsProcessTrusted`). The
    /// drag-to-authorize flow always offers the same CTA regardless of
    /// whether the user has a stale entry from a previous install —
    /// macOS accepts a fresh drop even when a conflicting entry exists.
    var accessibilityGranted: Bool = false

    /// True while the drag overlay is visible.
    var isDragOverlayShown: Bool = false

    // MARK: - Dependencies

    private let dragOverlay = PermissionDragOverlayController()
    private var appActiveObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    // Lifetime is pinned to AppDelegate, so we don't clean up the activation
    // observer on deinit (which would need @MainActor hops under Swift 6).

    init() {
        refresh()
        observeAppActivation()
    }

    // MARK: - Public API

    func refresh() {
        micGranted = PermissionManager.hasMicrophonePermission
        accessibilityGranted = PermissionManager.hasAccessibilityPermission
    }

    /// Request microphone access via the standard system prompt. If the user
    /// previously denied, macOS won't re-prompt — open Settings instead.
    func requestMicrophone() {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            micGranted = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                Task { @MainActor in
                    self?.micGranted = granted
                }
            }
        case .denied, .restricted:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
            ) {
                NSWorkspace.shared.open(url)
            }
        @unknown default:
            break
        }
    }

    /// Open System Settings to Accessibility and surface the drag overlay
    /// pinned under its window.
    ///
    /// When the overlay's poll detects `AXIsProcessTrusted()` flipping to
    /// true (i.e. the drop landed and TCC granted the permission), we
    /// dismiss the overlay, refresh state, and **bring the main guide
    /// window back to the front** so the user lands on an obvious "next
    /// step" surface instead of being stranded inside System Settings.
    func beginAccessibilityFlow() {
        PermissionManager.openAccessibilitySettings()
        isDragOverlayShown = true
        dragOverlay.show(
            appName: "Type4Me",
            permissionName: L("辅助功能", "Accessibility")
        ) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.isDragOverlayShown = false
                self.refresh()
                NSApp.activate(ignoringOtherApps: true)
                // Re-invoking the SwiftUI openWindow action for an already-
                // open Window scene raises it to the front. If the user
                // closed the guide window mid-flow, this reopens it.
                AppDelegate.openPermissionGuideAction?()
            }
        }
    }

    func dismissDragOverlay() {
        dragOverlay.dismiss()
        isDragOverlayShown = false
    }

    // MARK: - Helpers

    private func observeAppActivation() {
        appActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }
}
