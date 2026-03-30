import AVFoundation
import Cocoa
import Speech

// The actual value of kAXTrustedCheckOptionPrompt.
// Accessed as a literal to avoid Swift 6 concurrency errors
// (kAXTrustedCheckOptionPrompt is an unmanaged global var).
private nonisolated(unsafe) let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt" as CFString

enum PermissionManager {

    static var hasMicrophonePermission: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    static var hasSpeechRecognitionPermission: Bool {
        SFSpeechRecognizer.authorizationStatus() == .authorized
    }

    static func requestSpeechRecognitionPermission() async -> Bool {
        let status = SFSpeechRecognizer.authorizationStatus()
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus == .authorized)
                }
            }
        default:
            return false
        }
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrustedWithOptions(
            [axTrustedCheckOptionPrompt: false] as CFDictionary
        )
    }

    static func promptAccessibilityPermission() {
        AXIsProcessTrustedWithOptions(
            [axTrustedCheckOptionPrompt: true] as CFDictionary
        )
    }

    static func openAccessibilitySettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    static func printPermissionStatus() {
        print("[Permissions] Microphone: \(hasMicrophonePermission ? "granted" : "NOT granted")")
        print("[Permissions] Speech Recognition: \(hasSpeechRecognitionPermission ? "granted" : "NOT granted")")
        print("[Permissions] Accessibility: \(hasAccessibilityPermission ? "granted" : "NOT granted")")
    }
}
