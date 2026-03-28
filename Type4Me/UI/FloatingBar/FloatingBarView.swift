import SwiftUI

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var feedbackMessage: String { get }
    var processingFinishTime: Date? { get }
    var transcriptionText: String { get }
    var recordingStartDate: Date? { get }
}

/// Dark-themed floating transcription bar with smooth morphing between states.
///
/// Design: single capsule container that animates width + content transitions.
/// - Recording: audio-reactive dot + live text + timer, breathing border
/// - Processing: rotating orb with breathing glow + "AI" badge
/// - Done: bouncing green dot with ripple + "OK" badge
struct FloatingBarView<S: FloatingBarState>: View {

    let state: S

    @State private var breathe = false
    @State private var doneGlow = true
    @State private var doneAppeared = false
    @State private var doneRipple = false
    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = TF.barHeight

    private var capsuleWidth: CGFloat {
        switch state.barPhase {
        case .preparing:
            return TF.barHeight
        case .recording:
            return state.segments.isEmpty ? TF.barHeight : recordingPeakWidth
        case .processing:
            return measureText(state.currentMode.processingLabel) + 66.0
        case .done:
            return feedbackWidth(for: state.feedbackMessage)
        case .error:
            return TF.barWidth
        case .hidden:
            return TF.barHeight
        }
    }

    var body: some View {
        Group {
            if state.barPhase != .hidden {
                capsuleBar
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.92).combined(with: .opacity),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(TF.springSnappy, value: state.barPhase != .hidden)
        .onChange(of: state.barPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: state.segments) { _, newSegments in
            guard state.barPhase == .recording else { return }
            let text = newSegments.map(\.text).joined()
            let textWidth = measureText(text)
            let needed = min(TF.barWidth, max(TF.barHeight, textWidth + 66.0))
            if needed > recordingPeakWidth {
                // Growing: fixed velocity 250pt/s
                let distance = needed - recordingPeakWidth
                let duration = max(0.12, Double(distance / 250.0))
                withAnimation(.linear(duration: duration)) {
                    recordingPeakWidth = needed
                }
            } else if recordingPeakWidth - needed > 30 {
                // Large correction (hotword etc.): allow shrink
                withAnimation(.easeInOut(duration: 0.2)) {
                    recordingPeakWidth = needed
                }
            }
        }
    }

    // MARK: - Capsule Container

    private var capsuleBar: some View {
        let cornerRadius: CGFloat = 14
        return barContent
            .animation(TF.springSnappy, value: state.barPhase)
            .frame(
                width: capsuleWidth,
                height: state.barPhase == .error ? nil : TF.barHeight
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .background {
                capsuleBackground
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            }
            .shadow(color: Color(white: 0.08, opacity: 0.5), radius: 5, x: 0, y: 0)
            .animation(TF.springSnappy, value: state.barPhase)
    }

    // MARK: - Content by Phase

    @ViewBuilder
    private var barContent: some View {
        switch state.barPhase {
        case .preparing:
            preparingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.92).combined(with: .opacity),
                    removal: .opacity
                ))
        case .recording:
            recordingContent
                .transition(.asymmetric(
                    insertion: .opacity,
                    removal: .scale(scale: 0.9, anchor: .leading).combined(with: .opacity)
                ))
        case .processing:
            processingContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .scale(scale: 0.9).combined(with: .opacity)
                ))
        case .done:
            doneContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.85).combined(with: .opacity),
                    removal: .opacity
                ))
        case .error:
            errorContent
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.9).combined(with: .opacity),
                    removal: .opacity
                ))
        case .hidden:
            EmptyView()
        }
    }

    private var preparingContent: some View {
        HStack(spacing: 0) {
            PreparingDot()
        }
        .frame(maxWidth: .infinity)
    }

    private var recordingContent: some View {
        HStack(spacing: 10) {
            // Module 1: dot (fixed position, 14pt from left edge)
            RecordingDot(meter: state.audioLevel)

            // Module 2: text container (fills remaining space, grows with frame)
            // Uses overlay so text sizing never affects HStack layout
            if !state.segments.isEmpty {
                Color.clear
                    .overlay(alignment: .trailing) {
                        Text(state.transcriptionText)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .mask {
                        if recordingPeakWidth >= TF.barWidth {
                            HStack(spacing: 0) {
                                LinearGradient(
                                    colors: [.clear, .white],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: 12)
                                Rectangle()
                            }
                        } else {
                            Rectangle()
                        }
                    }
                    .padding(.trailing, 4)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
    }

    private var processingContent: some View {
        ZStack {
            Text(state.currentMode.processingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var doneContent: some View {
        HStack(spacing: 10) {
            DoneDot(appeared: doneAppeared, ripple: doneRipple)

            Text(state.feedbackMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
    }

    private var errorContent: some View {
        HStack(alignment: .center, spacing: 10) {
            ErrorDot()

            Text(state.feedbackMessage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Background & Border

    private var capsuleBackground: some View {
        ZStack {
            Color(white: 0.08, opacity: 0.88)

            if state.barPhase == .recording {
                AudioRipple(meter: state.audioLevel)
                    .transition(.opacity)
            }

            if state.barPhase == .processing {
                ProcessingProgress(finishTime: state.processingFinishTime)
                    .transition(.opacity)
            }

            if state.barPhase == .done {
                LinearGradient(
                    colors: [TF.success.opacity(0.18), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
                .transition(.opacity)
            }

            if state.barPhase == .error {
                LinearGradient(
                    colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
                .transition(.opacity)
            }
        }
    }

    private var capsuleBorder: some View {
        Capsule()
            .stroke(borderColor, lineWidth: 1)
    }

    private var borderColor: Color {
        switch state.barPhase {
        case .preparing:
            .white.opacity(0.04)
        case .recording:
            .white.opacity(breathe ? 0.14 : 0.05)
        case .processing:
            .white.opacity(0.07)
        case .done:
            TF.success.opacity(doneGlow ? 0.3 : 0.08)
        case .error:
            TF.settingsAccentRed.opacity(0.22)
        case .hidden:
            .clear
        }
    }

    // MARK: - Phase Transitions

    private func handlePhaseChange(_ phase: FloatingBarPhase) {
        switch phase {
        case .preparing:
            recordingPeakWidth = TF.barHeight
            breathe = false
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        case .recording:
            recordingPeakWidth = TF.barHeight
            breathe = false
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                breathe = true
            }
        case .done:
            breathe = false
            doneGlow = true
            doneAppeared = false
            doneRipple = false
            withAnimation(TF.springBouncy) { doneAppeared = true }
            withAnimation(.easeOut(duration: 0.8)) { doneRipple = true }
            withAnimation(.easeOut(duration: 1.0)) { doneGlow = false }
        case .error:
            breathe = false
            doneGlow = false
            doneAppeared = false
            doneRipple = false
        default:
            breathe = false
        }
    }

    private func feedbackWidth(for message: String) -> CGFloat {
        measureText(message) + 66.0
    }

    /// Measure actual rendered width using the same font as the floating bar text.
    private func measureText(_ string: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 14, weight: .medium)
        return ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }
}

// MARK: - Recording Dot

struct PreparingDot: View {

    @State private var rotation = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(TF.recording.opacity(0.16), lineWidth: 1.6)
                .frame(width: 14, height: 14)

            Circle()
                .trim(from: 0.16, to: 0.76)
                .stroke(
                    TF.recording,
                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                )
                .frame(width: 14, height: 14)
                .rotationEffect(.degrees(rotation))
        }
        .frame(width: 24, height: 24)
        .onAppear {
            rotation = 0
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Recording Dot

/// Audio-reactive red dot with dual concentric pulse rings.
struct RecordingDot: View {

    let meter: AudioLevelMeter

    @State private var outerPulse = false
    @State private var innerPulse = false

    var body: some View {
        TimelineView(.animation) { _ in
            let level = CGFloat(max(0.05, min(1.0, meter.current)))
            let levelSize: CGFloat = 10 + level * 12

            ZStack {
                // Outer slow pulse ring
                Circle()
                    .fill(TF.recording.opacity(outerPulse ? 0.0 : 0.25))
                    .frame(width: outerPulse ? 24 : 10, height: outerPulse ? 24 : 10)

                // Audio-reactive ring (smooth following)
                Circle()
                    .fill(TF.recording.opacity(0.18))
                    .frame(width: levelSize, height: levelSize)

                // Inner faster pulse ring (offset phase)
                Circle()
                    .stroke(TF.recording.opacity(innerPulse ? 0.2 : 0.0), lineWidth: 1)
                    .frame(width: innerPulse ? 18 : 12, height: innerPulse ? 18 : 12)

                // Core dot
                Circle()
                    .fill(TF.recording)
                    .frame(width: 10, height: 10)
                    .shadow(color: TF.recording.opacity(0.4), radius: 3)
            }
        }
        .frame(width: 24, height: 24)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                outerPulse = true
            }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.15)) {
                innerPulse = true
            }
        }
    }
}

// MARK: - Processing Orb

/// Purple/blue gradient sphere with rotation + breathing glow.
struct ProcessingOrb: View {

    @State private var rotation: Double = 0
    @State private var breathe = false

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: [
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                        Color(red: 0.30, green: 0.55, blue: 1.00),
                        Color(red: 0.40, green: 0.30, blue: 0.90),
                    ],
                    center: .center,
                    startAngle: .degrees(rotation),
                    endAngle: .degrees(rotation + 360)
                )
            )
            .frame(width: 22, height: 22)
            .scaleEffect(breathe ? 1.08 : 0.95)
            .shadow(
                color: Color(red: 0.35, green: 0.35, blue: 0.90).opacity(breathe ? 0.6 : 0.3),
                radius: breathe ? 10 : 5
            )
            .onAppear {
                withAnimation(.linear(duration: 2.5).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    breathe = true
                }
            }
    }
}

// MARK: - Done Dot

/// Green dot with a bounce-in + expanding ripple ring.
struct DoneDot: View {

    let appeared: Bool
    let ripple: Bool

    var body: some View {
        ZStack {
            // Ripple ring: expands outward and fades
            Circle()
                .stroke(TF.success.opacity(ripple ? 0 : 0.5), lineWidth: 1.5)
                .frame(width: ripple ? 26 : 12, height: ripple ? 26 : 12)

            // Core dot with spring bounce
            Circle()
                .fill(TF.success)
                .frame(width: 12, height: 12)
                .scaleEffect(appeared ? 1.0 : 0.3)
                .shadow(color: TF.success.opacity(appeared ? 0.6 : 0), radius: appeared ? 8 : 0)
        }
        .frame(width: 24, height: 24)
    }
}

struct ErrorDot: View {

    var body: some View {
        ZStack {
            Circle()
                .fill(TF.settingsAccentRed.opacity(0.18))
                .frame(width: 16, height: 16)

            Text("!")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(TF.settingsAccentRed)
                .offset(y: -0.5)
        }
        .frame(width: 24, height: 24)
    }
}

// MARK: - Recording Timer

/// Shows elapsed time since recording started, updates every second.
struct RecordingTimer: View {

    let startDate: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let elapsed = startDate.map { timeline.date.timeIntervalSince($0) } ?? 0
            let minutes = Int(elapsed) / 60
            let seconds = Int(elapsed) % 60
            Text(String(format: "%02d:%02d", minutes, seconds))
        }
    }
}

// MARK: - Processing Progress

/// Particle progress bar: fills left→right to 90% in 1.5s, then waits.
/// When processingFinishTime is set, sprints to 100% in 0.3s.
struct ProcessingProgress: View {

    let finishTime: Date?
    @State private var startTime: Double = 0

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                if startTime == 0 { DispatchQueue.main.async { startTime = time } }
                let elapsed = time - startTime

                let progress: CGFloat
                if let finishTime {
                    // Sprint phase: 90% → 100% in 0.3s
                    let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
                    let sprintProgress = min(1.0, CGFloat(finishElapsed / 0.3))
                    let baseProgress = min(0.9, CGFloat(elapsed / 1.5) * 0.9)
                    progress = baseProgress + (1.0 - baseProgress) * sprintProgress
                } else {
                    // Cruise phase: 0% → 90% in 1.5s with ease-out, then hold
                    let t = min(1.0, CGFloat(elapsed / 1.5))
                    progress = t * 0.9 * (2.0 - t) // quadratic ease-out
                }

                let fillEdge = progress * size.width
                let center = size.height / 2

                var col = 0
                var xi: CGFloat = 0
                while xi <= size.width {
                    let nx = xi / size.width

                    // Color: white (left) → blue (right)
                    let t = min(1.0, max(0, nx))
                    let cr = 0.82 - t * 0.42
                    let cg = 0.85 - t * 0.25
                    let coreColor = Color(red: cr, green: cg, blue: 1.0)

                    // Density: filled region is dense, edge has a soft falloff
                    let distToEdge = fillEdge - xi
                    let edgeFade: CGFloat
                    if distToEdge > 20 {
                        edgeFade = 1.0  // fully filled
                    } else if distToEdge > 0 {
                        edgeFade = distToEdge / 20  // soft leading edge
                    } else if distToEdge > -15 {
                        edgeFade = max(0, (distToEdge + 15) / 15) * 0.3  // sparse scatter ahead
                    } else {
                        col += 1; xi += 2; continue
                    }

                    let count = Int(edgeFade * 200)
                    for j in 0..<count {
                        let h1 = hash(col, j)
                        let h2 = hash(col, j &+ 53)
                        let h3 = hash(col, j &+ 137)

                        // Scatter vertically, dense at center
                        let scatter = (h1 - 0.5) * 2
                        let py = center + scatter * abs(scatter) * size.height * 0.48

                        // Fade from center outward
                        let distFromCenter = abs(py - center)
                        let distFade = pow(max(0, 1.0 - distFromCenter / (size.height * 0.48)), 1.3)

                        // Twinkle
                        let freq = 3.0 + Double(h2) * 10.0
                        let twinkle = CGFloat(0.5 + 0.5 * sin(time * freq + Double(h3) * .pi * 2))

                        let op = Double(distFade * twinkle * edgeFade * 0.85)
                        guard op > 0.03 else { continue }

                        let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                        context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(op)))
                    }

                    col += 1
                    xi += 2
                }
            }
        }
        .drawingGroup()
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

// MARK: - Audio Ripple

/// Audio visualizer with three selectable styles:
/// - classic: two sine-wave stroke lines
/// - dual: particles clustered around two sine-wave spines
/// - timeline: scrolling level history, right = now
struct AudioRipple: View {

    let meter: AudioLevelMeter
    @AppStorage("tf_visualStyle") private var style = "timeline"
    @State private var smootherSlow = LevelSmoother(timeConstant: 0.8)
    @State private var smootherFast = LevelSmoother(timeConstant: 0)
    @State private var startTime: Double = 0
    @State private var levelTimeline = LevelTimeline()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                switch style {
                case "classic": drawClassicWaves(context: &context, size: size, time: time)
                case "dual": drawDualSpine(context: &context, size: size, time: time)
                default: drawTimeline(context: &context, size: size, time: time)
                }
            }
        }
        .drawingGroup()
    }

    // MARK: - Classic Waves (stroke lines only)

    private func drawClassicWaves(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let opacity = 0.4 + Double(amp) * 0.4

        for w in 0..<2 {
            let period: Double = w == 0 ? 130.0 : 90.0
            let speed: Double = w == 0 ? 1.0 : 0.7
            let phase: Double = w == 0 ? 0.0 : 1.3

            var path = Path()
            var first = true
            var xi: CGFloat = 0
            while xi <= size.width {
                let nx = Double(xi / size.width)
                let env = 0.07 + pow(nx, 1.5) * (0.10 + Double(amp))
                let y = center + CGFloat(sin(Double(xi) / period * .pi * 2 + time * speed * .pi + phase) * env) * maxAmp
                if first { path.move(to: CGPoint(x: xi, y: y)); first = false }
                else { path.addLine(to: CGPoint(x: xi, y: y)) }
                xi += 2
            }

            context.stroke(path, with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.82, green: 0.85, blue: 1.0).opacity(opacity * 0.7),
                    Color(red: 0.40, green: 0.60, blue: 1.0).opacity(opacity)
                ]),
                startPoint: CGPoint(x: 0, y: center),
                endPoint: CGPoint(x: size.width, y: center)
            ), lineWidth: 1.5)
        }
    }

    // MARK: - Dual Spine Particles

    private func drawDualSpine(context: inout GraphicsContext, size: CGSize, time: Double) {
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherSlow.target = max(0.012, rawLevel)
        let level = smootherSlow.update(time: time)
        let amp = min(1.0, pow(max(0, (level - 0.012) / 0.45), 0.7))
        let center = size.height / 2
        let maxAmp = size.height * (0.15 + amp * 0.35)
        let levelBright: CGFloat = 0.75 + amp * 0.25
        let bandHalf: CGFloat = size.height * (0.2 + amp * 0.3)

        var xi: CGFloat = 0
        var col = 0
        while xi <= size.width {
            let nx = xi / size.width
            let env = 0.07 + pow(Double(nx), 1.5) * (0.10 + Double(amp))
            let s1y = center + CGFloat(sin(Double(xi) / 130.0 * .pi * 2 + time * .pi) * env) * maxAmp
            let s2y = center + CGFloat(sin(Double(xi) / 90.0 * .pi * 2 + time * 0.7 * .pi) * env) * maxAmp
            let localAmp = (abs(s1y - center) + abs(s2y - center)) / 2
            let localIntensity = min(1.0, localAmp / max(maxAmp * 0.5, 1))
            let posBright: CGFloat = 0.6 + pow(nx, 0.8) * 0.4

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            let count = 160 + Int(localIntensity * 120)
            let posScale: CGFloat = 0.4 + pow(nx, 0.8) * 0.6
            let localBand = bandHalf * posScale * (0.5 + amp * 1.0)

            for j in 0..<count {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)
                let h5 = hash(col, j &+ 293)

                let spineY = h5 > 0.5 ? s1y : s2y
                let scatter = (h1 - 0.5) * 2
                let py = spineY + scatter * abs(scatter) * localBand

                let distFromSpine = abs(py - spineY)
                let normDist = distFromSpine / max(localBand, 1)
                let distFade: CGFloat = normDist < 0.25 ? 1.0 : max(0, 1.0 - (normDist - 0.25) / 0.75)

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * distFade * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }

            col += 1
            xi += 2
        }
    }

    // MARK: - Timeline Particles (scrolling history)

    private func drawTimeline(context: inout GraphicsContext, size: CGSize, time: Double) {
        if startTime == 0 { DispatchQueue.main.async { startTime = time } }
        let rawLevel = CGFloat(max(0.0, min(1.0, meter.current)))
        smootherFast.target = max(0.005, rawLevel)
        let smoothed = smootherFast.update(time: time)
        let levels = levelTimeline.update(time: time, currentLevel: smoothed)

        let center = size.height / 2
        let bufCount = levels.count
        let colCount = Int(size.width / 2) + 1

        for col in 0..<colCount {
            let xi = CGFloat(col) * 2
            let nx = xi / size.width

            let histIdx = min(Int(nx * CGFloat(bufCount - 1)), bufCount - 1)
            let histLevel = levels[histIdx]
            let amp = min(1.0, pow(max(0, (histLevel - 0.08) / 0.62), 0.85))

            let bandHalf = size.height * (0.03 + amp * 0.45)
            let posBright: CGFloat = 0.4 + pow(nx, 0.8) * 0.3
            let levelBright: CGFloat = 0.45 + amp * 0.35

            let cr: Double = 0.82 - Double(nx) * 0.42
            let cg: Double = 0.85 - Double(nx) * 0.25
            let coreColor = Color(red: cr, green: cg, blue: 1.0)

            for j in 0..<180 {
                let h1 = hash(col, j)
                let h2 = hash(col, j &+ 53)
                let h3 = hash(col, j &+ 137)

                let scatter = (h1 - 0.5) * 2
                let py = center + scatter * abs(scatter) * bandHalf

                let freq = 3.0 + Double(h2) * 10.0
                let twinkle: CGFloat = 0.45 + 0.55 * CGFloat(sin(time * freq + Double(h3) * .pi * 2))

                let baseOp = posBright * twinkle * levelBright
                guard baseOp > 0.02 else { continue }

                let dotR = CGRect(x: xi - 0.25, y: py - 0.25, width: 0.5, height: 0.5)
                context.fill(Circle().path(in: dotR), with: .color(coreColor.opacity(Double(min(1.0, baseOp)))))
            }
        }
    }

    private func hash(_ a: Int, _ b: Int) -> CGFloat {
        var h = a &* 374761393 &+ b &* 668265263
        h = (h ^ (h >> 13)) &* 1274126177
        h = h ^ (h >> 16)
        return CGFloat(abs(h) % 10000) / 10000.0
    }
}

/// Frame-rate-independent exponential smoothing for audio level.
private final class LevelSmoother {
    var current: CGFloat = 0
    var target: CGFloat = 0
    private var lastTime: Double = 0
    private let timeConstant: Double

    init(timeConstant: Double = 0.8) {
        self.timeConstant = timeConstant
    }

    func update(time: Double) -> CGFloat {
        if lastTime == 0 { lastTime = time; return current }
        let dt = min(time - lastTime, 0.05)
        lastTime = time
        if timeConstant <= 0 {
            current = target
        } else {
            let alpha = CGFloat(1.0 - exp(-dt / timeConstant))
            current += (target - current) * alpha
        }
        return current
    }
}

/// Scrolling level history: newest on right, drifts left over time.
/// Index 0 = oldest (leftmost), last = newest (rightmost).
private final class LevelTimeline {
    private static let bufferSize = 200
    private var levels: [CGFloat]
    private var lastTime: Double = 0
    private var accumulator: Double = 0
    private let scrollSpeed: Double = 50  // entries shifted per second

    init() {
        levels = Array(repeating: 0, count: Self.bufferSize)
    }

    func update(time: Double, currentLevel: CGFloat) -> [CGFloat] {
        if lastTime == 0 {
            lastTime = time
            return levels
        }
        let dt = min(time - lastTime, 0.05)
        lastTime = time

        accumulator += dt * scrollSpeed
        let shift = Int(accumulator)
        if shift > 0 {
            accumulator -= Double(shift)
            let actual = min(shift, Self.bufferSize)
            levels.removeFirst(actual)
            for _ in 0..<actual {
                levels.append(currentLevel)
            }
        }
        levels[levels.count - 1] = currentLevel
        return levels
    }
}
