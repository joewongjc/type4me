import AudioToolbox
import SwiftUI
import UIKit

/// The buzz and click on each key press, like the system keyboard. Both
/// switches live in the app's Settings; the keyboard reads them each time it
/// appears.
@MainActor
enum KeyFeedback {
    enum Kind {
        case character, delete, modifier

        /// The system keyboard's own sounds; like it, they stay quiet when
        /// the ringer is switched to silent.
        var sound: SystemSoundID {
            switch self {
            case .character: 1104
            case .delete: 1155
            case .modifier: 1156
            }
        }
    }

    private static var haptics = SharedSettings.keyHaptics
    private static var sounds = SharedSettings.keySounds
    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let medium = UIImpactFeedbackGenerator(style: .medium)

    static func reload() {
        haptics = SharedSettings.keyHaptics
        sounds = SharedSettings.keySounds
        if haptics {
            light.prepare()
            medium.prepare()
        }
    }

    static func play(_ kind: Kind) {
        if haptics {
            // Character keys tap lighter than the keys around them.
            let generator = kind == .character ? light : medium
            generator.impactOccurred(intensity: kind == .character ? 0.6 : 0.8)
            generator.prepare()
        }
        if sounds { AudioServicesPlaySystemSound(kind.sound) }
    }
}

/// Plays the key feedback the moment a finger lands, as the system keyboard
/// does, rather than when the button's action fires on release.
struct KeyPressStyle: ButtonStyle {
    let feedback: KeyFeedback.Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { KeyFeedback.play(feedback) }
            }
    }
}

/// Fires on touch-down, then repeats while held: a pause, a steady rate, and
/// for delete a faster rate after a while, like the system keyboard.
struct KeyRepeat: ViewModifier {
    let feedback: KeyFeedback.Kind
    var accelerates = false
    let action: () -> Void

    @State private var timer: Timer?
    @State private var repeats = 0

    func body(content: Content) -> some View {
        content
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard timer == nil else { return }
                        fire()
                        repeats = 0
                        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                            MainActor.assumeIsolated { schedule(every: 0.08) }
                        }
                    }
                    .onEnded { _ in
                        timer?.invalidate()
                        timer = nil
                    }
            )
            .onDisappear {
                timer?.invalidate()
                timer = nil
            }
    }

    private func schedule(every interval: TimeInterval) {
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                fire()
                repeats += 1
                // About two seconds in, delete speeds up.
                if accelerates, repeats == 20 {
                    timer?.invalidate()
                    schedule(every: 0.04)
                }
            }
        }
    }

    private func fire() {
        KeyFeedback.play(feedback)
        action()
    }
}
