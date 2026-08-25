import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)

private enum FloatingBarTopOverlay: Equatable {
    case transcript
    case action(RecordingControlAction)
    case mode
}

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var feedbackMessage: String { get }
    var feedbackKind: FeedbackKind { get }
    var processingFinishTime: Date? { get }
    var transcriptionText: String { get }
    var recordingStartDate: Date? { get }
    var pinsTranscriptPopup: Bool { get }
    /// True when recording without SenseVoice streaming (Qwen3-only).
    var isQwen3OnlyMode: Bool { get }
    var effectiveProcessingLabel: String { get }
    var activityKind: RecordingActivityKind { get }
    var latestReviseUndoTicketID: UUID? { get }
    func performRecordingControlAction(_ action: RecordingControlAction)
    func performReviseUndo()
}

struct FloatingBarPresentation: Equatable {
    var indicatorStyle: RecordingIndicatorStyle = .regular
    var visualStyle: RecordingVisualStyle = .timeline
    var showsLiveTranscript: Bool = true
    var enablesHoverTranscriptPreview: Bool = true
    var showsTooltips: Bool = true
    var showsCancelButton: Bool = true

    var showsRecordingIndicator: Bool {
        indicatorStyle == .compact || visualStyle.showsRecordingPanel
    }
}

/// Dark-themed floating transcription bar.
///
/// Design: state changes are immediate; recording starts directly in the full
/// listening UI even while the audio service is still preparing internally.
/// - Recording: static dot + live text + completion/cancellation controls
/// - Processing: selected background effect + centered status text
/// - Done: immediate feedback message
struct FloatingBarView<S: FloatingBarState>: View {

    let state: S
    let presentationOverride: FloatingBarPresentation?

    init(
        state: S,
        presentationOverride: FloatingBarPresentation? = nil
    ) {
        self.state = state
        self.presentationOverride = presentationOverride
    }

    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = TF.barHeight
    @State private var processingStartDate: Date?
    @State private var doneStartDate: Date?
    @State private var isTranscriptHoverActive = false
    @State private var transcriptHoverExitTask: Task<Void, Never>?
    @State private var hoveredAction: RecordingControlAction?
    @State private var showsModeHint = false
    @State private var modeHintTask: Task<Void, Never>?
    @State private var recordingActionLocked = false
    @AppStorage(RecordingIndicatorStyle.storageKey) private var indicatorStyle = RecordingIndicatorStyle.defaultValue
    @AppStorage(LiveTranscriptDisplayPreference.storageKey) private var showLiveTranscript = LiveTranscriptDisplayPreference.defaultValue
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage(AppearancePreferenceDefaults.showTooltipsKey) private var showTooltips = AppearancePreferenceDefaults.showTooltipsDefault
    @AppStorage(AppearancePreferenceDefaults.showCancelButtonKey) private var showCancelButton = AppearancePreferenceDefaults.showCancelButtonDefault
    @AppStorage(RecordingVisualStyle.storageKey) private var visualStyle = RecordingVisualStyle.defaultValue
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    // MARK: - Presentation Resolution

    private var effectiveIndicatorStyle: RecordingIndicatorStyle {
        presentationOverride?.indicatorStyle
            ?? RecordingIndicatorStyle(rawValue: indicatorStyle)
            ?? .regular
    }

    private var effectiveRecordingVisualStyle: RecordingVisualStyle {
        presentationOverride?.visualStyle
            ?? RecordingVisualStyle(rawValue: visualStyle)
            ?? .timeline
    }

    private var effectiveShowsLiveTranscript: Bool {
        guard effectiveIndicatorStyle == .regular else { return false }
        return presentationOverride?.showsLiveTranscript ?? showLiveTranscript
    }

    private var effectiveHoverTranscriptPreview: Bool {
        guard effectiveIndicatorStyle == .regular else { return false }
        return presentationOverride?.enablesHoverTranscriptPreview ?? hoverTranscriptPreview
    }

    private var effectiveShowsTooltips: Bool {
        presentationOverride?.showsTooltips ?? showTooltips
    }

    private var effectiveShowsCancelButton: Bool {
        presentationOverride?.showsCancelButton ?? showCancelButton
    }

    private var currentRecordingChromeWidth: CGFloat {
        effectiveShowsCancelButton ? TF.recordingChromeWidth : TF.recordingSingleButtonChromeWidth
    }

    private var usesCompactPresentation: Bool {
        effectiveIndicatorStyle == .compact && state.barPhase != .hidden
    }

    private var usesCompactRecordingLayout: Bool {
        effectiveIndicatorStyle == .compact
            && (state.barPhase == .preparing || state.barPhase == .recording)
    }

    // MARK: - Transcript Popup

    private var recordingVisualStyle: RecordingVisualStyle {
        effectiveRecordingVisualStyle
    }

    private var showsTranscriptInCurrentPhase: Bool {
        LiveTranscriptDisplayPreference.showsTranscript(
            isEnabled: effectiveShowsLiveTranscript,
            phase: state.barPhase
        )
    }

    private var shouldRenderCapsule: Bool {
        guard state.barPhase != .hidden else { return false }
        if usesCompactPresentation {
            return true
        }
        return recordingVisualStyle.showsRecordingPanel
    }

    private var showTranscriptPopup: Bool {
        guard !usesCompactPresentation else { return false }
        guard recordingVisualStyle.showsRecordingPanel else { return false }
        guard showsTranscriptInCurrentPhase else { return false }
        if state.pinsTranscriptPopup {
            return !state.segments.isEmpty
        }
        if state.barPhase == .recovering {
            return !state.segments.isEmpty
        }
        guard recordingVisualStyle.showsRecordingPanel,
              effectiveHoverTranscriptPreview,
              isTranscriptHoverActive,
              state.barPhase == .recording,
              !state.segments.isEmpty
        else { return false }
        let textWidth = measureText(state.transcriptionText)
        return textWidth + currentRecordingChromeWidth > TF.barWidth
    }

    private var activeTopOverlay: FloatingBarTopOverlay? {
        if effectiveIndicatorStyle == .regular {
            guard recordingVisualStyle.showsRecordingPanel else { return nil }
        }
        if showTranscriptPopup { return .transcript }

        guard effectiveShowsTooltips else { return nil }

        if let hoveredAction, state.barPhase == .recording || state.barPhase == .preparing {
            return .action(hoveredAction)
        }
        if showsModeHint,
           (state.barPhase == .preparing || state.barPhase == .recording) {
            return .mode
        }
        return nil
    }

    private var capsuleHeight: CGFloat {
        usesCompactPresentation ? TF.compactIndicatorHeight : TF.barHeight
    }

    private var compactStatusIntrinsicWidth: CGFloat {
        let textFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        func measure(_ str: String) -> CGFloat {
            ceil((str as NSString).size(withAttributes: [.font: textFont]).width)
        }

        let basePadding: CGFloat = 20.0
        let iconWidth: CGFloat = 18.0

        switch state.barPhase {
        case .preparing, .recording, .hidden:
            return TF.compactIndicatorWidth
        case .processing, .recovering:
            let textW = measure(state.effectiveProcessingLabel)
            return basePadding + iconWidth + textW
        case .done:
            let textW = measure(state.feedbackMessage)
            var actionW: CGFloat = 0
            if state.activityKind == .revise && state.latestReviseUndoTicketID != nil {
                actionW = measure(L("撤销", "Undo")) + 22.0
            }
            return basePadding + iconWidth + textW + (actionW > 0 ? (actionW + 6.0) : 0)
        case .error:
            let textW = measure(state.feedbackMessage)
            return basePadding + iconWidth + textW
        }
    }

    private var compactCapsuleWidth: CGFloat {
        switch state.barPhase {
        case .preparing, .recording:
            return TF.compactIndicatorWidth
        case .processing, .recovering, .done, .error:
            return min(TF.compactStatusMaxWidth, max(44.0, compactStatusIntrinsicWidth))
        case .hidden:
            return 0
        }
    }

    private var capsuleWidth: CGFloat {
        if usesCompactPresentation {
            return compactCapsuleWidth
        }
        switch state.barPhase {
        case .preparing:
            let defaultWidth = measureText(recordingDisplayText) + currentRecordingChromeWidth
            return max(TF.barWidthCompact, defaultWidth)
        case .recording:
            guard effectiveShowsLiveTranscript, !state.segments.isEmpty else {
                let defaultWidth = measureText(recordingDisplayText) + currentRecordingChromeWidth
                return max(TF.barWidthCompact, defaultWidth)
            }
            return recordingPeakWidth
        case .processing:
            return min(TF.barWidth, max(110, measureText(state.effectiveProcessingLabel) + 66.0))
        case .recovering:
            return min(TF.barWidth, measureText(state.effectiveProcessingLabel) + 86.0)
        case .done:
            return feedbackWidth(for: state.feedbackMessage)
        case .error:
            return feedbackWidth(for: state.feedbackMessage)
        case .hidden:
            return TF.barHeight
        }
    }

    var body: some View {
        VStack(spacing: topOverlayGap) {
            if let overlay = activeTopOverlay {
                topOverlay(overlay)
            }

            if shouldRenderCapsule {
                capsuleBar
            }
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onChange(of: state.barPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: state.segments) { _, newSegments in
            guard !usesCompactPresentation, state.barPhase == .recording, effectiveShowsLiveTranscript else { return }
            let text = newSegments.map(\.text).joined()
            let textWidth = measureText(text)
            let needed = min(TF.barWidth, max(TF.barWidthCompact, textWidth + currentRecordingChromeWidth))
            if needed > recordingPeakWidth {
                recordingPeakWidth = needed
            } else if recordingPeakWidth - needed > 30 {
                recordingPeakWidth = needed
            }
        }
        .onChange(of: state.transcriptionText) { _, text in
            if !text.isEmpty && !usesCompactPresentation {
                dismissModeHint()
            }
        }
        .onChange(of: effectiveShowsLiveTranscript) { _, showsLive in
            guard !usesCompactPresentation, state.barPhase == .recording else { return }
            if showsLive && !state.segments.isEmpty {
                let text = state.transcriptionText
                let textWidth = measureText(text)
                let needed = min(TF.barWidth, max(TF.barWidthCompact, textWidth + currentRecordingChromeWidth))
                recordingPeakWidth = needed
            } else {
                let defaultWidth = min(TF.barWidth, max(TF.barWidthCompact, measureText(recordingDisplayText) + currentRecordingChromeWidth))
                recordingPeakWidth = defaultWidth
            }
        }
        .onDisappear {
            modeHintTask?.cancel()
            transcriptHoverExitTask?.cancel()
        }
    }

    // MARK: - Capsule Container

    private var capsuleBar: some View {
        barContent
            .frame(width: capsuleWidth, height: capsuleHeight)
            .clipShape(Capsule())
            .background {
                capsuleBackground
                    .clipShape(Capsule())
            }
            .shadow(color: Color(white: 0.08, opacity: 0.5), radius: 5, x: 0, y: 0)
            .animation(TF.springSnappy, value: capsuleWidth)
            .animation(TF.springSnappy, value: capsuleHeight)
    }

    // MARK: - Content by Phase

    @ViewBuilder
    private var barContent: some View {
        if usesCompactPresentation {
            compactPhaseContent
        } else {
            regularPhaseContent
        }
    }

    @ViewBuilder
    private var compactPhaseContent: some View {
        switch state.barPhase {
        case .preparing, .recording:
            compactRecordingContent
        case .processing:
            compactStatusContent(phase: .processing, text: state.effectiveProcessingLabel)
        case .recovering:
            compactStatusContent(phase: .recovering, text: state.effectiveProcessingLabel)
        case .done:
            compactDoneContent
        case .error:
            compactStatusContent(phase: .error, text: state.feedbackMessage)
        case .hidden:
            EmptyView()
        }
    }

    @ViewBuilder
    private var regularPhaseContent: some View {
        switch state.barPhase {
        case .preparing, .recording:
            recordingContent
        case .processing:
            processingContent
        case .recovering:
            recoveringContent
        case .done:
            doneContent
        case .error:
            errorContent
        case .hidden:
            EmptyView()
        }
    }

    private var compactRecordingContent: some View {
        HStack(spacing: 0) {
            compactRecordingButton(.finish)
                .frame(width: 32, height: TF.compactIndicatorHeight)

            CompactAudioIndicator(meter: state.audioLevel)
                .frame(maxWidth: .infinity, maxHeight: TF.compactIndicatorHeight)

            if effectiveShowsCancelButton {
                compactRecordingButton(.cancel)
                    .frame(width: 32, height: TF.compactIndicatorHeight)
            } else {
                Spacer().frame(width: TF.recordingEdgeInset)
            }
        }
        .frame(width: TF.compactIndicatorWidth, height: TF.compactIndicatorHeight)
    }

    @ViewBuilder
    private func compactStatusContent(phase: FloatingBarPhase, text: String) -> some View {
        HStack(spacing: 6) {
            compactPhaseIcon(phase)

            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 10)
        .frame(height: TF.compactIndicatorHeight)
        .accessibilityLabel(text)
    }

    @ViewBuilder
    private var compactDoneContent: some View {
        HStack(spacing: 6) {
            compactDoneIcon

            Text(state.feedbackMessage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if state.activityKind == .revise && state.latestReviseUndoTicketID != nil {
                Button(action: {
                    state.performReviseUndo()
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 9, weight: .semibold))
                        Text(L("撤销", "Undo"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(TF.floatingBackground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(TF.compactIndicatorActive)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: TF.compactIndicatorHeight)
        .accessibilityLabel(state.feedbackMessage)
    }

    @ViewBuilder
    private func compactPhaseIcon(_ phase: FloatingBarPhase) -> some View {
        switch phase {
        case .processing:
            ProgressView()
                .scaleEffect(0.42)
                .frame(width: 12, height: 12)
        case .recovering:
            Circle()
                .fill(TF.recording)
                .frame(width: 6, height: 6)
                .shadow(color: TF.recording.opacity(0.4), radius: 2)
        case .error:
            if let icon = feedbackIcon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(icon.color)
            } else {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(TF.settingsAccentRed)
            }
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var compactDoneIcon: some View {
        if let icon = feedbackIcon {
            Image(systemName: icon.symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(icon.color)
        } else {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(TF.success)
        }
    }

    private func compactRecordingButton(_ action: RecordingControlAction) -> some View {
        ZStack {
            Circle()
                .fill(TF.compactIndicatorActive)
                .frame(
                    width: TF.compactIndicatorControlVisualSize,
                    height: TF.compactIndicatorControlVisualSize
                )
                .overlay {
                    if action == .finish {
                        RoundedRectangle(cornerRadius: 1, style: .continuous)
                            .fill(TF.floatingBackground)
                            .frame(width: 6, height: 6)
                    } else {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(TF.floatingBackground)
                    }
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityLabel(action == .finish
            ? L("完成录制", "Finish Recording")
            : L("取消录制", "Cancel Recording"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            triggerRecordingAction(action)
        }
        .overlay {
            FloatingBarButtonInteraction(
                onHoverChanged: { hovered in
                    guard !recordingActionLocked else { return }
                    hoveredAction = hovered ? action : (hoveredAction == action ? nil : hoveredAction)
                },
                onClick: { triggerRecordingAction(action) }
            )
        }
    }

    private var recordingContent: some View {
        HStack(spacing: TF.recordingControlGap) {
            recordingButton(.finish)

            recordingText

            if effectiveShowsCancelButton {
                recordingButton(.cancel)
            }
        }
        .padding(.horizontal, TF.recordingEdgeInset)
    }

    private var recordingText: some View {
        Color.clear
            .overlay(alignment: recordingPeakWidth >= TF.barWidth ? .trailing : .center) {
                Text(recordingDisplayText)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TF.floatingText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .mask {
                if effectiveShowsLiveTranscript && !state.segments.isEmpty && recordingPeakWidth >= TF.barWidth {
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
            .background {
                FloatingBarHoverTracker { hovered in
                    updateTranscriptHover(hovered)
                }
            }
            .allowsHitTesting(true)
    }

    private var recordingDisplayText: String {
        guard effectiveShowsLiveTranscript, !state.segments.isEmpty else {
            return state.activityKind == .revise ? L("说说你想怎么改", "Say how to revise") : L("倾听中", "Listening")
        }
        return state.transcriptionText
    }

    private func recordingButton(_ action: RecordingControlAction) -> some View {
        ZStack {
            Circle()
                .fill(action == .finish ? TF.floatingControl : TF.floatingControlLight)

            if action == .finish {
                RecordingDot()
                    .allowsHitTesting(false)
            } else {
                Image(systemName: "xmark")
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(TF.floatingBackground)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: TF.recordingControlSize, height: TF.recordingControlSize)
        .contentShape(Circle())
        .accessibilityLabel(action == .finish
            ? L("完成录制", "Finish Recording")
            : L("取消录制", "Cancel Recording"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            triggerRecordingAction(action)
        }
        .overlay {
            FloatingBarButtonInteraction(
                onHoverChanged: { hovered in
                    guard !recordingActionLocked else { return }
                    hoveredAction = hovered ? action : (hoveredAction == action ? nil : hoveredAction)
                },
                onClick: { triggerRecordingAction(action) }
            )
        }
    }

    private func triggerRecordingAction(_ action: RecordingControlAction) {
        guard !recordingActionLocked else { return }
        recordingActionLocked = true
        hoveredAction = nil
        transcriptHoverExitTask?.cancel()
        isTranscriptHoverActive = false
        state.performRecordingControlAction(action)
    }

    private var processingContent: some View {
        ZStack {
            Text(state.effectiveProcessingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
    }

    private var recoveringContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(TF.recording)
                .frame(width: 10, height: 10)
                .shadow(color: TF.recording.opacity(0.4), radius: 3)

            Text(state.effectiveProcessingLabel)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 14)
    }

    private var doneContent: some View {
        Group {
            if state.activityKind == .revise && state.latestReviseUndoTicketID != nil {
                HStack(spacing: 8) {
                    Text(state.feedbackMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Button(action: {
                        state.performReviseUndo()
                    }) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.system(size: 11, weight: .semibold))
                            Text(L("撤销", "Undo"))
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(TF.floatingBackground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(TF.floatingControlLight)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            } else if let icon = feedbackIcon {
                HStack(spacing: 10) {
                    Image(systemName: icon.symbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(icon.color)
                    Text(state.feedbackMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
            } else {
                Text(state.feedbackMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var errorContent: some View {
        HStack(spacing: 10) {
            if let icon = feedbackIcon {
                Image(systemName: icon.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(icon.color)
            } else {
                ErrorDot()
            }

            Text(state.feedbackMessage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
    }

    /// SF Symbol + tint for the current feedback kind, or nil for the standard
    /// look (no leading icon, centered text — the existing `.done`/`.error` UI).
    private var feedbackIcon: (symbol: String, color: Color)? {
        switch state.feedbackKind {
        case .standard:
            return nil
        case .macActionSuccess:
            return ("checkmark.circle.fill", TF.success)
        case .macActionFailure:
            return ("xmark.circle.fill", TF.settingsAccentRed)
        case .macActionUnsure:
            return ("questionmark.circle.fill", TF.amber)
        }
    }

    // MARK: - Background & Border

    private var capsuleBackground: some View {
        ZStack {
            TF.floatingBackground

            if !usesCompactPresentation {
                if state.barPhase == .recording,
                   recordingVisualStyle.showsBackgroundEffect {
                    AudioRipple(meter: state.audioLevel, style: recordingVisualStyle)
                        .id(recordingVisualStyle.rawValue)
                }

                if (state.barPhase == .processing || state.barPhase == .recovering || state.barPhase == .done),
                   recordingVisualStyle.showsBackgroundEffect {
                    ProcessingProgress(
                        style: recordingVisualStyle,
                        finishTime: state.processingFinishTime,
                        processingStartDate: processingStartDate,
                        doneStartDate: doneStartDate
                    )
                }

                if state.barPhase == .error {
                    LinearGradient(
                        colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                        startPoint: .leading,
                        endPoint: UnitPoint(x: 0.45, y: 0.5)
                    )
                }
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
            .white.opacity(0.05)
        case .recording:
            .white.opacity(0.05)
        case .processing:
            .white.opacity(0.07)
        case .recovering:
            .white.opacity(0.12)
        case .done:
            switch state.feedbackKind {
            case .macActionUnsure:
                TF.amber.opacity(0.30)
            case .macActionSuccess, .macActionFailure, .standard:
                TF.success.opacity(0.3)
            }
        case .error:
            TF.settingsAccentRed.opacity(0.22)
        case .hidden:
            .clear
        }
    }

    // MARK: - Phase Transitions

    private func handlePhaseChange(_ phase: FloatingBarPhase) {
        // Reset hover state on panel show/hide boundaries.
        // NSTrackingArea suspends events when the view is hidden (panel orderOut)
        // instead of firing mouseExited, so isHovered would otherwise leak across
        // recording sessions and auto-show the popup without any actual hover.
        if phase == .preparing || phase == .hidden {
            transcriptHoverExitTask?.cancel()
            isTranscriptHoverActive = false
            hoveredAction = nil
        }
        switch phase {
        case .preparing:
            let defaultWidth = max(TF.barWidthCompact, measureText(recordingDisplayText) + currentRecordingChromeWidth)
            recordingPeakWidth = defaultWidth
            processingStartDate = nil
            doneStartDate = nil
            recordingActionLocked = false
            if effectiveShowsTooltips {
                showModeHint()
            }
        case .recording:
            let defaultWidth = max(TF.barWidthCompact, measureText(recordingDisplayText) + currentRecordingChromeWidth)
            if recordingPeakWidth < defaultWidth {
                recordingPeakWidth = defaultWidth
            }
            recordingActionLocked = false
        case .processing:
            dismissModeHint()
            processingStartDate = Date()
            doneStartDate = nil
        case .recovering:
            dismissModeHint()
            processingStartDate = Date()
            doneStartDate = nil
        case .done:
            dismissModeHint()
            doneStartDate = Date()
        case .error:
            dismissModeHint()
        default:
            dismissModeHint()
        }
    }

    private func feedbackWidth(for message: String) -> CGFloat {
        if state.activityKind == .revise && state.latestReviseUndoTicketID != nil {
            let undoWidth = measureText(L("撤销", "Undo")) + 38.0
            return min(TF.barWidth, max(140, measureText(message) + undoWidth + 50.0))
        }
        // Reserve extra room when an SF Symbol icon is shown (icon + spacing).
        let iconExtra: CGFloat = feedbackIcon == nil ? 0 : 26
        return min(TF.barWidth, max(110, measureText(message) + 66.0 + iconExtra))
    }

    /// Measure actual rendered width using the same font as the floating bar text.
    private func measureText(_ string: String) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: floatingBarFont]).width)
    }

    // MARK: - Top overlays

    private var topOverlayGap: CGFloat {
        switch activeTopOverlay {
        case .action, .mode:
            return TF.recordingTooltipGap
        case .transcript, nil:
            return TF.transcriptPopupGap
        }
    }

    @ViewBuilder
    private func topOverlay(_ overlay: FloatingBarTopOverlay) -> some View {
        switch overlay {
        case .transcript:
            TranscriptPopup(
                text: state.transcriptionText,
                onHoverChanged: updateTranscriptHover
            )
        case .mode:
            hintBubble(text: localizedCurrentModeName)
                .transaction { $0.animation = nil }
        case .action(.finish):
            alignedActionHint(.finish)
        case .action(.cancel):
            alignedActionHint(.cancel)
        }
    }

    private var localizedCurrentModeName: String {
        // The floating bar stays alive across language changes, so it must
        // observe the preference instead of retaining a launch-time string.
        _ = language
        return state.currentMode.localizedDisplayName
    }

    private func alignedActionHint(_ action: RecordingControlAction) -> some View {
        let distanceFromCenter: CGFloat
        if usesCompactRecordingLayout {
            distanceFromCenter = capsuleWidth / 2 - 16
        } else {
            distanceFromCenter = capsuleWidth / 2
                - TF.recordingEdgeInset
                - TF.recordingControlSize / 2
        }
        let horizontalOffset = action == .finish ? -distanceFromCenter : distanceFromCenter

        return actionHintBubble(action)
            .offset(x: horizontalOffset)
            .frame(width: capsuleWidth)
    }

    private func actionHintBubble(_ action: RecordingControlAction) -> some View {
        HStack(spacing: 7) {
            Text(action == .finish
                ? L("完成录制", "Finish Recording")
                : L("取消录制", "Cancel Recording"))

            if action == .cancel {
                Text("esc")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.floatingText)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TF.recordingTooltipBadge))
            }
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(TF.floatingText)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                .fill(TF.floatingBackground)
        )
        .frame(maxWidth: TF.recordingTooltipMaxWidth)
        .fixedSize(horizontal: true, vertical: false)
    }

    private func hintBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TF.floatingText)
            .lineLimit(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                    .fill(TF.floatingBackground)
            )
    }

    private func showModeHint() {
        modeHintTask?.cancel()
        showsModeHint = true
        modeHintTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            showsModeHint = false
        }
    }

    private func dismissModeHint() {
        modeHintTask?.cancel()
        modeHintTask = nil
        if showsModeHint {
            showsModeHint = false
        }
    }

    private func updateTranscriptHover(_ hovering: Bool) {
        transcriptHoverExitTask?.cancel()
        if hovering {
            isTranscriptHoverActive = true
            return
        }

        transcriptHoverExitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            isTranscriptHoverActive = false
        }
    }
}

private struct TranscriptPopup: View {
    let text: String
    let onHoverChanged: (Bool) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                Text(text)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(TF.floatingText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)

                Color.clear
                    .frame(height: 1)
                    .id("transcript-end")
            }
            .scrollIndicators(.hidden)
            .frame(width: TF.transcriptPopupWidth)
            .frame(maxHeight: TF.transcriptPopupMaxHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                    .fill(TF.floatingBackground)
            )
            .overlay {
                FloatingBarHoverTracker(onHoverChanged: onHoverChanged)
            }
            .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
            .shadow(color: Color.black.opacity(0.3), radius: 8, y: -2)
            .onAppear { proxy.scrollTo("transcript-end", anchor: .bottom) }
            .onChange(of: text) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
    }
}

// MARK: - Recording Dot

/// Static recording dot. Recording background effects are rendered separately
/// according to the user's configured visual style.
struct RecordingDot: View {
    var body: some View {
        Circle()
            .fill(TF.recording)
            .frame(width: 10, height: 10)
            .shadow(color: TF.recording.opacity(0.4), radius: 3)
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

/// Processing progress that preserves the user's selected recording visual style.
/// The timing is shared by all styles; only the rendering changes.
/// - Fast phase: 0% → 70% in 1.5s (ease-out)
/// - Slow cruise: 70% → 95% asymptotically (never stalls, always creeping)
/// When processingFinishTime is set, sprints toward 100% in 0.3s.
/// When doneStartDate is set, fills remaining gap to 100% in 0.15s.
/// All timing comes from parent — no @State, so view recreation is harmless.
struct ProcessingProgress: View {

    let style: RecordingVisualStyle
    let finishTime: Date?
    var processingStartDate: Date?
    var doneStartDate: Date?

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let startRef = processingStartDate?.timeIntervalSinceReferenceDate ?? time
                let elapsed = time - startRef

                var progress: CGFloat
                let cruiseProgress: CGFloat
                if elapsed <= 1.5 {
                    // Fast phase: ease-out to 70%
                    let t = min(1.0, CGFloat(elapsed / 1.5))
                    cruiseProgress = t * 0.7 * (2.0 - t)
                } else {
                    // Slow cruise: 70% → 95%, exponential approach (τ=6s)
                    let slowT = 1.0 - exp(-(elapsed - 1.5) / 6.0)
                    cruiseProgress = 0.7 + CGFloat(slowT) * 0.25
                }

                if let finishTime {
                    let finishElapsed = time - finishTime.timeIntervalSinceReferenceDate
                    let sprintT = min(1.0, CGFloat(finishElapsed / 0.3))
                    progress = cruiseProgress + (1.0 - cruiseProgress) * sprintT
                } else {
                    progress = cruiseProgress
                }

                // Done: fill remaining gap to 100% in 0.15s
                if let doneStartDate {
                    let doneElapsed = time - doneStartDate.timeIntervalSinceReferenceDate
                    let doneT = min(1.0, CGFloat(doneElapsed / 0.15))
                    let base = max(progress, 0.7)
                    progress = base + (1.0 - base) * doneT
                }

                switch style {
                case .classic:
                    drawLines(context: &context, size: size, time: time, progress: progress)
                case .dual:
                    drawParticles(context: &context, size: size, time: time, progress: progress)
                case .timeline:
                    drawLevels(context: &context, size: size, time: time, progress: progress)
                case .effectless, .hidden:
                    break
                }
            }
        }
        .drawingGroup()
    }

    private func drawLines(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        progress: CGFloat
    ) {
        let center = size.height / 2
        let fillEdge = progress * size.width
        for index in 0..<2 {
            var path = Path()
            let phase = time * (index == 0 ? 2.2 : 1.6) + Double(index) * 1.4
            var x: CGFloat = 0
            while x <= fillEdge {
                let envelope = sin(.pi * min(1, x / max(size.width, 1)))
                let y = center + sin(Double(x) / (index == 0 ? 24 : 34) + phase)
                    * Double(envelope * size.height * (index == 0 ? 0.22 : 0.13))
                if x == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
                x += 2
            }
            context.stroke(
                path,
                with: .linearGradient(
                    Gradient(colors: [.white.opacity(0.35), Color.blue.opacity(0.55)]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: center)
                ),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )
        }
    }

    private func drawLevels(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        progress: CGFloat
    ) {
        let center = size.height / 2
        let fillEdge = progress * size.width
        var x: CGFloat = 3
        while x < fillEdge {
            let wave = 0.25 + 0.75 * abs(sin(Double(x) * 0.11 + time * 3.4))
            let height = CGFloat(wave) * size.height * 0.64
            let rect = CGRect(x: x, y: center - height / 2, width: 2, height: height)
            let opacity = 0.18 + 0.35 * Double(x / max(size.width, 1))
            context.fill(
                RoundedRectangle(cornerRadius: 1).path(in: rect),
                with: .color(Color(red: 0.56, green: 0.68, blue: 1).opacity(opacity))
            )
            x += 5
        }
    }

    private func drawParticles(
        context: inout GraphicsContext,
        size: CGSize,
        time: Double,
        progress: CGFloat
    ) {
                // Push soft leading edge past visible boundary when full.
                let fillEdge = progress * size.width + (progress >= 0.99 ? 20 : 0)
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
    let style: RecordingVisualStyle
    @State private var smootherSlow = LevelSmoother(timeConstant: 0.8)
    @State private var smootherFast = LevelSmoother(timeConstant: 0)
    @State private var startTime: Double = 0
    @State private var levelTimeline = LevelTimeline()

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                switch style {
                case .classic: drawClassicWaves(context: &context, size: size, time: time)
                case .dual: drawDualSpine(context: &context, size: size, time: time)
                case .timeline: drawTimeline(context: &context, size: size, time: time)
                case .effectless, .hidden: break
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

// MARK: - Hover Tracking (works even when app is not active)

/// AppKit-backed click target for controls hosted in a non-activating panel.
/// `acceptsFirstMouse` makes the first click actionable even while another app
/// owns focus, which SwiftUI `Button` does not reliably guarantee here.
private struct FloatingBarButtonInteraction: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> FloatingBarButtonNSView {
        let view = FloatingBarButtonNSView()
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: FloatingBarButtonNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
        nsView.onClick = onClick
    }
}

final class FloatingBarButtonNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}

/// Uses NSTrackingArea with `.activeAlways` so hover fires on a non-key,
/// non-activating NSPanel regardless of which app is in the foreground.
struct FloatingBarHoverTracker: NSViewRepresentable {
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: HoverTrackingNSView, context: Context) {
        nsView.onHoverChanged = onHoverChanged
    }
}

final class HoverTrackingNSView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    private var enterWorkItem: DispatchWorkItem?

    /// Tracking areas should observe hover without intercepting SwiftUI button
    /// clicks or scroll-wheel events from controls underneath this helper view.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        enterWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let window = self.window else { return }
            // Re-check mouse position at trigger time: updateTrackingAreas()
            // sends synthetic mouseEntered when the tracking area is recreated
            // with the cursor inside (e.g. bar grows during recording).
            let mouseInView = self.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard self.bounds.contains(mouseInView) else { return }
            self.onHoverChanged?(true)
        }
        enterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        enterWorkItem?.cancel()
        onHoverChanged?(false)
    }
}
