import SwiftUI

/// Cached font for text measurement (module-level to avoid generic-type static restriction).
private let floatingBarFont = NSFont.systemFont(ofSize: 14, weight: .medium)

private enum FloatingBarTopOverlay: Equatable {
    case transcript
    case action(RecordingControlAction)
    case mode
}

// MARK: - Thinking States Text Swap Transition

private struct TextSwapTransitionModifier: ViewModifier {
    let y: CGFloat
    let blur: CGFloat
    let opacity: Double

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .offset(y: reduceMotion ? 0 : y)
            .blur(radius: reduceMotion ? 0 : blur)
            .opacity(opacity)
    }
}

extension AnyTransition {
    /// Transitions.dev Thinking States text swap animation:
    /// - 150ms ease-in-out duration
    /// - Outgoing text translates up by 8pt with 2pt blur and fades to 0
    /// - Incoming text enters from 8pt below with 2pt blur and fades to 1
    static var textSwap: AnyTransition {
        .asymmetric(
            insertion: .modifier(
                active: TextSwapTransitionModifier(y: 8, blur: 2, opacity: 0),
                identity: TextSwapTransitionModifier(y: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: TextSwapTransitionModifier(y: -8, blur: 2, opacity: 0),
                identity: TextSwapTransitionModifier(y: 0, blur: 0, opacity: 1)
            )
        )
    }
}

func recordingActionHorizontalOffset(
    _ action: RecordingControlAction,
    capsuleWidth: CGFloat,
    usesCompactLayout: Bool
) -> CGFloat {
    let distanceFromCenter: CGFloat
    if usesCompactLayout {
        distanceFromCenter = capsuleWidth / 2 - 16
    } else if action == .finish {
        distanceFromCenter = capsuleWidth / 2
            - TF.recordingLeadingInset
            - TF.recordingFinishControlSize / 2
    } else {
        distanceFromCenter = capsuleWidth / 2
            - TF.recordingTrailingInset
            - TF.recordingCancelControlSize / 2
    }
    return action == .finish ? -distanceFromCenter : distanceFromCenter
}

// MARK: - FloatingBarState Protocol

@MainActor
protocol FloatingBarState: AnyObject, Observable {
    var barPhase: FloatingBarPhase { get }
    var segments: [TranscriptionSegment] { get }
    var audioLevel: AudioLevelMeter { get }
    var currentMode: ProcessingMode { get }
    var recordingProvider: ASRProvider? { get }
    var recordingModelName: String? { get }
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
    var visualStyle: RecordingVisualStyle = .siri
    var showsLiveTranscript: Bool = true
    var enablesHoverTranscriptPreview: Bool = true
    var showsTooltips: Bool = true
    var showsCancelButton: Bool = true
    var showsModeName: Bool = RecordingMetadataDisplayPreference.showModeNameDefault
    var showsProviderName: Bool = RecordingMetadataDisplayPreference.showProviderNameDefault
    var showsModelName: Bool = RecordingMetadataDisplayPreference.showModelNameDefault

    var showsRecordingIndicator: Bool {
        true
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
    let onPanelLayoutChange: ((FloatingBarPanelLayout) -> Void)?

    init(
        state: S,
        presentationOverride: FloatingBarPresentation? = nil,
        onPanelLayoutChange: ((FloatingBarPanelLayout) -> Void)? = nil
    ) {
        self.state = state
        self.presentationOverride = presentationOverride
        self.onPanelLayoutChange = onPanelLayoutChange
    }

    /// High-water mark: only grows during recording, never shrinks (prevents ASR correction jitter)
    @State private var recordingPeakWidth: CGFloat = TF.barHeight
    @State private var processingStartDate: Date?
    @State private var doneStartDate: Date?
    @State private var isTranscriptHoverActive = false
    @State private var transcriptHoverExitTask: Task<Void, Never>?
    @State private var hoveredAction: RecordingControlAction?
    @State private var hintedAction: RecordingControlAction?
    @State private var actionHintTask: Task<Void, Never>?
    @State private var pressedAction: RecordingControlAction?
    @State private var cancelDragOffset: CGSize = .zero
    @State private var showsModeHint = false
    @State private var modeHintTask: Task<Void, Never>?
    @State private var recordingActionLocked = false
    @AppStorage(RecordingIndicatorStyle.storageKey) private var indicatorStyle = RecordingIndicatorStyle.defaultValue
    @AppStorage(LiveTranscriptDisplayPreference.storageKey) private var showLiveTranscript = LiveTranscriptDisplayPreference.defaultValue
    @AppStorage("tf_hoverTranscriptPreview") private var hoverTranscriptPreview = true
    @AppStorage(AppearancePreferenceDefaults.showTooltipsKey) private var showTooltips = AppearancePreferenceDefaults.showTooltipsDefault
    @AppStorage(AppearancePreferenceDefaults.showCancelButtonKey) private var showCancelButton = AppearancePreferenceDefaults.showCancelButtonDefault
    @AppStorage(RecordingVisualStyle.storageKey) private var visualStyle = RecordingVisualStyle.defaultValue
    @AppStorage(RecordingMetadataDisplayPreference.showModeNameKey)
    private var showModeName = RecordingMetadataDisplayPreference.showModeNameDefault
    @AppStorage(RecordingMetadataDisplayPreference.showProviderNameKey)
    private var showProviderName = RecordingMetadataDisplayPreference.showProviderNameDefault
    @AppStorage(RecordingMetadataDisplayPreference.showModelNameKey)
    private var showModelName = RecordingMetadataDisplayPreference.showModelNameDefault
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
            ?? .siri
    }

    private var effectiveShowsLiveTranscript: Bool {
        presentationOverride?.showsLiveTranscript ?? showLiveTranscript
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

    private var effectiveShowsModeName: Bool {
        presentationOverride?.showsModeName ?? showModeName
    }

    private var effectiveShowsProviderName: Bool {
        presentationOverride?.showsProviderName ?? showProviderName
    }

    private var effectiveShowsModelName: Bool {
        presentationOverride?.showsModelName ?? showModelName
    }

    private var usesCompactPresentation: Bool {
        effectiveIndicatorStyle == .compact && state.barPhase != .hidden
    }

    private var usesCompactRecordingLayout: Bool {
        effectiveIndicatorStyle == .compact
            && (state.barPhase == .preparing || state.barPhase == .recording)
    }

    private var usesCompactExpandedRecordingLayout: Bool {
        usesCompactRecordingLayout && effectiveShowsLiveTranscript
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
        state.barPhase != .hidden
    }

    private var showTranscriptPopup: Bool {
        guard !usesCompactPresentation else { return false }
        guard showsTranscriptInCurrentPhase else { return false }
        if state.pinsTranscriptPopup {
            return !state.segments.isEmpty
        }
        if state.barPhase == .recovering {
            return !state.segments.isEmpty
        }
        guard effectiveHoverTranscriptPreview,
              isTranscriptHoverActive,
              state.barPhase == .recording,
              !state.segments.isEmpty
        else { return false }
        let textWidth = measureText(state.transcriptionText)
        return textWidth + currentRecordingChromeWidth > TF.barWidth
    }

    private var activeTopOverlay: FloatingBarTopOverlay? {
        if showTranscriptPopup { return .transcript }

        guard effectiveShowsTooltips else { return nil }

        if let hintedAction, state.barPhase == .recording || state.barPhase == .preparing {
            return .action(hintedAction)
        }
        if showsModeHint,
           recordingMetadataText != nil,
           (state.barPhase == .preparing || state.barPhase == .recording) {
            return .mode
        }
        return nil
    }

    private var capsuleHeight: CGFloat {
        guard usesCompactPresentation else { return TF.barHeight }
        return usesCompactExpandedRecordingLayout
            ? TF.compactTranscriptExpandedHeight
            : TF.compactIndicatorHeight
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

    private var baseRecordingWidth: CGFloat {
        let placeholder = state.activityKind == .revise ? L("说说你想怎么改", "Say how to revise") : L("倾听中", "Listening")
        return max(TF.barWidthCompact, measureText(placeholder) + currentRecordingChromeWidth)
    }

    /// Monotonic target width for the recording capsule during a live-transcript
    /// session. Grows only; never shrinks mid-recording so ASR partial
    /// corrections cannot make the capsule jitter.
    private func recordingNeededWidth(for text: String) -> CGFloat {
        min(TF.barWidth, max(baseRecordingWidth, measureText(text) + currentRecordingChromeWidth))
    }

    private var capsuleWidth: CGFloat {
        if usesCompactPresentation {
            return compactCapsuleWidth
        }
        switch state.barPhase {
        case .preparing:
            return baseRecordingWidth
        case .recording:
            // Once recording, the width is driven purely by the monotonic
            // recordingPeakWidth state (reset to base on `.preparing`). We must
            // NOT fall back to baseRecordingWidth when `state.segments` briefly
            // becomes empty (ASR clears the partial during pauses/corrections),
            // otherwise the capsule collapses and re-expands, which is the main
            // source of the visible width jitter.
            guard effectiveShowsLiveTranscript else {
                return baseRecordingWidth
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

    private var panelLayout: FloatingBarPanelLayout {
        guard shouldRenderCapsule else { return .hidden }

        let capsuleSize = NSSize(width: capsuleWidth, height: capsuleHeight)
        guard let overlay = activeTopOverlay else {
            return FloatingBarPanelLayout(
                contentSize: capsuleSize,
                capsuleSize: capsuleSize
            )
        }

        let overlaySize = topOverlaySize(overlay)
        let contentWidth: CGFloat
        let horizontalOverflow: CGFloat

        switch overlay {
        case .transcript:
            contentWidth = max(capsuleSize.width, overlaySize.width)
            horizontalOverflow = 0
        case .mode:
            contentWidth = max(capsuleSize.width, overlaySize.width)
            horizontalOverflow = 0
        case .action(let action):
            contentWidth = capsuleSize.width
            horizontalOverflow = actionOverlayOverflow(
                action: action,
                bubbleWidth: overlaySize.width
            )
        }

        return FloatingBarPanelLayout(
            contentSize: NSSize(
                width: contentWidth,
                height: capsuleSize.height + topOverlayGap + overlaySize.height
            ),
            horizontalOverflow: horizontalOverflow,
            capsuleSize: capsuleSize
        )
    }

    private func updateRecordingPeakWidthIfNeeded() {
        guard !usesCompactPresentation, state.barPhase == .recording, effectiveShowsLiveTranscript else {
            if !effectiveShowsLiveTranscript && state.barPhase == .recording {
                recordingPeakWidth = baseRecordingWidth
            }
            return
        }
        let text = state.transcriptionText.isEmpty
            ? state.segments.map(\.text).joined()
            : state.transcriptionText
        guard !text.isEmpty else { return }
        let needed = recordingNeededWidth(for: text)
        if needed > recordingPeakWidth {
            recordingPeakWidth = needed
        }
    }

    var body: some View {
        VStack(spacing: topOverlayGap) {
            if let overlay = activeTopOverlay {
                topOverlay(overlay)
            }

            if shouldRenderCapsule {
                capsuleBar
                    .id("floating_capsule_bar")
            }
        }
        .padding(TF.floatingPanelShadowInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .onAppear {
            updateRecordingPeakWidthIfNeeded()
            onPanelLayoutChange?(panelLayout)
        }
        .onChange(of: panelLayout) { _, layout in
            onPanelLayoutChange?(layout)
        }
        .onChange(of: state.barPhase) { _, newPhase in
            handlePhaseChange(newPhase)
        }
        .onChange(of: state.segments) { _, _ in
            updateRecordingPeakWidthIfNeeded()
        }
        .onChange(of: state.transcriptionText) { _, text in
            if !text.isEmpty && !usesCompactPresentation {
                dismissModeHint()
            }
            updateRecordingPeakWidthIfNeeded()
        }
        .onChange(of: effectiveShowsLiveTranscript) { _, showsLive in
            if showsLive {
                updateRecordingPeakWidthIfNeeded()
            } else {
                recordingPeakWidth = baseRecordingWidth
            }
        }
        .onChange(of: effectiveIndicatorStyle) { _, newStyle in
            if newStyle == .regular {
                updateRecordingPeakWidthIfNeeded()
            }
        }
        .onDisappear {
            modeHintTask?.cancel()
            transcriptHoverExitTask?.cancel()
            actionHintTask?.cancel()
        }
    }

    // MARK: - Capsule Container

    private var barCornerRadius: CGFloat {
        if usesCompactExpandedRecordingLayout {
            return TF.compactTranscriptCornerRadius
        }
        return capsuleHeight / 2
    }

    private var barShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous)
    }

    private var capsuleBar: some View {
        barContent
            .frame(width: capsuleWidth, height: capsuleHeight)
            .clipShape(barShape)
            .background {
                capsuleBackground
                    .clipShape(barShape)
            }
            .overlay {
                capsuleBorder
            }
            .shadow(color: Color.black.opacity(0.12), radius: 8)
            // Critically damped (dampingFraction 1.0) so the width never
            // overshoots and settles back leftward between characters. An
            // underdamped spring makes the right edge/cancel button wiggle
            // "inward then outward" on every widen while the left (MTKView orb)
            // edge jumps instantly and appears stable.
            .animation(
                .spring(response: TF.recordingCapsuleSpringResponse, dampingFraction: 1.0),
                value: capsuleWidth
            )
            .animation(
                .spring(response: TF.recordingCapsuleSpringResponse, dampingFraction: 1.0),
                value: capsuleHeight
            )
            .animation(
                .spring(response: TF.recordingCapsuleSpringResponse, dampingFraction: 1.0),
                value: barCornerRadius
            )
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
        ZStack {
            switch state.barPhase {
            case .preparing, .recording:
                compactRecordingContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .processing:
                compactStatusContent(phase: .processing, text: state.effectiveProcessingLabel)
                    .transition(.textSwap.animation(.easeInOut(duration: 0.15)))
            case .recovering:
                compactStatusContent(phase: .recovering, text: state.effectiveProcessingLabel)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .done:
                compactDoneContent
                    .transition(.textSwap.animation(.easeInOut(duration: 0.15)))
            case .error:
                compactStatusContent(phase: .error, text: state.feedbackMessage)
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .hidden:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.barPhase)
    }

    @ViewBuilder
    private var regularPhaseContent: some View {
        ZStack {
            switch state.barPhase {
            case .preparing, .recording:
                recordingContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .processing:
                processingContent
                    .transition(.textSwap.animation(.easeInOut(duration: 0.15)))
            case .recovering:
                recoveringContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .done:
                doneContent
                    .transition(.textSwap.animation(.easeInOut(duration: 0.15)))
            case .error:
                errorContent
                    .transition(.opacity.animation(.easeInOut(duration: 0.18)))
            case .hidden:
                EmptyView()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: state.barPhase)
    }

    private var compactRecordingControls: some View {
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
    private var compactRecordingContent: some View {
        if effectiveShowsLiveTranscript {
            VStack(spacing: 0) {
                CompactLiveTranscriptRow(text: state.transcriptionText)
                compactRecordingControls
            }
            .frame(width: TF.compactIndicatorWidth, height: TF.compactTranscriptExpandedHeight)
        } else {
            compactRecordingControls
        }
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
                onPressChanged: { pressed in
                    guard !recordingActionLocked else { return }
                    pressedAction = pressed ? action : (pressedAction == action ? nil : pressedAction)
                },
                onHoverChanged: { hovered in
                    guard !recordingActionLocked else { return }
                    updateActionHover(action, hovering: hovered)
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
        .padding(.leading, TF.recordingLeadingInset)
        .padding(.trailing, TF.recordingTrailingInset)
    }

    private var isLiveTranscriptTrailingAligned: Bool {
        effectiveShowsLiveTranscript && !state.segments.isEmpty && recordingPeakWidth >= TF.barWidth
    }

    private var recordingText: some View {
        // The text is an overlay on a flexible Color.clear so it never
        // participates in the HStack layout: it can never push the cancel
        // button, and the cancel button can never overlap it. The clear region
        // is exactly the space between the two controls; the text is masked to
        // it, so overflow only fades on the leading edge.
        Color.clear
            .overlay(alignment: isLiveTranscriptTrailingAligned ? .trailing : .center) {
                recordingTextContent
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .mask {
                if isLiveTranscriptTrailingAligned {
                    HStack(spacing: 0) {
                        LinearGradient(
                            colors: [.clear, .white],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 14)
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

    @ViewBuilder
    private var recordingTextContent: some View {
        if effectiveShowsLiveTranscript && !state.segments.isEmpty {
            Text(state.transcriptionText)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(TF.floatingText)
        } else {
            LiquidGlassText(
                text: recordingDisplayText,
                style: recordingVisualStyle,
                audioEnergy: state.audioLevel.current
            )
        }
    }

    private var recordingDisplayText: String {
        guard effectiveShowsLiveTranscript, !state.segments.isEmpty else {
            return state.activityKind == .revise ? L("说说你想怎么改", "Say how to revise") : L("倾听中", "Listening")
        }
        return state.transcriptionText
    }

    private func recordingButton(_ action: RecordingControlAction) -> some View {
        let size = action == .finish ? TF.recordingFinishControlSize : TF.recordingCancelControlSize
        return ZStack {
            if action == .finish {
                LiquidGlassOrb(
                    style: recordingVisualStyle,
                    audioEnergy: state.audioLevel.current,
                    isHovered: hoveredAction == .finish,
                    isPressed: pressedAction == .finish || recordingActionLocked
                )
                .id("recording_orb_button")
            } else {
                LiquidGlassCancelButton(
                    isHovered: hoveredAction == .cancel,
                    isPressed: pressedAction == .cancel || recordingActionLocked,
                    dragOffset: pressedAction == .cancel ? cancelDragOffset : .zero
                )
                .id("recording_cancel_button")
            }
        }
        .frame(width: size, height: size)
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
                onPressChanged: { pressed in
                    guard !recordingActionLocked else { return }
                    pressedAction = pressed ? action : (pressedAction == action ? nil : pressedAction)
                    if !pressed && action == .cancel {
                        cancelDragOffset = .zero
                    }
                },
                onDragOffsetChanged: action == .cancel ? { offset in
                    guard !recordingActionLocked else { return }
                    cancelDragOffset = offset
                } : nil,
                onHoverChanged: { hovered in
                    guard !recordingActionLocked else { return }
                    updateActionHover(action, hovering: hovered)
                },
                onClick: { triggerRecordingAction(action) }
            )
        }
    }

    private func triggerRecordingAction(_ action: RecordingControlAction) {
        guard presentationOverride == nil else { return }
        guard !recordingActionLocked else { return }
        recordingActionLocked = true
        pressedAction = nil
        cancelDragOffset = .zero
        hoveredAction = nil
        hintedAction = nil
        actionHintTask?.cancel()
        transcriptHoverExitTask?.cancel()
        isTranscriptHoverActive = false
        state.performRecordingControlAction(action)
    }

    private var processingContent: some View {
        LiquidGlassText(
            text: state.effectiveProcessingLabel,
            style: recordingVisualStyle,
            audioEnergy: 0.25
        )
        .frame(maxWidth: .infinity)
    }

    private var recoveringContent: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(TF.recording)
                .frame(width: 10, height: 10)
                .shadow(color: TF.recording.opacity(0.4), radius: 3)

            LiquidGlassText(
                text: state.effectiveProcessingLabel,
                style: recordingVisualStyle,
                audioEnergy: 0.25
            )
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

            if state.barPhase == .error {
                LinearGradient(
                    colors: [TF.settingsAccentRed.opacity(0.16), .clear],
                    startPoint: .leading,
                    endPoint: UnitPoint(x: 0.45, y: 0.5)
                )
            }
        }
    }

    private var capsuleBorder: some View {
        barShape
            .strokeBorder(borderColor, lineWidth: 0.5)
    }

    private var borderColor: Color {
        switch state.barPhase {
        case .preparing, .recording, .processing, .recovering:
            TF.floatingBorder
        case .done:
            switch state.feedbackKind {
            case .macActionUnsure:
                TF.amber.opacity(0.40)
            case .macActionSuccess, .macActionFailure, .standard:
                TF.success.opacity(0.40)
            }
        case .error:
            TF.settingsAccentRed.opacity(0.45)
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
            hintedAction = nil
            actionHintTask?.cancel()
            pressedAction = nil
            cancelDragOffset = .zero
        }
        switch phase {
        case .preparing:
            recordingPeakWidth = baseRecordingWidth
            processingStartDate = nil
            doneStartDate = nil
            recordingActionLocked = false
            if effectiveShowsTooltips {
                showModeHint()
            }
        case .recording:
            let base = baseRecordingWidth
            if recordingPeakWidth < base {
                recordingPeakWidth = base
            }
            updateRecordingPeakWidthIfNeeded()
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
        measureText(string, font: floatingBarFont)
    }

    private func measureText(_ string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    private func topOverlaySize(_ overlay: FloatingBarTopOverlay) -> NSSize {
        switch overlay {
        case .transcript:
            return NSSize(
                width: TF.transcriptPopupWidth,
                height: transcriptPopupHeight
            )
        case .mode:
            let font = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let maxWidth = TF.barWidth + TF.recordingTooltipOverhang * 2
            return NSSize(
                width: min(maxWidth, measureText(recordingMetadataText ?? "", font: font) + 24),
                height: ceil(font.boundingRectForFont.height) + 18
            )
        case .action(let action):
            return actionHintSize(action)
        }
    }

    private var transcriptPopupHeight: CGFloat {
        let textWidth = TF.transcriptPopupWidth - 24
        let bounds = (state.transcriptionText as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: floatingBarFont]
        )
        // TranscriptPopup adds 12 pt vertical padding on both sides and a
        // one-point scroll anchor after the text.
        return min(TF.transcriptPopupMaxHeight, max(1, ceil(bounds.height) + 25))
    }

    private func actionHintSize(_ action: RecordingControlAction) -> NSSize {
        let labelFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let shortcutFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        var width = measureText(actionTitle(action), font: labelFont) + 24
        var contentHeight = ceil(labelFont.boundingRectForFont.height)

        if action == .cancel {
            width += 7 + measureText("esc", font: shortcutFont) + 14
            contentHeight = max(contentHeight, ceil(shortcutFont.boundingRectForFont.height) + 4)
        }

        return NSSize(
            width: min(TF.recordingTooltipMaxWidth, width),
            height: contentHeight + 18
        )
    }

    private func actionOverlayOverflow(
        action: RecordingControlAction,
        bubbleWidth: CGFloat
    ) -> CGFloat {
        max(
            0,
            abs(actionHorizontalOffset(action)) + bubbleWidth / 2 - capsuleWidth / 2
        )
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
                height: transcriptPopupHeight,
                onHoverChanged: updateTranscriptHover
            )
        case .mode:
            hintBubble(text: recordingMetadataText ?? "")
                .transaction { $0.animation = nil }
        case .action(.finish):
            alignedActionHint(.finish)
        case .action(.cancel):
            alignedActionHint(.cancel)
        }
    }

    private var recordingMetadataText: String? {
        // The floating bar stays alive across language changes, so it must
        // observe the preference instead of retaining a launch-time string.
        _ = language
        var components: [String] = []
        if effectiveShowsModeName {
            components.append(state.currentMode.localizedDisplayName)
        }
        if effectiveShowsProviderName, let provider = state.recordingProvider {
            components.append(provider.displayName)
        }
        if effectiveShowsModelName, let model = state.recordingModelName, !model.isEmpty {
            components.append(model)
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private func alignedActionHint(_ action: RecordingControlAction) -> some View {
        return actionHintBubble(action)
            .offset(x: actionHorizontalOffset(action))
            .frame(width: capsuleWidth)
    }

    private func actionHorizontalOffset(_ action: RecordingControlAction) -> CGFloat {
        recordingActionHorizontalOffset(
            action,
            capsuleWidth: capsuleWidth,
            usesCompactLayout: usesCompactRecordingLayout
        )
    }

    private func actionTitle(_ action: RecordingControlAction) -> String {
        _ = language
        return action == .finish
            ? L("完成录制", "Finish Recording")
            : L("取消录制", "Cancel Recording")
    }

    private func actionHintBubble(_ action: RecordingControlAction) -> some View {
        HStack(spacing: 7) {
            Text(actionTitle(action))

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
                .overlay {
                    RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                        .strokeBorder(TF.floatingBorder, lineWidth: 0.5)
                }
        )
        .frame(maxWidth: TF.recordingTooltipMaxWidth)
        .fixedSize(horizontal: true, vertical: false)
        .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
    }

    private func hintBubble(text: String) -> some View {
        Text(text)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TF.floatingText)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: TF.barWidth + TF.recordingTooltipOverhang * 2)
            .background(
                RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                    .fill(TF.floatingBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                            .strokeBorder(TF.floatingBorder, lineWidth: 0.5)
                    }
            )
            .fixedSize(horizontal: true, vertical: false)
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
    }

    private func showModeHint() {
        modeHintTask?.cancel()
        guard recordingMetadataText != nil else {
            showsModeHint = false
            modeHintTask = nil
            return
        }
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

    private func updateActionHover(_ action: RecordingControlAction, hovering: Bool) {
        if hovering {
            guard hoveredAction != action else { return }
            actionHintTask?.cancel()
            hoveredAction = action
            hintedAction = nil
            actionHintTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled, hoveredAction == action else { return }
                hintedAction = action
            }
            return
        }

        guard hoveredAction == action || hintedAction == action else { return }
        actionHintTask?.cancel()
        if hoveredAction == action {
            hoveredAction = nil
        }
        if hintedAction == action {
            hintedAction = nil
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
    let height: CGFloat
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
            .frame(width: TF.transcriptPopupWidth, height: height)
            .background(
                RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                    .fill(TF.floatingBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous)
                            .strokeBorder(TF.floatingBorder, lineWidth: 0.5)
                    }
            )
            .overlay {
                FloatingBarHoverTracker(onHoverChanged: onHoverChanged)
            }
            .clipShape(RoundedRectangle(cornerRadius: TF.transcriptPopupCorner, style: .continuous))
            .shadow(color: Color.black.opacity(0.35), radius: 6, x: 0, y: 2)
            .onAppear { proxy.scrollTo("transcript-end", anchor: .bottom) }
            .onChange(of: text) { _, _ in
                proxy.scrollTo("transcript-end", anchor: .bottom)
            }
        }
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

// MARK: - Hover Tracking (works even when app is not active)

/// AppKit-backed click target for controls hosted in a non-activating panel.
/// `acceptsFirstMouse` makes the first click actionable even while another app
/// owns focus, which SwiftUI `Button` does not reliably guarantee here.
private struct FloatingBarButtonInteraction: NSViewRepresentable {
    var onPressChanged: ((Bool) -> Void)? = nil
    var onDragOffsetChanged: ((CGSize) -> Void)? = nil
    let onHoverChanged: (Bool) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> FloatingBarButtonNSView {
        let view = FloatingBarButtonNSView()
        view.onPressChanged = onPressChanged
        view.onDragOffsetChanged = onDragOffsetChanged
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        return view
    }

    func updateNSView(_ nsView: FloatingBarButtonNSView, context: Context) {
        nsView.onPressChanged = onPressChanged
        nsView.onDragOffsetChanged = onDragOffsetChanged
        nsView.onHoverChanged = onHoverChanged
        nsView.onClick = onClick
    }
}

final class FloatingBarButtonNSView: NSView {
    var onPressChanged: ((Bool) -> Void)?
    var onDragOffsetChanged: ((CGSize) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?

    private var isTrackingPress: Bool = false

    override var isFlipped: Bool { true }

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
        guard containsMouse else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        // Panel resizing can rebuild tracking areas and synthesize an exit while
        // the pointer is still over the control.
        guard !containsMouse else { return }
        onHoverChanged?(false)
    }

    private var containsMouse: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return }
        isTrackingPress = true
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let offset = CGSize(width: location.x - center.x, height: location.y - center.y)
        onDragOffsetChanged?(offset)
        onPressChanged?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingPress else { return }
        let location = convert(event.locationInWindow, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        let offset = CGSize(width: location.x - center.x, height: location.y - center.y)
        onDragOffsetChanged?(offset)
        onPressChanged?(true)
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingPress else { return }
        isTrackingPress = false
        onDragOffsetChanged?(.zero)
        onPressChanged?(false)
        let location = convert(event.locationInWindow, from: nil)
        if bounds.contains(location) {
            onClick?()
        }
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

    deinit {
        enterWorkItem?.cancel()
    }

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
            guard let self, self.containsMouse else { return }
            self.onHoverChanged?(true)
        }
        enterWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    override func mouseExited(with event: NSEvent) {
        enterWorkItem?.cancel()
        // Resizing the panel rebuilds tracking areas and can synthesize an exit
        // even though the pointer never left the visible view.
        guard !containsMouse else { return }
        onHoverChanged?(false)
    }

    private var containsMouse: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }
}
