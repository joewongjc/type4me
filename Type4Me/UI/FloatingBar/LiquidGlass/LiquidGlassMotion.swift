//
//  LiquidGlassMotion.swift
//  Type4Me
//

import Foundation

struct LiquidGlassMotion: Equatable, Sendable {
    let time: TimeInterval
    let energy: Float
    let isAnimated: Bool

    static let staticFallback = LiquidGlassMotion(time: 0, energy: 0, isAnimated: false)

    static func active(
        time: TimeInterval,
        rawEnergy: Float,
        isAnimated: Bool,
        reduceMotion: Bool
    ) -> LiquidGlassMotion {
        guard isAnimated, !reduceMotion else {
            return staticFallback
        }
        let clamped = max(0.0, min(1.0, rawEnergy))
        return LiquidGlassMotion(time: time, energy: clamped, isAnimated: true)
    }
}

// MARK: - Speech Envelope

/// Turns the raw microphone meter into the two motion signals the orb needs.
///
/// The orb has two very different jobs. It must settle into a designed resting
/// pose whenever nobody is talking, and it must feel alive per syllable while
/// somebody is. A single smoothed level cannot do both: fast enough to track a
/// syllable is also fast enough to flicker between words. So the envelope
/// exposes two followers over the same gated signal.
///
/// - `activity` is slow and hysteretic. It decides *whether* the orb is awake,
///   and drives the pose morph and the flow speed.
/// - `transient` is fast. It decides *how hard* the orb is being pushed right
///   now, and drives scale, outline deformation and exposure.
///
/// The gate rides an adaptive noise floor instead of a fixed threshold, so a
/// quiet room and a noisy room both end up with the orb still at rest.
struct OrbSpeechEnvelope: Equatable, Sendable {

    // MARK: Tuning

    /// The floor creeps upward slowly so sustained speech never raises it, but
    /// drops quickly so the orb re-arms as soon as a room goes quiet. Real
    /// speech dips to ambient between words, which is what keeps the fast fall
    /// rate anchored on the room rather than on the voice.
    static let noiseFloorRiseRate: Float = 0.30
    static let noiseFloorFallRate: Float = 1.8
    /// Right after recording starts there is no history to work from, so the
    /// floor latches onto the room quickly for a moment. Levels above
    /// `warmupSpeechGuard` are assumed to be a voice and are excluded, so
    /// talking immediately cannot calibrate the room to your own volume.
    static let warmupDuration: Float = 0.4
    static let warmupFloorRate: Float = 8.0
    static let warmupSpeechGuard: Float = 0.32
    /// Never let the adaptive floor climb high enough to swallow real speech.
    static let noiseFloorCeiling: Float = 0.30
    static let noiseFloorInitial: Float = 0.04

    /// Hysteresis: it takes more level to wake the orb than to keep it awake.
    static let openMargin: Float = 0.10
    static let closeMargin: Float = 0.055

    /// Bridges the gaps between words so one sentence reads as one gesture.
    static let holdDuration: Float = 0.13

    static let activityAttackRate: Float = 11.0
    static let activityReleaseRate: Float = 9.0
    static let transientAttackRate: Float = 26.0
    static let transientReleaseRate: Float = 8.5

    /// `flux` measures how fast the level is *changing*, not how loud it is —
    /// rapid, percussive speech agitates the fluid more than a held vowel at
    /// the same volume. Averaged over ~170ms so it reads syllable rate rather
    /// than waveform.
    static let fluxFollowRate: Float = 6.0
    /// Level change per second that counts as fully agitated speech.
    static let fluxReference: Float = 3.0

    /// Below this the orb is declared visually asleep and snaps to exact zero,
    /// so silence is genuinely still rather than drifting at a fraction of a
    /// percent forever. It sits at `livenessLow`, where the pose morph has
    /// already bottomed out and nothing on screen is moving anyway.
    static let idleEpsilon: Float = 0.02

    /// The resting drift rate, as a fraction of the flow at conversational
    /// volume. Low enough that nothing appears to react, high enough that the
    /// orb is visibly a liquid rather than a screenshot.
    /// A visible but unhurried drift — a lava lamp, not a reaction. Speech
    /// runs this up by roughly thirteen times.
    static let idlePhaseVelocity: Float = 0.42

    /// How much `activity` counts as fully awake. A whisper lands part-way up
    /// and gets a correspondingly partial response.
    static let livenessLow: Float = 0.05
    static let livenessHigh: Float = 0.45

    /// The pose morph runs on its own, much slower follower than the reactive
    /// signals. Two things depend on this being sluggish: the transition from
    /// resting to speaking has to ease rather than snap, and a brief weak sound
    /// must not be able to drive the pose far enough to be seen as a flash.
    static let poseAttackRate: Float = 5.0
    static let poseReleaseRate: Float = 3.2

    // MARK: State

    private(set) var noiseFloor: Float = OrbSpeechEnvelope.noiseFloorInitial
    private(set) var activity: Float = 0
    private(set) var transient: Float = 0
    private(set) var phase: Float = 0
    private var fluxFollower: Float = 0
    private var previousLevel: Float = 0
    private var pose: Float = 0
    private(set) var isGateOpen: Bool = false
    private(set) var holdRemaining: Float = 0
    private(set) var warmupRemaining: Float = OrbSpeechEnvelope.warmupDuration

    init() {}

    var openThreshold: Float { min(0.92, noiseFloor + Self.openMargin) }
    var closeThreshold: Float { min(0.90, noiseFloor + Self.closeMargin) }

    /// 0 at rest, 1 while speaking. Blends every uniform between the resting
    /// pose and the live pose. Eased on both ends: the raw follower is already
    /// exponential, and the smoothstep adds the ease-in the start of a phrase
    /// needs so the orb swells into motion instead of snapping into it.
    var liveness: Float {
        Self.smoothstep(0.0, 1.0, pose)
    }

    /// 1 at rest. Convenience inverse of `liveness`.
    var idleBlend: Float { 1.0 - liveness }

    /// 0...1 agitation from how quickly the voice is modulating. Gated by
    /// `liveness` so a silent room's meter noise cannot register as fast speech.
    var flux: Float {
        min(1.0, fluxFollower / Self.fluxReference) * liveness
    }

    /// The per-syllable push, gated by the slow pose so that a faint or
    /// momentary sound can never produce a visible pulse. This is what stops
    /// the orb flickering at a voice too quiet to properly wake it.
    var punch: Float { transient * liveness }

    /// A resting orb is not frozen — a dead still frame reads as a hung app —
    /// but it drifts an order of magnitude slower than it flows under a voice.
    ///
    /// The idle motion is deliberately the fluid field's own aperiodic drift
    /// rather than a breathing scale or glow. Apple's Motion guidance calls out
    /// sustained oscillations near 0.2 Hz (one cycle per five seconds) as the
    /// uncomfortable band, and a slow "breathing" orb lands squarely in it.
    /// Domain-warped noise has no such frequency to sit on.
    var phaseVelocity: Float {
        Self.idlePhaseVelocity
            + activity * (1.3 + 2.4 * activity)
            + 1.3 * flux
    }

    // MARK: Update

    /// Advances the envelope by one render frame.
    /// - Parameters:
    ///   - rawLevel: the microphone meter, already normalised to 0...1.
    ///   - deltaTime: seconds since the previous frame.
    ///   - motionScale: per-preset speed character folded into the phase.
    mutating func advance(rawLevel: Float, deltaTime: Float, motionScale: Float) {
        let dt = max(0.0, min(0.05, deltaTime))
        let level = max(0.0, min(1.0, rawLevel))

        updateNoiseFloor(level: level, dt: dt)
        updateFlux(level: level, dt: dt)
        warmupRemaining = max(0.0, warmupRemaining - dt)
        updateGate(level: level, dt: dt)

        let drive = gatedDrive(level: level)
        // While the hold is running the envelope refuses to fall, which is what
        // keeps a pause inside a sentence from making the orb stutter.
        let sustaining = holdRemaining > 0
        let activityTarget = sustaining ? max(drive, activity) : drive
        let transientTarget = sustaining ? max(drive, transient * 0.9) : drive

        activity = Self.follow(
            current: activity,
            target: activityTarget,
            dt: dt,
            attackRate: Self.activityAttackRate,
            releaseRate: Self.activityReleaseRate
        )
        transient = Self.follow(
            current: transient,
            target: transientTarget,
            dt: dt,
            attackRate: Self.transientAttackRate,
            releaseRate: Self.transientReleaseRate
        )

        pose = Self.follow(
            current: pose,
            target: Self.smoothstep(Self.livenessLow, Self.livenessHigh, activity),
            dt: dt,
            attackRate: Self.poseAttackRate,
            releaseRate: Self.poseReleaseRate
        )

        phase += dt * phaseVelocity * max(0.0, motionScale)
    }

    /// Returns the orb to its resting pose without a transition. Used when the
    /// surface goes static (Reduce Motion, static preset, recording stopped).
    mutating func reset() {
        noiseFloor = Self.noiseFloorInitial
        activity = 0
        transient = 0
        isGateOpen = false
        holdRemaining = 0
        fluxFollower = 0
        previousLevel = 0
        pose = 0
        warmupRemaining = Self.warmupDuration
    }

    // MARK: Internals

    /// The meter arrives at ~20Hz while this runs at 60-120Hz, so most frames
    /// see no change at all. Low-passing `|delta| / dt` rather than `|delta|`
    /// makes the estimate independent of how often either side ticks.
    private mutating func updateFlux(level: Float, dt: Float) {
        guard dt > 0 else { return }
        let rate = abs(level - previousLevel) / dt
        previousLevel = level
        fluxFollower += (rate - fluxFollower) * min(1.0, dt * Self.fluxFollowRate)
        fluxFollower = max(0.0, fluxFollower)
    }

    private mutating func updateNoiseFloor(level: Float, dt: Float) {
        // Once speech has opened the gate (and while its inter-word hold is
        // active), never learn a louder level as room noise. Otherwise a
        // sustained soft phrase slowly pulls the floor upward until the gate
        // closes on the speaker. We still allow a downward correction so a
        // quieter room is picked up immediately between words.
        if isGateOpen || holdRemaining > 0 {
            guard level < noiseFloor else { return }
            noiseFloor += (level - noiseFloor)
                * min(1.0, dt * Self.noiseFloorFallRate)
            noiseFloor = max(0.0, min(Self.noiseFloorCeiling, noiseFloor))
            return
        }

        let isCalibrating = warmupRemaining > 0 && level < Self.warmupSpeechGuard
        let rate = isCalibrating
            ? Self.warmupFloorRate
            : (level > noiseFloor ? Self.noiseFloorRiseRate : Self.noiseFloorFallRate)
        noiseFloor += (level - noiseFloor) * min(1.0, dt * rate)
        noiseFloor = max(0.0, min(Self.noiseFloorCeiling, noiseFloor))
    }

    private mutating func updateGate(level: Float, dt: Float) {
        if isGateOpen {
            if level < closeThreshold {
                isGateOpen = false
                holdRemaining = Self.holdDuration
            } else {
                holdRemaining = Self.holdDuration
            }
        } else if level >= openThreshold, canOpenGate(level: level) {
            isGateOpen = true
            holdRemaining = Self.holdDuration
        } else {
            holdRemaining = max(0.0, holdRemaining - dt)
        }
    }

    /// While the noise floor is still calibrating, only a level loud enough to
    /// be unambiguously a voice may open the gate. That is what stops a fan
    /// from producing a blip in the first frames after recording starts.
    private func canOpenGate(level: Float) -> Bool {
        warmupRemaining <= 0 || level >= Self.warmupSpeechGuard
    }

    private func gatedDrive(level: Float) -> Float {
        guard isGateOpen else { return 0 }
        let base = closeThreshold
        let span = max(0.05, 1.0 - base)
        let normalized = max(0.0, min(1.0, (level - base) / span))
        // Perceptual lift: a soft voice should still visibly move the orb.
        return pow(normalized, 0.62)
    }

    static func follow(
        current: Float,
        target: Float,
        dt: Float,
        attackRate: Float,
        releaseRate: Float
    ) -> Float {
        let from = max(0.0, min(1.0, current))
        let to = max(0.0, min(1.0, target))
        let rate = to > from ? attackRate : releaseRate
        let next = from + (to - from) * min(1.0, max(0.0, dt) * rate)
        if to <= 0, next < idleEpsilon { return 0 }
        return max(0.0, min(1.0, next))
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        guard edge1 > edge0 else { return x >= edge1 ? 1 : 0 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }
}

// MARK: - Uniform Shaping

/// Maps the envelope onto the orb shader's uniform slots.
///
/// Nothing here touches the vendored Metal source. Every expressive change is a
/// per-frame uniform write, which keeps `OrbMetalSource.swift` byte-identical to
/// the pinned upstream commit.
enum OrbUniformShaping {
    // Uniform slot indices inside `OrbPreset.uniforms`.
    static let sizeX = 0
    static let sizeY = 1
    static let time = 2
    static let speed = 3
    static let radius = 4
    static let zoom = 5
    static let warp = 6
    static let ridgeAmt = 7
    static let sharp = 8
    static let exposure = 14
    static let edgeSoftness = 16
    static let contourDeform = 21
    static let styleFlowIndex = 15

    /// Flow index 9 is the Siri band shader, whose uniforms mean something
    /// different from every other fluid's.
    static func isBandStyle(_ base: [Float]) -> Bool {
        abs(base[styleFlowIndex] - 9.0) < 0.5
    }

    /// How far inside the frame the orb sits when nobody is speaking, leaving
    /// headroom for the scale pulse and the outline wobble.
    static let restRadiusScale: Float = 0.945
    /// The shader multiplies this by 0.09, so this caps the silhouette
    /// undulation at roughly 3% of the radius. Past that the orb stops
    /// reading as a button and starts reading as a dented potato.
    static let maxContourDeform: Float = 0.34
    /// Roughly 0.9% of the radius — an organic outline, not a reaction.
    static let restContourDeform: Float = 0.10

    /// Visual change per second that a preset should produce at a
    /// conversational phase velocity. Chosen so the set lands near where the
    /// liveliest original preset already sat.
    static let referenceFlow: Float = 22.0

    /// Converts a preset's measured `flowResponse` into the phase multiplier
    /// that makes every preset flow at a comparable perceived rate.
    ///
    /// The preset's own `speed` field is deliberately not used: it is a phase
    /// multiplier, not a measure of how much the image actually moves, and the
    /// two turned out to be nearly uncorrelated. `frost` ships at speed 2.22
    /// yet moves a twelfth as much per unit phase as `siri` at 0.82.
    static func motionScale(flowResponse: Float) -> Float {
        max(0.35, min(6.0, referenceFlow / max(0.5, flowResponse)))
    }

    /// The shader's alpha cut is `smoothstep(0.99 - d, 1.01 + d, pd)` with
    /// `d = edgeSoftness - 0.005`, i.e. a transition band of `0.01 + 2 * soft`
    /// in units of the orb radius. Solving that for a fixed pixel width gives a
    /// properly resolution-aware edge instead of the preset's 13px mush.
    static func edgeSoftness(
        drawableMinDimension: Float,
        orbRadius: Float,
        featherPixels: Float = 2.4
    ) -> Float {
        let radiusPixels = max(1.0, orbRadius * drawableMinDimension * 0.5)
        let bandInRadii = featherPixels / radiusPixels
        return max(0.002, min(0.06, (bandInRadii - 0.01) * 0.5))
    }

    /// Builds the frame's uniforms from the preset plus the live envelope.
    ///
    /// The resting pose is not a frozen random frame: it is the same field
    /// evaluated with a deliberately calmer parameterisation — less domain
    /// warp, softer ridges, a perfectly circular outline. Because every one of
    /// those is continuous, going quiet reads as the liquid settling rather
    /// than as a video being paused.
    static func shape(
        base: [Float],
        envelope: OrbSpeechEnvelope,
        drawableWidth: Float,
        drawableHeight: Float,
        isAnimated: Bool
    ) -> [Float] {
        var u = base
        u[sizeX] = drawableWidth
        u[sizeY] = drawableHeight

        let minDimension = max(1.0, min(drawableWidth, drawableHeight))
        u[edgeSoftness] = edgeSoftness(
            drawableMinDimension: minDimension,
            orbRadius: base[radius]
        )

        guard isAnimated else {
            // Static presets and Reduce Motion keep the original pose exactly.
            u[time] = 0
            return u
        }

        let punch = envelope.punch

        u[time] = envelope.phase
        // The preset's speed is folded into the integrated phase instead, so
        // the shader multiplies by 1 and the flow rate is ours to drive.
        u[speed] = 1.0

        // Resting is *slow*, not flattened.
        //
        // The obvious way to make a resting orb look calm is to wind down the
        // domain warp and the ridge amount. It backfires: `lqRamp` spreads the
        // four palette colours across the full range of the field value, so
        // compressing the field collapses the palette onto its middle two
        // stops. The highlight and the deep tone drop out, and the orb reads as
        // dim and muddy rather than calm. So the preset's own field parameters
        // are left alone at rest and every one of these is an *overdrive* that
        // only engages once there is a voice.

        // The orb rests slightly inside the frame so the pulse and the outline
        // wobble have somewhere to expand into.
        u[radius] = base[radius] * Self.restRadiusScale * (1.0 + 0.05 * punch)

        // Volume drives turbulence: `punch` pushes the domain warp above the
        // preset's own value so a loud syllable visibly churns.
        u[warp] = base[warp] * (1.0 + 0.35 * punch)

        // The Siri band shader reads `ridgeAmt` as the wave's height and its
        // line softness, so overdriving it is what makes the wave swell and
        // sharpen with the voice — the behaviour of the real Siri orb. Every
        // other fluid feeds `ridgeAmt` into a `mix()`, where values above 1
        // extrapolate, so those stay clamped.
        u[ridgeAmt] = isBandStyle(base)
            ? base[ridgeAmt] * (1.0 + 2.2 * punch)
            : min(1.0, base[ridgeAmt] * (1.0 + 0.4 * punch))

        // A lift only, never a dip. Dimming at rest was read as the orb simply
        // going dark, which is the one thing it must not do.
        u[exposure] = base[exposure] * (1.0 + 0.12 * punch)

        // Always faintly organic; undulating with the voice on top. The shader
        // scales this by 0.09, so the cap is a ~3% radius wobble.
        u[contourDeform] = min(
            Self.maxContourDeform,
            base[contourDeform] + Self.restContourDeform + 0.20 * punch
        )

        return u
    }
}
