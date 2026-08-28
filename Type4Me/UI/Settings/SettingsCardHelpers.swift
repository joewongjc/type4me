import SwiftUI

// MARK: - Shared Settings Fluid Tooltip (Design System Standard)

/// Standard tooltip placement relative to the trigger.
enum SettingsTooltipPlacement: Sendable {
    case top
    case bottom
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
            .shadow(color: Color.black.opacity(0.05), radius: 3, x: 0, y: 2)
            .shadow(color: Color.black.opacity(0.06), radius: 16, x: 0, y: 4)
            .fixedSize(horizontal: true, vertical: false)
            .allowsHitTesting(false)
    }
}

private struct SettingsTooltipHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 28
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct SettingsFluidTooltipModifier: ViewModifier {
    let text: String
    let placement: SettingsTooltipPlacement
    let isEnabled: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var isPresented = false
    @State private var isVisible = false
    @State private var hoverToken = 0
    @State private var tooltipHeight: CGFloat = 28

    func body(content: Content) -> some View {
        content
            .overlay(alignment: overlayAlignment) {
                if isVisible {
                    SettingsTooltipBubble(text: text)
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: SettingsTooltipHeightPreferenceKey.self,
                                    value: geo.size.height
                                )
                            }
                        )
                        .onPreferenceChange(SettingsTooltipHeightPreferenceKey.self) { height in
                            if height > 0 { tooltipHeight = height }
                        }
                        .offset(y: verticalOffset)
                        .scaleEffect(reduceMotion ? 1.0 : (isPresented ? 1.0 : 0.98), anchor: scaleAnchor)
                        .opacity(isPresented ? 1.0 : 0.0)
                        .allowsHitTesting(false)
                }
            }
            .zIndex(isVisible ? 100 : 0)
            .onHover { hovering in
                guard isEnabled else { return }
                handleHover(hovering)
            }
    }

    private var overlayAlignment: Alignment {
        switch placement {
        case .top: return .top
        case .bottom: return .bottom
        }
    }

    private var verticalOffset: CGFloat {
        switch placement {
        case .top: return -(tooltipHeight + 8)
        case .bottom: return tooltipHeight + 8
        }
    }

    private var scaleAnchor: UnitPoint {
        switch placement {
        case .top: return .bottom
        case .bottom: return .top
        }
    }

    private func handleHover(_ hovering: Bool) {
        hoverToken += 1
        let currentToken = hoverToken

        if hovering {
            isHovered = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { // 80ms delay
                guard currentToken == hoverToken, isHovered else { return }
                isVisible = true
                withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeOut(duration: 0.15)) {
                    isPresented = true
                }
            }
        } else {
            isHovered = false
            // 0ms delay on exit, 50ms easeOut animation
            withAnimation(reduceMotion ? .easeInOut(duration: 0.05) : .easeOut(duration: 0.05)) {
                isPresented = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard currentToken == hoverToken, !isHovered else { return }
                isVisible = false
            }
        }
    }
}

extension View {
    /// Standard Settings Tooltip modifier with Apple-grade fluid animation.
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
        @ViewBuilder control: () -> Control
    ) -> some View {
        SettingsOptionRowLayout(controlWidth: controlWidth) {
            settingsOptionLabel(label, subtitle: subtitle)
            control()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    func settingsToggleRow(
        _ label: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        settingsOptionRow(
            label,
            subtitle: subtitle,
            controlWidth: SettingsControlWidth.toggle
        ) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.black)
                .disabled(!isEnabled)
        }
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
