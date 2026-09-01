import XCTest
@testable import Type4Me

@MainActor
final class AppStateTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suite = "Type4MeTests.AppState.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testFreshInstallStartsInQuickMode() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-fresh-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let appState = AppState(modeStorage: ModeStorage(fileURL: url), userDefaults: makeDefaults())

        XCTAssertEqual(appState.currentMode.id, ProcessingMode.directId)
    }

    func testExistingInstallWithoutSelectionPreservesLegacySmartModeStartup() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-existing-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = ModeStorage(fileURL: url)
        try storage.save([.direct, .smartDirect])

        let appState = AppState(modeStorage: storage, userDefaults: makeDefaults())

        XCTAssertEqual(appState.currentMode.id, ProcessingMode.smartDirectId)
    }

    func testRecordingSelectionPersistsAndRestoresLastValidMode() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-selection-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let storage = ModeStorage(fileURL: url)
        try storage.save(ProcessingMode.defaults)
        let defaults = makeDefaults()
        let first = AppState(modeStorage: storage, userDefaults: defaults)

        first.selectModeForRecording(.intelliSense)
        let restored = AppState(modeStorage: storage, userDefaults: defaults)

        XCTAssertEqual(restored.currentMode.id, ProcessingMode.intelliSenseId)
    }

    func testStartRecordingTransitionsToPreparing() {
        let appState = AppState()
        appState.startRecording()

        XCTAssertEqual(appState.barPhase, .preparing)
    }

    func testStopRecordingIgnoredWhenNotRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.cancel()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingCancelsWhenPreparing() {
        let appState = AppState()
        appState.startRecording()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .hidden)
    }

    func testStopRecordingTransitionsToProcessingWhenRecording() {
        let appState = AppState()
        appState.currentMode = .smartDirect
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testStopRecordingTransitionsDirectModeToProcessing() {
        let appState = AppState()
        appState.currentMode = .direct
        appState.startRecording()
        appState.markRecordingReady()

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
    }

    func testShowRecoveryDisplaysPartialTextAndStatus() {
        let appState = AppState()

        appState.showRecovery(
            text: "已经识别的文字",
            message: "连接中断，已保留当前文字，正在用整段录音重试"
        )

        XCTAssertEqual(appState.barPhase, .recovering)
        XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
        XCTAssertEqual(appState.effectiveProcessingLabel, "连接中断，已保留当前文字，正在用整段录音重试")
    }

    func testRecoveryPromptKeepsPartialTextVisible() {
        let appState = AppState()
        appState.showRecovery(
            text: "已经识别的文字",
            message: "连接中断，已保留当前文字，正在用整段录音重试"
        )

        appState.showRecoveryPrompt(
            text: "已经识别的文字",
            message: "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。"
        )

        XCTAssertEqual(appState.barPhase, .recovering)
        XCTAssertEqual(appState.transcriptionText, "已经识别的文字")
        XCTAssertEqual(appState.effectiveProcessingLabel, "正在恢复上一次识别。继续按下将打断当前恢复并重新开始录音。")
    }

    func testRecoveryResultPinsTranscriptPopup() {
        let appState = AppState()

        appState.showRecoveryResult(text: "完整识别文字", message: "已恢复完整识别")

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.transcriptionText, "完整识别文字")
        XCTAssertTrue(appState.pinsTranscriptPopup)
    }

    func testStaticRecordingVisualKeepsHostPanelAliveForLivePreferenceChanges() {
        let previousStyle = UserDefaults.standard.string(forKey: RecordingVisualStyle.storageKey)
        UserDefaults.standard.set(RecordingVisualStyle.staticGlass.rawValue, forKey: RecordingVisualStyle.storageKey)
        defer {
            if let previousStyle {
                UserDefaults.standard.set(previousStyle, forKey: RecordingVisualStyle.storageKey)
            } else {
                UserDefaults.standard.removeObject(forKey: RecordingVisualStyle.storageKey)
            }
        }

        let appState = AppState()
        var showCount = 0
        var hideCount = 0
        appState.onShowPanel = { showCount += 1 }
        appState.onHidePanel = { hideCount += 1 }

        appState.startRecording()
        appState.markRecordingReady()

        XCTAssertEqual(appState.barPhase, .recording)
        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(hideCount, 0)

        appState.stopRecording()

        XCTAssertEqual(appState.barPhase, .processing)
        XCTAssertEqual(showCount, 2)
        XCTAssertEqual(hideCount, 0)
    }

    func testRecordingVisualStylesInclude11LiquidGlassPresets() {
        XCTAssertEqual(RecordingVisualStyle.allCases.count, 11)
        XCTAssertEqual(RecordingVisualStyle.defaultValue, "siri")
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.siri))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.blueDrop))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.chromaticMetal))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.frost))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.opal))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.voiceWave))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.violetEmber))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.aurora))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.chrome))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.spectrum))
        XCTAssertTrue(RecordingVisualStyle.allCases.contains(.staticGlass))

        XCTAssertFalse(RecordingVisualStyle.staticGlass.isAnimated)
        XCTAssertTrue(RecordingVisualStyle.siri.isAnimated)
        XCTAssertTrue(RecordingVisualStyle.blueDrop.isAnimated)
    }

    func testRecordingVisualStyleMigrationFromLegacySchema() {
        let suite = "Type4MeTests.VisualMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // 1. classic -> siri
        defaults.set(0, forKey: RecordingVisualStyle.schemaVersionKey)
        defaults.set("classic", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), RecordingVisualStyle.siri.rawValue)
        XCTAssertEqual(defaults.integer(forKey: RecordingVisualStyle.schemaVersionKey), 2)

        // 2. dual -> voiceWave
        defaults.set(0, forKey: RecordingVisualStyle.schemaVersionKey)
        defaults.set("dual", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), RecordingVisualStyle.voiceWave.rawValue)

        // 3. timeline -> spectrum
        defaults.set(0, forKey: RecordingVisualStyle.schemaVersionKey)
        defaults.set("timeline", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), RecordingVisualStyle.spectrum.rawValue)

        // 4. effectless -> static
        defaults.set(0, forKey: RecordingVisualStyle.schemaVersionKey)
        defaults.set("effectless", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), RecordingVisualStyle.staticGlass.rawValue)

        // 5. hidden -> static
        defaults.set(0, forKey: RecordingVisualStyle.schemaVersionKey)
        defaults.set("hidden", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), RecordingVisualStyle.staticGlass.rawValue)

        // 6. Schema 2 does not overwrite user changes
        defaults.set("chrome", forKey: RecordingVisualStyle.storageKey)
        RecordingVisualStyle.migrateLegacyPreferenceIfNeeded(userDefaults: defaults)
        XCTAssertEqual(defaults.string(forKey: RecordingVisualStyle.storageKey), "chrome")
    }

    func testFloatingIndicatorDesignDimensionsMatchSpecification() {
        XCTAssertEqual(TF.barHeight, 55)
        XCTAssertEqual(TF.barWidthCompact, 180)
        XCTAssertEqual(TF.barWidth, 400)
        XCTAssertEqual(TF.floatingPanelShadowInset, 8)
        XCTAssertEqual(TF.recordingFinishControlSize, 45)
        XCTAssertEqual(TF.recordingCancelControlSize, 35)
        XCTAssertEqual(TF.recordingLeadingInset, 5)
        XCTAssertEqual(TF.recordingTrailingInset, 10)
        XCTAssertEqual(TF.recordingEdgeInset, 10)
        XCTAssertEqual(TF.recordingTooltipGap, 5)
        XCTAssertEqual(TF.transcriptPopupWidth, 350)
        XCTAssertEqual(TF.transcriptPopupMaxHeight, 120)
        XCTAssertEqual(TF.transcriptPopupCorner, TF.cornerLG)
        XCTAssertEqual(TF.transcriptPopupGap, 10)
    }

    func testFloatingPanelLayoutTracksOnlyVisibleBounds() {
        XCTAssertEqual(FloatingBarPanelLayout.hidden.panelSize, NSSize(width: 1, height: 1))

        let shortBar = FloatingBarPanelLayout(
            contentSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight)
        )
        XCTAssertEqual(shortBar.panelSize, NSSize(width: 196, height: 71))
        XCTAssertEqual(
            FloatingBarPanelLayout.fallback(for: .compact, showsLiveTranscript: false).panelSize,
            NSSize(width: 196, height: 40)
        )
        XCTAssertEqual(
            FloatingBarPanelLayout.fallback(for: .compact, showsLiveTranscript: true).panelSize,
            NSSize(width: 196, height: 64)
        )

        let fullBar = FloatingBarPanelLayout(
            contentSize: NSSize(width: TF.barWidth, height: TF.barHeight)
        )
        XCTAssertEqual(fullBar.panelSize, NSSize(width: 416, height: 71))

        let transcript = FloatingBarPanelLayout(
            contentSize: NSSize(
                width: TF.transcriptPopupWidth,
                height: TF.barHeight + TF.transcriptPopupGap + 60
            )
        )
        XCTAssertEqual(transcript.panelSize, NSSize(width: 366, height: 141))

        let action = FloatingBarPanelLayout(
            contentSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight + 5 + 35),
            horizontalOverflow: 60
        )
        XCTAssertEqual(action.panelSize, NSSize(width: 316, height: 111))
    }

    func testFloatingPanelKeepsCapsulePositionWhenOverlayResizesPanel() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let capsuleSize = NSSize(width: TF.barWidthCompact, height: TF.barHeight)

        // Hovering a control adds a tooltip whose bubble overflows the capsule by
        // a fractional amount. The capsule is centered in the panel, so its left
        // edge must not move as the panel grows around it.
        let overflows: [CGFloat] = [0, 12.5, 37.25, 60, 73.9]
        let capsuleOrigins: [CGFloat] = overflows.map { overflow in
            let layout = FloatingBarPanelLayout(
                contentSize: capsuleSize,
                horizontalOverflow: overflow,
                capsuleSize: capsuleSize
            )
            let size = layout.panelSize
            XCTAssertEqual(size.width.truncatingRemainder(dividingBy: 2), 0, "panel width must stay even")

            let frame = FloatingBarPanel.bottomCenteredFrame(size: size, visibleFrame: visibleFrame)
            return frame.minX + (size.width - capsuleSize.width) / 2
        }

        for origin in capsuleOrigins {
            XCTAssertEqual(origin, capsuleOrigins[0], accuracy: 0.001)
        }
    }

    func testFloatingPanelFrameKeepsBarBottomCentered() {
        let visibleFrame = NSRect(x: 100, y: 50, width: 1000, height: 800)
        let frame = FloatingBarPanel.bottomCenteredFrame(
            size: NSSize(width: 180, height: 55),
            visibleFrame: visibleFrame
        )

        XCTAssertEqual(frame.midX, visibleFrame.midX)
        XCTAssertEqual(
            frame.minY + TF.floatingPanelShadowInset,
            visibleFrame.minY + TF.barBottomOffset
        )

        let expandedFrame = FloatingBarPanel.bottomCenteredFrame(
            size: NSSize(width: 400, height: 185),
            visibleFrame: visibleFrame
        )
        XCTAssertEqual(expandedFrame.minY, frame.minY)
    }

    func testRecordingActionHintsAreCenteredOverTheirControls() {
        let width: CGFloat = 180
        let finishOffset = recordingActionHorizontalOffset(
            .finish,
            capsuleWidth: width,
            usesCompactLayout: false
        )
        let cancelOffset = recordingActionHorizontalOffset(
            .cancel,
            capsuleWidth: width,
            usesCompactLayout: false
        )

        XCTAssertEqual(width / 2 + finishOffset, TF.recordingLeadingInset + TF.recordingFinishControlSize / 2)
        XCTAssertEqual(width / 2 + cancelOffset, width - TF.recordingTrailingInset - TF.recordingCancelControlSize / 2)
        XCTAssertEqual(
            width / 2 + recordingActionHorizontalOffset(.finish, capsuleWidth: width, usesCompactLayout: true),
            16
        )
        XCTAssertEqual(
            width / 2 + recordingActionHorizontalOffset(.cancel, capsuleWidth: width, usesCompactLayout: true),
            width - 16
        )
    }

    func testFloatingPanelControllerEnablesMouseOnlyForVisibleContent() async throws {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)
        // This test injects layouts directly; detach the live SwiftUI reporter.
        controller.panel.contentView = nil
        appState.barPhase = .recording

        let visibleLayout = FloatingBarPanelLayout(
            contentSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight),
            capsuleSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight)
        )
        controller.updatePanelLayout(visibleLayout)
        XCTAssertFalse(controller.panel.ignoresMouseEvents)
        XCTAssertEqual(controller.panel.frame.size, visibleLayout.panelSize)
        XCTAssertFalse(controller.panel.hasShadow)

        let previewLayout = FloatingBarPanelLayout(
            contentSize: NSSize(
                width: TF.transcriptPopupWidth,
                height: TF.barHeight + TF.transcriptPopupGap + TF.transcriptPopupMaxHeight
            ),
            capsuleSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight)
        )
        controller.updatePanelLayout(previewLayout)
        XCTAssertEqual(controller.panel.frame.size, previewLayout.panelSize)

        controller.panel.alphaValue = 0
        controller.panel.orderFrontRegardless()
        defer { controller.panel.orderOut(nil) }

        controller.updatePanelLayout(visibleLayout)
        XCTAssertEqual(controller.panel.frame.size, visibleLayout.panelSize)

        let wideCapsuleLayout = FloatingBarPanelLayout(
            contentSize: NSSize(
                width: TF.barWidth,
                height: TF.barHeight + TF.transcriptPopupGap + TF.transcriptPopupMaxHeight
            ),
            capsuleSize: NSSize(width: TF.barWidth, height: TF.barHeight)
        )
        controller.updatePanelLayout(wideCapsuleLayout)
        XCTAssertEqual(controller.panel.frame.size, wideCapsuleLayout.panelSize)

        let animatedCapsuleLayout = FloatingBarPanelLayout(
            contentSize: visibleLayout.contentSize,
            capsuleSize: visibleLayout.capsuleSize
        )
        controller.updatePanelLayout(animatedCapsuleLayout)
        XCTAssertEqual(
            controller.panel.frame.size,
            NSSize(width: wideCapsuleLayout.panelSize.width, height: animatedCapsuleLayout.panelSize.height)
        )

        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(controller.panel.frame.size, animatedCapsuleLayout.panelSize)

        controller.panel.orderOut(nil)
        appState.barPhase = .hidden
        controller.updatePanelLayout(.hidden)
        XCTAssertTrue(controller.panel.ignoresMouseEvents)
        XCTAssertEqual(controller.panel.frame.size, FloatingBarPanelLayout.hidden.panelSize)
    }

    func testFloatingIndicatorHoverTrackingDoesNotInterceptControls() {
        let panel = FloatingBarPanel(contentRect: NSRect(x: 0, y: 0, width: 432, height: 217))
        let tracker = HoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 45, height: 45))
        let buttonTarget = FloatingBarButtonNSView(frame: NSRect(x: 0, y: 0, width: 45, height: 45))
        var clickCount = 0
        buttonTarget.onClick = { clickCount += 1 }

        XCTAssertTrue(panel.ignoresMouseEvents)
        panel.ignoresMouseEvents = false
        XCTAssertTrue(panel.acceptsMouseMovedEvents)
        XCTAssertNil(tracker.hitTest(NSPoint(x: 22, y: 22)))
        XCTAssertTrue(buttonTarget.acceptsFirstMouse(for: nil))
        XCTAssertTrue(buttonTarget.hitTest(NSPoint(x: 22, y: 22)) === buttonTarget)

        let downEvent = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 22, y: 22),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )
        let upEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 22, y: 22),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        )
        buttonTarget.mouseDown(with: try! XCTUnwrap(downEvent))
        XCTAssertEqual(clickCount, 0) // Does not trigger on mouseDown alone
        buttonTarget.mouseUp(with: try! XCTUnwrap(upEvent))
        XCTAssertEqual(clickCount, 1) // Triggers on mouseUp inside bounds

        // Test drag-to-cancel: release outside bounds should not trigger click
        var pressStates: [Bool] = []
        buttonTarget.onPressChanged = { pressStates.append($0) }
        buttonTarget.mouseDown(with: try! XCTUnwrap(downEvent))
        XCTAssertEqual(pressStates.last, true)

        let outsideDragEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 3,
            clickCount: 1,
            pressure: 1
        )
        buttonTarget.mouseDragged(with: try! XCTUnwrap(outsideDragEvent))
        XCTAssertEqual(pressStates.last, true) // stays pressed during drag across screen

        let outsideUpEvent = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: NSPoint(x: 100, y: 100),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 4,
            clickCount: 1,
            pressure: 0
        )
        buttonTarget.mouseUp(with: try! XCTUnwrap(outsideUpEvent))
        XCTAssertEqual(pressStates.last, false) // unpressed on mouseUp
        XCTAssertEqual(clickCount, 1) // clickCount still 1 (release outside bounds does not trigger click)
    }

    func testFloatingIndicatorActionCallbacksAreForwarded() {
        let appState = AppState()
        var actions: [RecordingControlAction] = []
        appState.onRecordingControlAction = { actions.append($0) }

        appState.performRecordingControlAction(.finish)
        appState.performRecordingControlAction(.cancel)

        XCTAssertEqual(actions, [.finish, .cancel])
    }

    func testDisabledLiveTranscriptOnlyHidesTextWhileRecording() {
        XCTAssertFalse(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .recording
            )
        )
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .recovering
            )
        )
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: false,
                phase: .done
            )
        )
    }

    func testEnabledLiveTranscriptShowsTextWhileRecording() {
        XCTAssertTrue(
            LiveTranscriptDisplayPreference.showsTranscript(
                isEnabled: true,
                phase: .recording
            )
        )
    }

    func testSetLiveTranscriptReplacesExistingConfirmedSegments() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖"],
                partialText: "",
                authoritativeText: "我想买咖",
                isFinal: false
            )
        )
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["我想", "买咖啡"],
                partialText: "",
                authoritativeText: "我想买咖啡",
                isFinal: false
            )
        )

        XCTAssertEqual(appState.segments.map(\.text), ["我想", "买咖啡"])
        XCTAssertEqual(appState.transcriptionText, "我想买咖啡")
    }

    func testSetLiveTranscriptUsesAuthoritativeFinalTextWhenDifferent() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["deep seek"],
                partialText: "",
                authoritativeText: "DeepSeek",
                isFinal: true
            )
        )

        XCTAssertEqual(appState.segments.count, 1)
        XCTAssertEqual(appState.segments.first?.text, "DeepSeek")
        XCTAssertTrue(appState.segments.first?.isConfirmed == true)
    }

    func testSetLiveTranscriptDropsStalePartialUpdates() {
        let appState = AppState()
        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["new"],
                partialText: "",
                authoritativeText: "new",
                isFinal: false
            )
        )

        appState.setLiveTranscript(
            RecognitionTranscript(
                confirmedSegments: ["old"],
                partialText: "",
                authoritativeText: "old",
                isFinal: false,
                emitTime: ContinuousClock.now - .seconds(1)
            )
        )

        XCTAssertEqual(appState.transcriptionText, "new")
    }

    func testFinalizeShowsClipboardFallbackMessage() {
        let appState = AppState()
        appState.barPhase = .processing

        appState.finalize(text: "测试文本", outcome: .copiedToClipboard)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.copiedToClipboard.completionMessage)
        XCTAssertEqual(appState.transcriptionText, "测试文本")
    }

    func testShowErrorDisplaysErrorPhaseAndMessage() {
        let appState = AppState()

        appState.showError("找不到麦克风")

        XCTAssertEqual(appState.barPhase, .error)
        XCTAssertEqual(appState.feedbackMessage, "找不到麦克风")
    }

    func testTransientNotificationUsesExistingCompletionPresentationWhenIdle() {
        let appState = AppState()
        var showCount = 0
        appState.onShowPanel = { showCount += 1 }

        appState.showTransientNotification("输入设备已切换至 AirPods Pro")

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, "输入设备已切换至 AirPods Pro")
        XCTAssertEqual(showCount, 1)
    }

    func testTransientNotificationDefersUntilRecordingEnds() {
        let appState = AppState()
        appState.barPhase = .recording

        appState.showTransientNotification("输入设备已切换至 AirPods Pro")

        XCTAssertEqual(appState.barPhase, .recording)

        appState.cancel()

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, "输入设备已切换至 AirPods Pro")
    }

    func testReconcileCurrentModeKeepsSupportedCustomModeForQuickOnlyProvider() {
        let appState = AppState()
        let customMode = ProcessingMode(
            id: UUID(),
            name: "结构化",
            prompt: "Rewrite {text}",
            isBuiltin: false
        )
        appState.availableModes.append(customMode)
        appState.currentMode = customMode

        appState.reconcileCurrentMode(for: .bailian)

        XCTAssertEqual(appState.currentMode.id, customMode.id)
    }

    func testCrossModeFinishPreferenceDefaultsToDisabled() {
        let suiteName = "CrossModeFinishPreferenceTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CrossModeFinishPreference.isEnabled(userDefaults: defaults))
    }

    func testCrossModeFinishPreferenceReadsChangesImmediately() {
        let suiteName = "CrossModeFinishPreferenceTests.changes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: CrossModeFinishPreference.storageKey)
        XCTAssertTrue(CrossModeFinishPreference.isEnabled(userDefaults: defaults))

        defaults.set(false, forKey: CrossModeFinishPreference.storageKey)
        XCTAssertFalse(CrossModeFinishPreference.isEnabled(userDefaults: defaults))
    }

    func testCrossModeFinishPreferenceSelectsExpectedProcessingMode() {
        let startingMode = ProcessingMode.direct
        let endingMode = ProcessingMode.smartDirect

        let retainedMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: false
        )
        XCTAssertEqual(retainedMode.id, startingMode.id)

        let switchedMode = CrossModeFinishPreference.processingMode(
            startingMode: startingMode,
            endingMode: endingMode,
            isEnabled: true
        )
        XCTAssertEqual(switchedMode.id, endingMode.id)
    }

    func testFinalizeShowsNoDestinationMessage() {
        let appState = AppState()
        appState.barPhase = .processing

        appState.finalize(text: "测试文本", outcome: .notInserted)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.notInserted.completionMessage)
    }

    func testFinalizeShowsCancelledMessageWhenResultIsNotRetained() {
        let appState = AppState()
        appState.barPhase = .processing

        appState.finalize(text: "测试文本", outcome: .discarded)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.discarded.completionMessage)
    }

    func testSuppressedCancellationHidesProcessingUntilItFinalizes() {
        let appState = AppState()
        appState.barPhase = .recording

        appState.stopRecording(suppressProcessingUI: true)

        XCTAssertEqual(appState.barPhase, .hidden)
        XCTAssertNil(appState.processingLabelOverride)

        appState.finalize(text: "原始识别", outcome: .copiedToClipboard)

        XCTAssertEqual(appState.barPhase, .done)
        XCTAssertEqual(appState.feedbackMessage, InjectionOutcome.copiedToClipboard.completionMessage)
    }

    func testLocalASREngineSelectionNeverDisablesBothEngines() {
        let qwenOnly = LocalASREngineSelection(
            senseVoiceEnabled: true,
            qwen3Enabled: false
        ).settingSenseVoice(false, qwen3Available: true)
        XCTAssertEqual(qwenOnly, LocalASREngineSelection(senseVoiceEnabled: false, qwen3Enabled: true))

        let senseVoiceOnly = LocalASREngineSelection(
            senseVoiceEnabled: false,
            qwen3Enabled: true
        ).settingQwen3(false)
        XCTAssertEqual(senseVoiceOnly, LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false))
    }

    func testLocalASREngineSelectionRejectsLastEngineDisableWhenQwenUnavailable() {
        let selection = LocalASREngineSelection(
            senseVoiceEnabled: true,
            qwen3Enabled: false
        ).settingSenseVoice(false, qwen3Available: false)

        XCTAssertEqual(selection, LocalASREngineSelection(senseVoiceEnabled: true, qwen3Enabled: false))
    }
}
