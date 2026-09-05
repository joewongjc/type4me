//
//  LiquidGlassVisualTests.swift
//  Type4MeTests
//

import XCTest
@testable import Type4Me

@MainActor
final class LiquidGlassVisualTests: XCTestCase {

    // MARK: - RecordingTextParts Tests

    func testRecordingTextParts_emptySegmentsYieldsListeningText() {
        let parts = RecordingTextParts.build(segments: [], defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "")
        XCTAssertEqual(parts.active, "倾听中")
    }

    func testRecordingTextParts_allConfirmedSegmentsYieldsEmptyActive() {
        let segments = [
            TranscriptionSegment(text: "今天天气", isConfirmed: true),
            TranscriptionSegment(text: "真不错", isConfirmed: true),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "今天天气真不错")
        XCTAssertEqual(parts.active, "")
    }

    func testRecordingTextParts_mixedSegmentsSplitsConfirmedAndLastUnconfirmed() {
        let segments = [
            TranscriptionSegment(text: "今天天气", isConfirmed: true),
            TranscriptionSegment(text: "很好，我们", isConfirmed: true),
            TranscriptionSegment(text: "出去玩吧", isConfirmed: false),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "今天天气很好，我们")
        XCTAssertEqual(parts.active, "出去玩吧")
    }

    func testRecordingTextParts_onlyUnconfirmedSegment() {
        let segments = [
            TranscriptionSegment(text: "正在说话", isConfirmed: false),
        ]
        let parts = RecordingTextParts.build(segments: segments, defaultListeningText: "倾听中")
        XCTAssertEqual(parts.confirmed, "")
        XCTAssertEqual(parts.active, "正在说话")
    }

    // MARK: - OrbPreset Mapping Tests

    func testOrbPresets_styleIDAndAnimation() {
        XCTAssertEqual(RecordingVisualStyle.siri.preset.styleID, 0)
        XCTAssertTrue(RecordingVisualStyle.siri.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.blueDrop.preset.styleID, 1)
        XCTAssertTrue(RecordingVisualStyle.blueDrop.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.chromaticMetal.preset.styleID, 2)
        XCTAssertTrue(RecordingVisualStyle.chromaticMetal.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.frost.preset.styleID, 3)
        XCTAssertTrue(RecordingVisualStyle.frost.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.opal.preset.styleID, 4)
        XCTAssertTrue(RecordingVisualStyle.opal.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.voiceWave.preset.styleID, 5)
        XCTAssertTrue(RecordingVisualStyle.voiceWave.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.violetEmber.preset.styleID, 6)
        XCTAssertTrue(RecordingVisualStyle.violetEmber.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.aurora.preset.styleID, 7)
        XCTAssertTrue(RecordingVisualStyle.aurora.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.chrome.preset.styleID, 8)
        XCTAssertTrue(RecordingVisualStyle.chrome.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.spectrum.preset.styleID, 9)
        XCTAssertTrue(RecordingVisualStyle.spectrum.preset.isAnimated)

        XCTAssertEqual(RecordingVisualStyle.staticGlass.preset.styleID, 10)
        XCTAssertFalse(RecordingVisualStyle.staticGlass.preset.isAnimated)
    }

    // MARK: - LiquidGlassMotion Policy Tests

    func testLiquidGlassMotion_activeClampsEnergy() {
        let motion = LiquidGlassMotion.active(time: 12.34, rawEnergy: 1.5, isAnimated: true, reduceMotion: false)
        XCTAssertTrue(motion.isAnimated)
        XCTAssertEqual(motion.time, 12.34)
        XCTAssertEqual(motion.energy, 1.0)

        let negativeMotion = LiquidGlassMotion.active(time: 5.0, rawEnergy: -0.5, isAnimated: true, reduceMotion: false)
        XCTAssertEqual(negativeMotion.energy, 0.0)
    }

    func testLiquidGlassMotion_staticOrReduceMotionYieldsStaticFallback() {
        let staticMotion = LiquidGlassMotion.active(time: 10.0, rawEnergy: 0.8, isAnimated: false, reduceMotion: false)
        XCTAssertEqual(staticMotion, LiquidGlassMotion.staticFallback)

        let reduceMotion = LiquidGlassMotion.active(time: 10.0, rawEnergy: 0.8, isAnimated: true, reduceMotion: true)
        XCTAssertEqual(reduceMotion, LiquidGlassMotion.staticFallback)
    }

    // MARK: - OrbSpeechEnvelope Tests

    /// Drives the envelope at 60fps for `seconds` at a constant meter level.
    private func run(
        _ envelope: inout OrbSpeechEnvelope,
        level: Float,
        seconds: Float,
        motionScale: Float = 1.0
    ) {
        let dt: Float = 1.0 / 60.0
        var elapsed: Float = 0
        while elapsed < seconds {
            envelope.advance(rawLevel: level, deltaTime: dt, motionScale: motionScale)
            elapsed += dt
        }
    }

    func testEnvelope_twoSecondsOfSilenceProducesNoReactionOnlySlowDrift() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.0, seconds: 2.0)

        XCTAssertEqual(envelope.activity, 0)
        XCTAssertEqual(envelope.transient, 0)
        XCTAssertEqual(envelope.liveness, 0)
        XCTAssertEqual(envelope.idleBlend, 1)
        // Alive, but only just: the field drifts, nothing reacts.
        XCTAssertEqual(envelope.phaseVelocity, OrbSpeechEnvelope.idlePhaseVelocity)
        XCTAssertEqual(envelope.phase, 2.0 * OrbSpeechEnvelope.idlePhaseVelocity,
                       accuracy: 0.02)
    }

    func testEnvelope_speakingFlowsFarFasterThanResting() {
        var resting = OrbSpeechEnvelope()
        run(&resting, level: 0.0, seconds: 1.0)

        var speaking = OrbSpeechEnvelope()
        run(&speaking, level: 0.02, seconds: 0.5)
        run(&speaking, level: 0.8, seconds: 1.0)

        XCTAssertGreaterThan(speaking.phaseVelocity, resting.phaseVelocity * 6)
    }

    func testEnvelope_steadyRoomNoiseNeverWakesTheOrb() {
        // A fan sitting well above the old fixed 0.15 gate.
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.22, seconds: 3.0)

        XCTAssertFalse(envelope.isGateOpen)
        XCTAssertEqual(envelope.activity, 0)
        XCTAssertEqual(envelope.liveness, 0)
    }

    func testEnvelope_flowRespondsFastWhilePoseEasesIn() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5) // quiet room first
        run(&envelope, level: 0.6, seconds: 0.15)

        // Flow speed is the immediate response: a change of rate reads as
        // smooth no matter how fast it arrives.
        XCTAssertTrue(envelope.isGateOpen)
        XCTAssertGreaterThan(envelope.phaseVelocity,
                             OrbSpeechEnvelope.idlePhaseVelocity * 5)

        // The pose is deliberately still on its way up at this point — that is
        // what keeps the start of a phrase from snapping.
        XCTAssertGreaterThan(envelope.liveness, 0.25)
        XCTAssertLessThan(envelope.liveness, 0.9)

        run(&envelope, level: 0.6, seconds: 0.3)
        XCTAssertGreaterThan(envelope.liveness, 0.85, "and fully arrived by ~450ms")
    }

    func testEnvelope_aVeryQuietSoundCannotFlashTheOrb() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.6)

        // A faint, fluttering sound just above the gate.
        let dt: Float = 1.0 / 60.0
        var t: Float = 0
        var peakPunch: Float = 0
        var peakSwing: Float = 0
        var previous: Float = 0
        while t < 2.0 {
            let level: Float = (Int(t / 0.11) % 2 == 0) ? 0.16 : 0.05
            envelope.advance(rawLevel: level, deltaTime: dt, motionScale: 1.0)
            peakPunch = max(peakPunch, envelope.punch)
            peakSwing = max(peakSwing, abs(envelope.punch - previous) / dt)
            previous = envelope.punch
            t += dt
        }

        // `punch` is what drives scale, exposure and outline. Near zero here
        // means a weak voice produces flow, never a flash.
        XCTAssertLessThan(peakPunch, 0.10)
        XCTAssertLessThan(peakSwing, 1.0)
    }

    func testEnvelope_loudSpeechDrivesHarderThanQuietSpeech() {
        var quiet = OrbSpeechEnvelope()
        run(&quiet, level: 0.02, seconds: 0.5)
        run(&quiet, level: 0.22, seconds: 0.6)

        var loud = OrbSpeechEnvelope()
        run(&loud, level: 0.02, seconds: 0.5)
        run(&loud, level: 0.85, seconds: 0.6)

        XCTAssertGreaterThan(quiet.activity, 0, "a soft voice must still register")
        XCTAssertGreaterThan(loud.activity, quiet.activity)
        XCTAssertGreaterThan(loud.transient, quiet.transient)
        XCTAssertGreaterThan(loud.phaseVelocity, quiet.phaseVelocity)
    }

    func testEnvelope_sustainedSoftSpeechDoesNotBecomeRoomNoise() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5)
        run(&envelope, level: 0.22, seconds: 6.0)

        XCTAssertTrue(envelope.isGateOpen)
        XCTAssertGreaterThan(envelope.activity, 0)
        XCTAssertGreaterThan(envelope.liveness, 0)
        XCTAssertLessThan(envelope.noiseFloor, envelope.closeThreshold)
    }

    func testEnvelope_shortPauseInsideASentenceDoesNotDropTheOrb() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5)
        run(&envelope, level: 0.7, seconds: 0.5)
        let speaking = envelope.activity

        run(&envelope, level: 0.0, seconds: 0.12) // gap between words

        XCTAssertGreaterThan(envelope.activity, speaking * 0.9)
        XCTAssertGreaterThan(envelope.liveness, 0.97)
    }

    func testEnvelope_settlesBackToRestWithinHalfASecondOfSilence() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5)
        run(&envelope, level: 0.7, seconds: 1.0)
        XCTAssertGreaterThan(envelope.liveness, 0.97)

        run(&envelope, level: 0.0, seconds: 0.6)

        // Motion stops promptly...
        XCTAssertEqual(envelope.activity, 0)
        XCTAssertEqual(envelope.phaseVelocity, OrbSpeechEnvelope.idlePhaseVelocity,
                       accuracy: 0.02, "settled orbs drift, they do not react")
        XCTAssertEqual(envelope.punch, 0)

        // ...while the pose keeps easing back for a beat longer, which is what
        // makes the orb look like it is relaxing rather than being switched off.
        XCTAssertGreaterThan(envelope.liveness, 0)
        run(&envelope, level: 0.0, seconds: 0.9)
        XCTAssertEqual(envelope.liveness, 0)
    }

    func testEnvelope_gateUsesHysteresisSoBorderlineLevelsDoNotChatter() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5)
        XCTAssertGreaterThan(envelope.openThreshold, envelope.closeThreshold)

        run(&envelope, level: envelope.openThreshold + 0.01, seconds: 0.2)
        XCTAssertTrue(envelope.isGateOpen)

        // Between the two thresholds the gate must stay open.
        run(&envelope, level: envelope.closeThreshold + 0.005, seconds: 0.2)
        XCTAssertTrue(envelope.isGateOpen)
    }

    func testEnvelope_resetReturnsToTheRestingState() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.8, seconds: 0.5)
        envelope.reset()

        XCTAssertEqual(envelope.activity, 0)
        XCTAssertEqual(envelope.transient, 0)
        XCTAssertFalse(envelope.isGateOpen)
        XCTAssertEqual(envelope.liveness, 0)
    }

    // MARK: - OrbUniformShaping Tests

    func testUniformShaping_restingPoseIsCircularAndCalmerThanTheLivePose() {
        let base = RecordingVisualStyle.siri.preset.uniforms
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.0, seconds: 1.0)

        let rest = OrbUniformShaping.shape(
            base: base,
            envelope: envelope,
            drawableWidth: 180,
            drawableHeight: 180,
            isAnimated: true
        )

        XCTAssertEqual(rest[OrbUniformShaping.contourDeform],
                       base[OrbUniformShaping.contourDeform]
                           + OrbUniformShaping.restContourDeform,
                       accuracy: 0.0001, "a silent orb is organic, not reactive")
        XCTAssertEqual(
            rest[OrbUniformShaping.radius],
            base[OrbUniformShaping.radius] * OrbUniformShaping.restRadiusScale,
            accuracy: 0.0001, "no scale pulse without a voice"
        )

        // The resting orb must keep the preset's own field parameters. Winding
        // them down collapses `lqRamp` onto its middle two palette stops, which
        // reads as the orb going dim and muddy instead of calm.
        XCTAssertEqual(rest[OrbUniformShaping.warp], base[OrbUniformShaping.warp],
                       accuracy: 0.0001)
        XCTAssertEqual(rest[OrbUniformShaping.ridgeAmt], base[OrbUniformShaping.ridgeAmt],
                       accuracy: 0.0001)
        XCTAssertEqual(rest[OrbUniformShaping.exposure], base[OrbUniformShaping.exposure],
                       accuracy: 0.0001, "resting must never be darker than the preset")

        run(&envelope, level: 0.8, seconds: 0.6)
        let live = OrbUniformShaping.shape(
            base: base,
            envelope: envelope,
            drawableWidth: 180,
            drawableHeight: 180,
            isAnimated: true
        )

        XCTAssertGreaterThan(live[OrbUniformShaping.warp], rest[OrbUniformShaping.warp])
        XCTAssertGreaterThan(live[OrbUniformShaping.exposure], rest[OrbUniformShaping.exposure])
        XCTAssertGreaterThan(live[OrbUniformShaping.contourDeform], 0)
        XCTAssertGreaterThan(live[OrbUniformShaping.radius], rest[OrbUniformShaping.radius])
        XCTAssertGreaterThan(live[OrbUniformShaping.time], 0)
    }

    func testUniformShaping_exposureLiftStaysRestrained() {
        let base = RecordingVisualStyle.siri.preset.uniforms
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.02, seconds: 0.5)
        run(&envelope, level: 1.0, seconds: 1.0)

        let live = OrbUniformShaping.shape(
            base: base,
            envelope: envelope,
            drawableWidth: 180,
            drawableHeight: 180,
            isAnimated: true
        )
        let ratio = live[OrbUniformShaping.exposure] / base[OrbUniformShaping.exposure]
        XCTAssertGreaterThan(ratio, 1.0)
        XCTAssertLessThanOrEqual(ratio, 1.13, "the old +70% blew every preset to white")
    }

    func testUniformShaping_staticSurfacesKeepTheOriginalPose() {
        let base = RecordingVisualStyle.staticGlass.preset.uniforms
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.9, seconds: 1.0)

        let shaped = OrbUniformShaping.shape(
            base: base,
            envelope: envelope,
            drawableWidth: 180,
            drawableHeight: 180,
            isAnimated: false
        )

        XCTAssertEqual(shaped[OrbUniformShaping.time], 0)
        for index in 0..<base.count {
            switch index {
            case OrbUniformShaping.sizeX, OrbUniformShaping.sizeY,
                 OrbUniformShaping.time, OrbUniformShaping.edgeSoftness:
                continue
            default:
                XCTAssertEqual(shaped[index], base[index], accuracy: 0.0001,
                               "static preset uniform \(index) must be untouched")
            }
        }
    }

    func testUniformShaping_edgeSoftnessTightensAsResolutionRises() {
        let coarse = OrbUniformShaping.edgeSoftness(
            drawableMinDimension: 90, orbRadius: 0.94
        )
        let fine = OrbUniformShaping.edgeSoftness(
            drawableMinDimension: 180, orbRadius: 0.94
        )
        XCTAssertLessThan(fine, coarse, "a denser drawable needs a narrower feather")
        // Both must be dramatically crisper than the preset's own 0.15 mush.
        XCTAssertLessThan(coarse, 0.03)
        XCTAssertGreaterThan(fine, 0.002)
    }

    func testUniformShaping_motionScaleEqualisesMeasuredFlow() {
        // A sluggish fluid must be driven harder than a lively one.
        let sluggish = OrbUniformShaping.motionScale(flowResponse: 3.93)  // frost
        let lively = OrbUniformShaping.motionScale(flowResponse: 50.72)   // siri
        XCTAssertGreaterThan(sluggish, lively * 5)

        // Perceived flow — response times scale — lands near the reference.
        for style in RecordingVisualStyle.allCases where style.preset.isAnimated {
            let preset = style.preset
            let perceived = preset.flowResponse
                * OrbUniformShaping.motionScale(flowResponse: preset.flowResponse)
            XCTAssertEqual(perceived, OrbUniformShaping.referenceFlow,
                           accuracy: OrbUniformShaping.referenceFlow * 0.15,
                           "\(style.rawValue) flows off-pace")
        }
    }

    func testOrbPresets_spectrumIntentionallySharesTheSiriBandShader() {
        // Spectrum is the spectral palette running through the Siri wave. The
        // unused spectrum fluid at index 14 renders a much plainer band, so
        // this is a deliberate choice, not the oversight it looks like.
        XCTAssertEqual(
            RecordingVisualStyle.spectrum.preset.uniforms[OrbUniformShaping.styleFlowIndex],
            9.0
        )
        XCTAssertNotEqual(
            RecordingVisualStyle.spectrum.preset.uniforms,
            RecordingVisualStyle.siri.preset.uniforms,
            "it must still differ from siri everywhere else"
        )
    }

    func testEnvelope_fastSpeechFlowsFasterThanASteadyToneAtTheSameVolume() {
        let dt: Float = 1.0 / 60.0

        var steady = OrbSpeechEnvelope()
        run(&steady, level: 0.02, seconds: 0.5)
        run(&steady, level: 0.7, seconds: 1.2)

        var rapid = OrbSpeechEnvelope()
        run(&rapid, level: 0.02, seconds: 0.5)
        var t: Float = 0
        while t < 1.2 {
            // Same mean level, modulated at a syllable rate.
            let level: Float = (Int(t / 0.09) % 2 == 0) ? 0.95 : 0.45
            rapid.advance(rawLevel: level, deltaTime: dt, motionScale: 1.0)
            t += dt
        }

        XCTAssertGreaterThan(rapid.flux, steady.flux * 3)
        XCTAssertGreaterThan(rapid.phaseVelocity, steady.phaseVelocity)
    }

    func testEnvelope_fluxIsZeroWhenNobodyIsSpeaking() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.0, seconds: 1.5)
        XCTAssertEqual(envelope.flux, 0)
    }

    func testUniformShaping_everyAnimatedPresetIsUnreactiveAtRest() {
        var envelope = OrbSpeechEnvelope()
        run(&envelope, level: 0.0, seconds: 1.0)

        for style in RecordingVisualStyle.allCases where style.preset.isAnimated {
            let base = style.preset.uniforms
            let rest = OrbUniformShaping.shape(
                base: base,
                envelope: envelope,
                drawableWidth: 180,
                drawableHeight: 180,
                isAnimated: true
            )
            XCTAssertLessThanOrEqual(
                rest[OrbUniformShaping.contourDeform],
                base[OrbUniformShaping.contourDeform] + OrbUniformShaping.restContourDeform + 0.0001,
                "\(style.rawValue) must not deform reactively at rest"
            )
            XCTAssertEqual(
                rest[OrbUniformShaping.radius],
                base[OrbUniformShaping.radius] * OrbUniformShaping.restRadiusScale,
                accuracy: 0.0001, "\(style.rawValue) must not pulse at rest"
            )
            XCTAssertEqual(rest[OrbUniformShaping.speed], 1.0, accuracy: 0.0001,
                           "\(style.rawValue) folds preset speed into the phase")
        }
    }

    // MARK: - DemoState Preview Segment Tests

    func testDemoState_makePreviewSegments_splitsConfirmedAndActive() {
        let zhSegments = DemoState.makePreviewSegments(from: "我正在使用Type4Me测试一段足够长的实时识别文本，方便直接预览悬停窗口和录音动效。")
        XCTAssertEqual(zhSegments.count, 2)
        XCTAssertTrue(zhSegments[0].isConfirmed)
        XCTAssertFalse(zhSegments[1].isConfirmed)
        XCTAssertEqual(zhSegments[0].text, "我正在使用Type4Me测试一段足够长的实时识别文本，")
        XCTAssertEqual(zhSegments[1].text, "方便直接预览悬停窗口和录音动效。")

        let enSegments = DemoState.makePreviewSegments(from: "I am testing a sufficiently long live transcript in Type4Me, to preview the hover window and recording effects directly.")
        XCTAssertEqual(enSegments.count, 2)
        XCTAssertTrue(enSegments[0].isConfirmed)
        XCTAssertFalse(enSegments[1].isConfirmed)
    }
}
