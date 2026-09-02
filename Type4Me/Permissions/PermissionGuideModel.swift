import AppKit
import AVFoundation
import Speech
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

    /// Speech recognition authorization (optional, used when Apple Speech ASR is selected).
    var speechGranted: Bool = false

    /// True if the currently selected ASR provider is Apple Speech.
    var isAppleASRSelected: Bool = false

    /// True when Accessibility is granted by TCC, but the kernel-level event tap
    /// fails and requires an application relaunch to activate global hotkeys.
    var needsRestart: Bool = false

    /// True while the drag overlay is visible.
    var isDragOverlayShown: Bool = false

    /// Computed requirement: both Microphone and Accessibility must be granted.
    var requiredPermissionsGranted: Bool {
        micGranted && accessibilityGranted
    }

    // MARK: - Injected Probes & Callbacks

    /// Real event-tap probe provided by AppDelegate/HotkeyManager.
    var hotkeyProbe: (() -> Bool)?

    /// Origin-aware host raise callback (distinguishes embedded wizard vs standalone guide window).
    var onFlowCompleteOrRaise: (() -> Void)?

    // MARK: - Dependencies

    private let dragOverlay = PermissionDragOverlayController()
    private var appActiveObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    init() {
        refresh()
        observeAppActivation()
    }

    // MARK: - Public API

    func refresh() {
        micGranted = PermissionManager.hasMicrophonePermission
        accessibilityGranted = PermissionManager.hasAccessibilityPermission
        speechGranted = PermissionManager.hasSpeechRecognitionPermission
        isAppleASRSelected = (KeychainService.selectedASRProvider == .apple)

        if accessibilityGranted {
            if let probe = hotkeyProbe {
                let tapOk = probe()
                needsRestart = !tapOk
            } else {
                needsRestart = false
            }
        } else {
            needsRestart = false
        }
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

    /// Request Speech Recognition access (for Apple Speech ASR).
    func requestSpeechRecognition() {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            speechGranted = true
        case .notDetermined:
            Task { @MainActor in
                let granted = await PermissionManager.requestSpeechRecognitionPermission()
                self.speechGranted = granted
            }
        case .denied, .restricted:
            if let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
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
    /// true, we dismiss the overlay, refresh state, and bring the host
    /// window back to the front.
    func beginAccessibilityFlow(hostRaiseCallback: (() -> Void)? = nil) {
        if let hostRaiseCallback {
            self.onFlowCompleteOrRaise = hostRaiseCallback
        }
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
                if let raise = self.onFlowCompleteOrRaise {
                    raise()
                } else {
                    AppDelegate.openPermissionGuideAction?()
                }
            }
        }
    }

    func dismissDragOverlay() {
        dragOverlay.dismiss()
        isDragOverlayShown = false
    }

    /// Relaunches the application to refresh macOS kernel-level event tap permissions.
    /// Executes optional persistence logic (such as marking setup complete) before spawning.
    func relaunchApp(persistSetup: (() -> Void)? = nil) {
        persistSetup?()
        let url = Bundle.main.bundleURL
        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", url.path]
        try? task.run()
        NSApp.terminate(nil)
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
