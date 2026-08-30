import SwiftUI

// MARK: - Shared Settings Fluid Tooltip (Design System Standard)

/// Standard tooltip placement relative to the trigger.
enum SettingsTooltipPlacement: Sendable {
    case top
    case bottom
}

/// Identifies which window hosts a tooltip, so the process-wide coordinator never
/// renders a Settings-relative bubble inside another window (and vice versa).
enum SettingsTooltipHostScope: String, Sendable, Equatable {
    case settings
    case selectionAsk

    var coordinateSpaceName: String { "TooltipHostCoordinateSpace.\(rawValue)" }
}

private struct SettingsTooltipHostScopeKey: EnvironmentKey {
    static let defaultValue: SettingsTooltipHostScope = .settings
}

extension EnvironmentValues {
    var settingsTooltipHostScope: SettingsTooltipHostScope {
        get { self[SettingsTooltipHostScopeKey.self] }
        set { self[SettingsTooltipHostScopeKey.self] = newValue }
    }
}

/// Global coordinator for rendering tooltips at the root window layer.
/// This completely decouples tooltips from child view hierarchies and prevents
/// them from ever being clipped by parent ScrollViews, cards, or `.clipShape()` containers.
@MainActor
@Observable
final class SettingsTooltipCoordinator {
    static let shared = SettingsTooltipCoordinator()

    struct TooltipState: Equatable {
        let id: UUID
        let scope: SettingsTooltipHostScope
        let text: String
        var targetRect: CGRect
        let placement: SettingsTooltipPlacement
    }

    var activeTooltip: TooltipState?
    var isPresented: Bool = false

    private var showTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var currentHoverID: UUID?

    func show(
        id: UUID,
        scope: SettingsTooltipHostScope,
        text: String,
        targetRect: CGRect,
        placement: SettingsTooltipPlacement
    ) {
        currentHoverID = id
        hideTask?.cancel()
        hideTask = nil

        showTask?.cancel()
        showTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 80_000_000) // 80ms delay
            guard !Task.isCancelled, currentHoverID == id else { return }
            activeTooltip = TooltipState(
                id: id,
                scope: scope,
                text: text,
                targetRect: targetRect,
                placement: placement
            )
            withAnimation(.easeOut(duration: 0.15)) {
                isPresented = true
            }
        }
    }

    func updateTargetRect(id: UUID, targetRect: CGRect) {
        guard activeTooltip?.id == id else { return }
        activeTooltip?.targetRect = targetRect
    }

    func hide(id: UUID) {
        // A hover-enter for another trigger can arrive before this trigger's
        // hover-exit. Ignore the stale exit so it cannot cancel the new owner's
        // pending show and strand `activeTooltip` with `isPresented == false`.
        guard currentHoverID == id || currentHoverID == nil else { return }
        currentHoverID = nil
        showTask?.cancel()
        showTask = nil

        hideTask?.cancel()
        hideTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.05)) {
                isPresented = false
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms exit
            guard !Task.isCancelled, currentHoverID == nil else { return }
            activeTooltip = nil
        }
    }
}

/// Standard fluid tooltip bubble used across Type4Me settings.
/// Complies with Transitions.dev open/close specification:
/// - 80ms hover entrance delay (prevents accidental trigger while sweeping cursor)
/// - 150ms ease-out entrance with 0.98 scale transition anchored at boundary
/// - 0ms exit delay with instant 50ms ease-out exit transition
/// - Clean card surface (TF.settingsCard, 1px subtle stroke, soft ambient and contact drop shadow)
/// - Respects accessibilityReduceMotion
struct SettingsTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(TF.settingsText)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(TF.settingsCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.03), radius: 2, x: 0, y: 1)
            .shadow(color: Color.black.opacity(0.03), radius: 8, x: 0, y: 2)
            .fixedSize(horizontal: true, vertical: false)
            .allowsHitTesting(false)
    }
}

/// Root host overlay mounted at the top-level window layer.
struct SettingsTooltipRootHost: View {
    let scope: SettingsTooltipHostScope

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let coordinator = SettingsTooltipCoordinator.shared

    init(scope: SettingsTooltipHostScope = .settings) {
        self.scope = scope
    }

    var body: some View {
        GeometryReader { windowGeo in
            if let tooltip = coordinator.activeTooltip, tooltip.scope == scope {
                SettingsTooltipBubble(text: tooltip.text)
                    .scaleEffect(
                        reduceMotion ? 1.0 : (coordinator.isPresented ? 1.0 : 0.98),
                        anchor: scaleAnchor(for: tooltip.placement)
                    )
                    .opacity(coordinator.isPresented ? 1.0 : 0.0)
                    .position(calculatedPosition(for: tooltip, in: windowGeo.size))
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }

    private func scaleAnchor(for placement: SettingsTooltipPlacement) -> UnitPoint {
        switch placement {
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    private func calculatedPosition(
        for tooltip: SettingsTooltipCoordinator.TooltipState,
        in windowSize: CGSize
    ) -> CGPoint {
        let target = tooltip.targetRect
        let bubbleHeight: CGFloat = 28
        let gap: CGFloat = 8

        var y: CGFloat
        switch tooltip.placement {
        case .top:
            y = target.minY - gap - (bubbleHeight / 2)
            // Auto flip to bottom if clipped by window top
            if y - (bubbleHeight / 2) < 8 {
                y = target.maxY + gap + (bubbleHeight / 2)
            }
        case .bottom:
            y = target.maxY + gap + (bubbleHeight / 2)
            // Auto flip to top if clipped by window bottom
            if y + (bubbleHeight / 2) > windowSize.height - 8 {
                y = target.minY - gap - (bubbleHeight / 2)
            }
        }

        var x = target.midX
        let minX: CGFloat = 50
        let maxX: CGFloat = max(minX, windowSize.width - 50)
        x = min(max(x, minX), maxX)

        return CGPoint(x: x, y: y)
    }
}

private struct SettingsFluidTooltipModifier: ViewModifier {
    let text: String
    let placement: SettingsTooltipPlacement
    let isEnabled: Bool

    @Environment(\.settingsTooltipHostScope) private var scope
    @State private var id = UUID()
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: isHovered) { _, hovering in
                            guard isEnabled else { return }
                            if hovering {
                                let frame = geo.frame(in: .named(scope.coordinateSpaceName))
                                if frame.width > 0 && frame.height > 0 {
                                    SettingsTooltipCoordinator.shared.show(
                                        id: id,
                                        scope: scope,
                                        text: text,
                                        targetRect: frame,
                                        placement: placement
                                    )
                                }
                            } else {
                                SettingsTooltipCoordinator.shared.hide(id: id)
                            }
                        }
                        .onChange(of: geo.frame(in: .named(scope.coordinateSpaceName))) { _, newFrame in
                            if isHovered && isEnabled && newFrame.width > 0 {
                                SettingsTooltipCoordinator.shared.updateTargetRect(id: id, targetRect: newFrame)
                            }
                        }
                }
            )
            .onHover { hovering in
                guard isEnabled else { return }
                isHovered = hovering
            }
            .onDisappear {
                SettingsTooltipCoordinator.shared.hide(id: id)
            }
    }
}

extension View {
    /// Mounts a window-level tooltip host and scopes every `settingsTooltip` in the
    /// subtree to it, so concurrently visible windows never render each other's bubbles.
    func settingsTooltipHost(_ scope: SettingsTooltipHostScope) -> some View {
        coordinateSpace(name: scope.coordinateSpaceName)
            .overlay { SettingsTooltipRootHost(scope: scope) }
            .environment(\.settingsTooltipHostScope, scope)
    }

    /// Standard Settings Tooltip modifier with Apple-grade fluid animation and zero-clipping window-level host.
    func settingsTooltip(
        _ text: String,
        placement: SettingsTooltipPlacement = .top,
        isEnabled: Bool = true
    ) -> some View {
        modifier(SettingsFluidTooltipModifier(text: text, placement: placement, isEnabled: isEnabled))
    }

    /// Alias for `settingsTooltip`.
    func fluidTooltip(
        _ text: String,
        placement: SettingsTooltipPlacement = .top,
        isEnabled: Bool = true
    ) -> some View {
        settingsTooltip(text, placement: placement, isEnabled: isEnabled)
    }
}

// MARK: - Shared Types

enum SettingsTestStatus: Equatable {
    case idle, testing, saved, success, failed(String)

    var buttonForeground: Color {
        switch self {
        case .idle, .testing:  return TF.settingsText
        case .saved, .success: return TF.settingsAccentGreen
        case .failed:          return TF.settingsAccentRed
        }
    }

    var buttonBackground: Color {
        switch self {
        case .idle, .testing:  return TF.settingsCardAlt
        case .saved, .success: return TF.settingsAccentGreen.opacity(0.12)
        case .failed:          return TF.settingsAccentRed.opacity(0.12)
        }
    }
}

// MARK: - Shared UI Helpers

protocol SettingsCardHelpers {}

enum SettingsControlWidth {
    static let toggle: CGFloat = 52
    static let inlineSegmented: CGFloat = 140
    static let standard: CGFloat = 240
    static let provider: CGFloat = 320
    static let input: CGFloat = 360
}

private struct SettingsOptionRowLayout: Layout {
    let controlWidth: CGFloat
    private let horizontalSpacing: CGFloat = 24
    private let verticalSpacing: CGFloat = 10
    private let minimumLabelWidth: CGFloat = 220
    private let minimumRowHeight: CGFloat = 56

    private func usesHorizontalLayout(availableWidth: CGFloat) -> Bool {
        availableWidth >= minimumLabelWidth + horizontalSpacing + controlWidth
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let availableWidth = proposal.width
            ?? (minimumLabelWidth + horizontalSpacing + controlWidth)

        if usesHorizontalLayout(availableWidth: availableWidth) {
            let labelWidth = availableWidth - horizontalSpacing - controlWidth
            let labelSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: labelWidth, height: proposal.height)
            )
            let controlSize = subviews[1].sizeThatFits(
                ProposedViewSize(width: controlWidth, height: proposal.height)
            )
            return CGSize(
                width: availableWidth,
                height: max(minimumRowHeight, labelSize.height, controlSize.height)
            )
        }

        let labelSize = subviews[0].sizeThatFits(
            ProposedViewSize(width: availableWidth, height: nil)
        )
        let controlSize = subviews[1].sizeThatFits(
            ProposedViewSize(width: availableWidth, height: nil)
        )
        return CGSize(
            width: availableWidth,
            height: labelSize.height + verticalSpacing + controlSize.height + 20
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        if usesHorizontalLayout(availableWidth: bounds.width) {
            let labelWidth = bounds.width - horizontalSpacing - controlWidth
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: labelWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.maxX, y: bounds.midY),
                anchor: .trailing,
                proposal: ProposedViewSize(width: controlWidth, height: bounds.height)
            )
        } else {
            let contentWidth = bounds.width
            let labelSize = subviews[0].sizeThatFits(
                ProposedViewSize(width: contentWidth, height: nil)
            )
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + 10),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: contentWidth, height: labelSize.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + 10 + labelSize.height + verticalSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: contentWidth, height: nil)
            )
        }
    }
}

@MainActor
extension SettingsCardHelpers {

    func settingsOptionRow<Control: View>(
        _ label: String,
        subtitle: String? = nil,
        controlWidth: CGFloat = SettingsControlWidth.standard,
        isIndented: Bool = false,
        @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsOptionRowLayout(controlWidth: controlWidth) {
            settingsOptionLabel(label, subtitle: subtitle)
                .padding(.leading, isIndented ? 18 : 0)
            control()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    func settingsToggleRow(
        _ label: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true,
        isIndented: Bool = false
    ) -> some View {
        settingsOptionRow(
            label,
            subtitle: subtitle,
            controlWidth: SettingsControlWidth.toggle,
            isIndented: isIndented
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.black)
                .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }

    private func settingsOptionLabel(_ label: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func settingsGroupCard<Content: View>(
        _ title: String,
        icon: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                if let trailing {
                    trailing
                }
            }
            .padding(.horizontal, 2)

            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TF.settingsBorder, lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func settingsField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        settingsOptionRow(label, controlWidth: SettingsControlWidth.input) {
            FixedWidthTextField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
    }

    func settingsPickerField(_ label: String, selection: Binding<String>, options: [FieldOption]) -> some View {
        settingsOptionRow(label, controlWidth: SettingsControlWidth.input) {
            settingsDropdown(
                selection: selection,
                options: options.map { ($0.value, $0.label) }
            )
        }
    }

    func settingsSecureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        settingsOptionRow(label, controlWidth: SettingsControlWidth.input) {
            FixedWidthSecureField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
    }

    func credentialSummaryCard(rows: [(String, String)]) -> some View {
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, item in
                if index > 0 { SettingsDivider() }
                settingsOptionRow(item.0, controlWidth: SettingsControlWidth.input) {
                    HStack {
                        Text(item.1)
                            .font(.system(size: 13))
                            .foregroundStyle(TF.settingsTextSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(TF.settingsCardAlt)
                    )
                }
            }
        }
    }

    // MARK: - Custom Controls

    /// Custom dropdown whose visible width follows the current selection.
    func settingsDropdown(
        selection: Binding<String>,
        options: [(value: String, label: String)],
        icon: String? = nil
    ) -> some View {
        let currentLabel = options.first(where: { $0.value == selection.wrappedValue })?.label ?? selection.wrappedValue
        return Menu {
            ForEach(options, id: \.value) { option in
                Toggle(isOn: Binding(
                    get: { option.value == selection.wrappedValue },
                    set: { if $0 { selection.wrappedValue = option.value } }
                )) {
                    Text(option.label)
                }
            }
        } label: {
            settingsDropdownLabel(currentLabel, icon: icon)
        }
        .buttonStyle(.plain)
    }

    func settingsDropdownLabel(
        _ label: String,
        icon: String? = nil
    ) -> some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .padding(.horizontal, 12)
        .frame(minWidth: 88, minHeight: 36)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsCardAlt)
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    /// Custom segmented picker with dark selected pill.
    func settingsSegmentedPicker(selection: Binding<String>, options: [(value: String, label: String)]) -> some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection.wrappedValue == option.value
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        selection.wrappedValue = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : TF.settingsText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(isSelected ? TF.settingsNavActive : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsCardAlt)
        )
    }

    /// Compact Apple-style inline segmented picker for 2 (or few) options in a settings option row.
    func settingsInlineSegmentedPicker(
        selection: Binding<String>,
        options: [(value: String, label: String)]
    ) -> some View {
        SettingsInlineSegmentedPicker(selection: selection, options: options)
    }

    func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9).fill(TF.settingsAccentBlue))
            .contentShape(Rectangle())
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
            .contentShape(Rectangle())
    }

    func saveButton(action: @escaping () -> Void) -> some View {
        primaryButton(L("保存", "Save"), action: action)
    }

    /// A "test connection" button that shows its own status inline.
    func testButton(
        _ title: String,
        status: SettingsTestStatus,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                switch status {
                case .idle:
                    Text(title)
                case .testing:
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                    Text(title)
                case .saved:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(L("已保存", "Saved"))
                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                    Text(L("连接成功", "Connected"))
                case .failed:
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text(L("重试", "Retry"))
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.buttonForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(status.buttonBackground))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(status == .testing || !isEnabled)
        .opacity(status == .testing || isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    func testStatusMessage(status: SettingsTestStatus) -> some View {
        if case .failed(let msg) = status {
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsAccentRed)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.top, 6)
        }
    }

    func maskedSecret(_ value: String) -> String {
        guard !value.isEmpty else { return L("未设置", "Not set") }
        guard value.count > 8 else { return L("已保存", "Saved") }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

}

/// Apple-grade inline segmented capsule picker with smooth matched-geometry sliding spring pill.
struct SettingsInlineSegmentedPicker: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @State private var hoveredValue: String?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                let isHovered = hoveredValue == option.value

                Button {
                    guard selection != option.value else { return }
                    if reduceMotion {
                        selection = option.value
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            selection = option.value
                        }
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                }
                .buttonStyle(SettingsSegmentedButtonStyle())
                .background {
                    ZStack {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .strokeBorder(Color.black.opacity(0.04), lineWidth: 0.5)
                                }
                                .shadow(color: Color.black.opacity(0.08), radius: 2, x: 0, y: 1)
                                .matchedGeometryEffect(id: "selected_segment_pill", in: selectionNamespace)
                        } else if isHovered {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.black.opacity(0.04))
                        }
                    }
                }
                .onHover { hovering in
                    hoveredValue = hovering ? option.value : nil
                }
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TF.settingsCardAlt)
        )
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.28, dampingFraction: 0.82),
            value: selection
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SettingsSegmentedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
