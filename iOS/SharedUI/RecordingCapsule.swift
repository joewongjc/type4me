import QuartzCore
import SwiftUI

/// Floating-bar tokens copied from the Mac `TF` design system so the iPhone
/// recording UI reads as the same object.
enum Bar {
    static let background = Color(red: 17 / 255, green: 18 / 255, blue: 20 / 255) // #111214
    static let border = Color(red: 38 / 255, green: 39 / 255, blue: 41 / 255) // #262729
    static let text = Color.white
    static let textDim = Color.white.opacity(0.70)
    static let backgroundLight = Color(red: 246 / 255, green: 246 / 255, blue: 248 / 255)
    static let textLight = Color(red: 28 / 255, green: 28 / 255, blue: 30 / 255)
    static let amber = Color(red: 0.83, green: 0.57, blue: 0.24)
    static let success = Color(red: 0.42, green: 0.70, blue: 0.42)
    static let error = Color(red: 1.0, green: 0.55, blue: 0.49)
    static let recording = Color(red: 0.87, green: 0.38, blue: 0.30)

    static let cancelSize: CGFloat = 34
    static let font = Font.system(size: 15, weight: .medium)
    static let spring = Animation.spring(response: 0.3, dampingFraction: 1.0)
}

// MARK: - Theme

/// Mac `RecordingTheme`: dark is the floating-bar default, light is the
/// bright glass with near-black text.
enum RecordingTheme {
    case dark, light

    init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }

    var text: Color { self == .dark ? .white : Bar.textLight }
}

// MARK: - Shimmer text

/// Text with a fast specular sweep every 2.55 s: the Mac `LiquidGlassText`.
struct LiquidGlassText: View {
    let text: String
    var theme: RecordingTheme = .dark
    var energy: Float = 0
    var font: Font = Bar.font
    /// `nil` lets a long transcript wrap; the gradient sweeps every line.
    var lineLimit: Int? = 1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startTime: CFTimeInterval?

    var body: some View {
        Group {
            if reduceMotion {
                styled(time: 0, animated: false)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
                    styled(time: CACurrentMediaTime(), animated: true)
                }
            }
        }
        .onAppear { startTime = CACurrentMediaTime() }
        .onChange(of: text) { _, _ in startTime = CACurrentMediaTime() }
    }

    private func styled(time: CFTimeInterval, animated: Bool) -> some View {
        let sweep = 0.55
        let cycle = sweep + 2.0
        let elapsed = max(0, time - (startTime ?? time)).truncatingRemainder(dividingBy: cycle)
        let sweeping = animated && elapsed < sweep
        let progress = sweeping ? elapsed / sweep : 0
        let glow = sweeping ? max(0, sin(progress * .pi)) : 0
        let glint = 0.18
        let phase = -0.30 + progress * 1.6
        let start = sweeping ? UnitPoint(x: phase - glint, y: 0.5) : UnitPoint(x: -2, y: 0.5)
        let end = sweeping ? UnitPoint(x: phase + glint, y: 0.5) : UnitPoint(x: -1.7, y: 0.5)
        let e = Double(max(0, min(1, energy)))

        return Text(text)
            .font(font)
            .lineLimit(lineLimit)
            .foregroundStyle(LinearGradient(
                stops: theme == .dark ? [
                    .init(color: .white.opacity(0.70), location: 0),
                    .init(color: .white.opacity(0.85), location: 0.35),
                    .init(color: .white, location: 0.50),
                    .init(color: .white.opacity(0.85), location: 0.65),
                    .init(color: .white.opacity(0.70), location: 1),
                ] : [
                    .init(color: Bar.textLight, location: 0),
                    .init(color: Bar.textLight.opacity(0.75), location: 0.32),
                    .init(color: .white, location: 0.50),
                    .init(color: Bar.textLight.opacity(0.75), location: 0.68),
                    .init(color: Bar.textLight, location: 1),
                ],
                startPoint: start,
                endPoint: end
            ))
            .shadow(
                color: .white.opacity(glow * (theme == .dark ? 0.30 + e * 0.30 : 0.85 + e * 0.15)),
                radius: 2 + e * 1.5
            )
    }
}

// MARK: - Cancel button

/// Dark frosted glass ✕ from the Mac floating bar.
struct LiquidGlassCancelButton: View {
    var isPressed = false
    var size: CGFloat = Bar.cancelSize

    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(isPressed ? 0.45 : 0.38))
            Circle().fill(RadialGradient(
                colors: isPressed
                    ? [.white.opacity(0.55), .white.opacity(0.38), .white.opacity(0.22)]
                    : [.white.opacity(0.16), .white.opacity(0.08), .white.opacity(0.03)],
                center: UnitPoint(x: 0.35, y: 0.30),
                startRadius: 2,
                endRadius: size * 0.55
            ))
            Circle().strokeBorder(
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(isPressed ? 0.75 : 0.34), location: 0),
                        .init(color: .white.opacity(isPressed ? 0.45 : 0.16), location: 0.45),
                        .init(color: .white.opacity(isPressed ? 0.25 : 0.07), location: 1),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: isPressed ? 1 : 0.75
            )
            Ellipse()
                .fill(LinearGradient(
                    colors: [.white.opacity(isPressed ? 0.5 : 0.24), .white.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                ))
                .frame(width: size * 0.55, height: size * 0.22)
                .offset(x: -size * 0.08, y: -size * 0.22)
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: isPressed ? .bold : .semibold))
                .foregroundStyle(.white.opacity(isPressed ? 1 : 0.85))
                .shadow(color: .black.opacity(0.4), radius: 1, y: 0.5)
        }
        .frame(width: size, height: size)
        .scaleEffect(isPressed ? 1.10 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isPressed)
    }
}

// MARK: - Caption

/// What the recording caption is showing. Mirrors the Mac `FloatingBarPhase`
/// subset the iPhone needs.
enum RecordingCaptionPhase: Equatable {
    case recording(text: String, locked: Bool)
    case processing(text: String, label: String)
    case done(message: String)
    case error(message: String)
}

/// Caption tokens. The glow colours are the orb's own (see `MicButton`), so
/// the light reads as coming out of the button under the thumb.
enum Caption {
    static let font = Font.system(size: 17, weight: .medium)
    static let lineSpacing: CGFloat = 3
    static let lineHeight = UIFont.systemFont(ofSize: 17, weight: .medium).lineHeight
    /// The empty band between the keyboard's top edge and the orb. The first
    /// line sits in its middle; the text rolls once it reaches the bottom.
    static let height: CGFloat = 74
    static let topInset: CGFloat = 6
    static let sideInset: CGFloat = 28
    /// How long newly arrived characters take to come up to full ink.
    static let bloom: Double = 0.35
    /// Characters past the shared prefix that bloom at most, so a large ASR
    /// revision doesn't wash out the whole line.
    static let maxBloomCount = 12
    /// The glow hugs the orb rather than spreading across the keyboard.
    static let auraWidth: CGFloat = 260
    static let auraHeight: CGFloat = 140
    static let auraTop: CGFloat = 40

    // The orb's hues, washed towards white so the glow tints rather than
    // paints.
    static let violet = Color(red: 0.66, green: 0.56, blue: 1.0)
    static let pink = Color(red: 1.0, green: 0.66, blue: 0.85)
    static let cyan = Color(red: 0.60, green: 0.88, blue: 1.0)
    static let coolBlue = Color(red: 0.62, green: 0.77, blue: 1.0)
    static let lavender = Color(red: 0.80, green: 0.75, blue: 1.0)
}

/// The light the caption sits in, in place of a capsule. It glows softly
/// around the orb, without an edge: it breathes with the
/// voice while recording, cools while the text is processed and takes the
/// result's tint for done or error.
struct VoiceAura: View {
    let phase: RecordingCaptionPhase
    let level: Float

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    private var isProcessing: Bool {
        if case .processing = phase { return true }
        return false
    }

    var body: some View {
        let energy = CGFloat(max(0, min(1, level)))
        ZStack {
            pulsing(
                // The gradient reaches clear well inside the frame, so no
                // edge of the shape ever shows through the blur.
                Ellipse()
                    .fill(EllipticalGradient(stops: stops, center: UnitPoint(x: 0.5, y: 0.6), endRadiusFraction: 0.42))
                    .blur(radius: 22)
                    .scaleEffect(isRecording ? 0.97 + energy * 0.05 : 1, anchor: .bottom)
                    .opacity(baseOpacity + (isRecording ? Double(energy) * 0.15 : 0))
                    .animation(.easeOut(duration: 0.18), value: level)
            )
        }
        .animation(.easeInOut(duration: 0.35), value: stops)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pulsing(_ glow: some View) -> some View {
        if isProcessing && !reduceMotion {
            glow.phaseAnimator([1.0, 0.78]) { content, value in
                content.opacity(value)
            } animation: { _ in .easeInOut(duration: 1.6) }
        } else {
            glow
        }
    }

    private var baseOpacity: Double {
        switch phase {
        case .recording: return colorScheme == .dark ? 0.34 : 0.30
        case .processing: return 0.28
        case .done, .error: return 0.24
        }
    }

    private var stops: [Gradient.Stop] {
        switch phase {
        case .recording:
            return [
                .init(color: Caption.violet.opacity(0.70), location: 0),
                .init(color: Caption.pink.opacity(0.40), location: 0.42),
                .init(color: Caption.cyan.opacity(0.25), location: 0.68),
                .init(color: Caption.cyan.opacity(0), location: 1),
            ]
        case .processing:
            return [
                .init(color: Caption.coolBlue.opacity(0.65), location: 0),
                .init(color: Caption.lavender.opacity(0.35), location: 0.5),
                .init(color: Caption.lavender.opacity(0), location: 1),
            ]
        case .done:
            return [
                .init(color: Bar.success.opacity(0.60), location: 0),
                .init(color: Bar.success.opacity(0), location: 1),
            ]
        case .error:
            return [
                .init(color: Bar.error.opacity(0.60), location: 0),
                .init(color: Bar.error.opacity(0), location: 1),
            ]
        }
    }
}

/// The live transcript without a container. The first line appears in the
/// middle of the band above the orb and the next one below it; from then on
/// the newest line stays on the bottom line and earlier lines glide up and
/// fade instead of jumping. The lines can be scrolled back while
/// recording or processing; once scrolled up, new words no longer pull the
/// view down until it is scrolled back to the bottom. Newly arrived
/// characters come up from faint to full ink, so the eye finds the end of
/// the sentence.
struct RecordingCaption: View {
    let phase: RecordingCaptionPhase
    let meter: AudioLevelMeter

    @Environment(\.colorScheme) private var colorScheme

    private var theme: RecordingTheme { RecordingTheme(colorScheme) }

    var body: some View {
        ZStack {
            // One branch for recording and processing, so the scroll
            // position carries over when the words start processing.
            if let transcript {
                TranscriptRoll(text: transcript.text, processing: transcript.processing, theme: theme)
                    .transition(.opacity)
            } else {
                switch phase {
                case .recording:
                    LiquidGlassText(text: L("倾听中", "Listening"), theme: theme, energy: meter.current)
                        .transition(.opacity)
                case .processing(_, let label):
                    LiquidGlassText(text: label, theme: theme, energy: 0.25)
                        .transition(.opacity)
                case .done(let message):
                    feedback(message, symbol: "checkmark.circle.fill", tint: Bar.success)
                        .transition(.blurReplace)
                case .error(let message):
                    feedback(message, symbol: "exclamationmark.circle.fill", tint: Bar.error)
                        .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Caption.height)
        .padding(.horizontal, Caption.sideInset)
        // Keyed on the kind of content, not the text: streaming partials
        // swap in place, and a crossfade would ghost every one of them.
        .animation(.easeInOut(duration: 0.18), value: kind)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var transcript: (text: String, processing: Bool)? {
        switch phase {
        case .recording(let text, _) where !text.isEmpty: return (text, false)
        case .processing(let text, _) where !text.isEmpty: return (text, true)
        default: return nil
        }
    }

    private func feedback(_ message: String, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(Bar.font)
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.85)
        }
    }

    private var kind: Int {
        switch phase {
        case .recording(let text, _): return text.isEmpty ? 0 : 1
        case .processing(let text, _): return text.isEmpty ? 2 : 3
        case .done: return 4
        case .error: return 5
        }
    }

    private var accessibilityText: String {
        switch phase {
        case .recording(let text, _): return text.isEmpty ? L("倾听中", "Listening") : text
        case .processing(let text, let label): return text.isEmpty ? label : "\(label)：\(text)"
        case .done(let message), .error(let message): return message
        }
    }
}

/// The scrolling stack of transcript lines, anchored on the newest one.
private struct TranscriptRoll: View {
    let text: String
    let processing: Bool
    let theme: RecordingTheme

    @State private var position = ScrollPosition(edge: .bottom)
    /// Whether new lines scroll into view. Off while the user has scrolled
    /// back to read; on again once they return to the bottom.
    @State private var following = true
    @State private var atBottom = true

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if processing {
                    LiquidGlassText(text: text, theme: theme, energy: 0.25, font: Caption.font, lineLimit: nil)
                } else {
                    BloomingText(text: text, color: theme.text)
                }
            }
            .font(Caption.font)
            .lineSpacing(Caption.lineSpacing)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            // Room above the first line, so it starts in the middle of the
            // band and lines on screen never re-lay out: they only scroll.
            .padding(.top, (Caption.height - Caption.lineHeight) / 2)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { old, new in
                guard new > old + 0.5, following else { return }
                withAnimation(.easeOut(duration: 0.3)) { position.scrollTo(edge: .bottom) }
            }
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .scrollIndicators(.hidden)
        // The iOS 26 soft edge effect blurs the text near the edge and draws
        // hard vertical seams at the scroll view's sides; the mask below
        // does the fading instead.
        .scrollEdgeEffectHidden(true, for: .all)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentSize.height - geometry.visibleRect.maxY < 6
        } action: { _, value in
            atBottom = value
        }
        .onScrollPhaseChange { old, new in
            switch new {
            case .interacting:
                following = false
            // Any settle, including a bounce back after dragging content
            // that fits: follow again only if the bottom is in view.
            case .idle where old != .idle:
                following = atBottom
            default:
                break
            }
        }
        .mask {
            // The two newest lines at full ink, the one rolling out above them
            // fading away. Scrolled back, the bottom edge fades too, to show
            // more below.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.35), location: 0.12),
                    .init(color: .black, location: 0.34),
                    .init(color: .black, location: atBottom ? 1 : 0.9),
                    .init(color: .black.opacity(atBottom ? 1 : 0.4), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .animation(.easeOut(duration: 0.2), value: atBottom)
        }
    }
}

/// Text whose newest characters fade up to full ink as they arrive.
private struct BloomingText: View {
    let text: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settledCount = Int.max
    @State private var arrivedAt = Date.distantPast
    @State private var blooming = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !blooming)) { context in
            let progress = min(1, max(0, context.date.timeIntervalSince(arrivedAt) / Caption.bloom))
            let split = text.index(text.startIndex, offsetBy: min(settledCount, text.count))
            let settled = Text(verbatim: String(text[..<split])).foregroundStyle(color)
            let fresh = Text(verbatim: String(text[split...])).foregroundStyle(color.opacity(0.3 + 0.7 * progress))
            Text("\(settled)\(fresh)")
        }
        .onChange(of: text) { old, new in
            guard !reduceMotion else { return }
            settledCount = max(old.commonPrefix(with: new).count, new.count - Caption.maxBloomCount)
            arrivedAt = .now
            blooming = true
        }
        .task(id: arrivedAt) {
            try? await Task.sleep(for: .seconds(Caption.bloom + 0.05))
            if !Task.isCancelled { blooming = false }
        }
    }
}

/// Plain button style that reports its pressed state, for glass buttons that
/// draw their own press response.
struct PressReportingStyle: ButtonStyle {
    @Binding var pressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, value in pressed = value }
    }
}
