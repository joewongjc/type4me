import SwiftUI

// MARK: - Settings Button System
//
// One style for every text button in the settings window, setup wizard and
// permission guide. Pick a role and a size; hover, press and disabled states
// are handled here so call sites never hand-roll padding, fills or opacity.
//
//     Button(L("保存", "Save")) { save() }
//         .buttonStyle(.tf(.primary))
//
//     Button { reset() } label: { Label(L("还原", "Revert"), systemImage: "arrow.uturn.backward") }
//         .buttonStyle(.tf(.ghost, size: .small))

enum TFButtonRole: Equatable {
    /// Ink-filled call to action. At most one per surface.
    case primary
    /// Neutral filled control for ordinary actions and Cancel.
    case secondary
    /// Text-only action; gains a fill on hover. Links, Revert, Undo.
    case ghost
    /// Red-tinted action that deletes or clears data.
    case destructive
    /// Status-tinted control (e.g. a connection test that succeeded).
    case tinted(Color)
}

enum TFButtonSize {
    /// 24pt — inline with rows, card corners, toolbars.
    case small
    /// 28pt — default for page actions and sheet footers.
    case regular
    /// 36pt — onboarding and permission flows.
    case large

    var height: CGFloat {
        switch self {
        case .small: 24
        case .regular: 28
        case .large: 36
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .small: 10
        case .regular: 12
        case .large: 16
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .small: 11
        case .regular: 12
        case .large: 13
        }
    }

    var iconSpacing: CGFloat {
        switch self {
        case .small: 4
        case .regular, .large: 5
        }
    }
}

struct TFButtonStyle: ButtonStyle {
    static let cornerRadius: CGFloat = 8

    var role: TFButtonRole = .secondary
    var size: TFButtonSize = .regular
    /// Stretch the button to fill the available width.
    var fillsWidth = false
    /// The action is in progress: pair with `.disabled(true)` to block every
    /// input path (mouse, keyboard, accessibility) while staying fully legible.
    var isLoading = false

    func makeBody(configuration: Configuration) -> some View {
        TFButtonBody(
            configuration: configuration,
            role: role,
            size: size,
            fillsWidth: fillsWidth,
            isLoading: isLoading
        )
    }
}

extension ButtonStyle where Self == TFButtonStyle {
    static func tf(
        _ role: TFButtonRole = .secondary,
        size: TFButtonSize = .regular,
        fillsWidth: Bool = false,
        isLoading: Bool = false
    ) -> TFButtonStyle {
        TFButtonStyle(role: role, size: size, fillsWidth: fillsWidth, isLoading: isLoading)
    }
}

private struct TFButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let role: TFButtonRole
    let size: TFButtonSize
    let fillsWidth: Bool
    let isLoading: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TFButtonStyle.cornerRadius, style: .continuous)
        configuration.label
            .labelStyle(TFButtonLabelStyle(spacing: size.iconSpacing))
            .font(.system(size: size.fontSize, weight: role == .primary ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, size.horizontalPadding)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: size.height)
            .background(shape.fill(background))
            .overlay(shape.strokeBorder(border, lineWidth: 0.5))
            .contentShape(shape)
            .opacity(isEnabled || isLoading ? 1 : 0.4)
            .scaleEffect(configuration.isPressed && isEnabled ? 0.98 : 1)
            .animation(.spring(response: 0.16, dampingFraction: 0.75), value: configuration.isPressed)
            .animation(TF.easeQuick, value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }

    private var isActive: Bool { isHovered || configuration.isPressed }

    private var foreground: Color {
        switch role {
        case .primary: TF.settingsOnStrong
        case .secondary: TF.settingsText
        case .ghost: isActive ? TF.settingsText : TF.settingsTextSecondary
        case .destructive: TF.settingsAccentRed
        case .tinted(let color): color
        }
    }

    private var background: Color {
        switch role {
        case .primary:
            TF.settingsNavActive.opacity(configuration.isPressed ? 0.75 : isHovered ? 0.86 : 1)
        case .secondary:
            isActive ? TF.settingsControlHover : TF.settingsControl
        case .ghost:
            isActive ? TF.settingsControl : .clear
        case .destructive:
            TF.settingsAccentRed.opacity(isActive ? 0.16 : 0.10)
        case .tinted(let color):
            color.opacity(isActive ? 0.18 : 0.12)
        }
    }

    private var border: Color {
        role == .secondary ? TF.settingsBorder : .clear
    }
}

/// Keeps icon + title spacing consistent when the label is a `Label`.
private struct TFButtonLabelStyle: LabelStyle {
    let spacing: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

// MARK: - Icon Buttons

enum TFIconButtonKind {
    /// Square 24pt control with a neutral fill: add, refresh, page arrows.
    case control
    /// Bare glyph that gains a fill on hover: inline row actions.
    case plain
    /// Small circular remove glyph inside chips and tags.
    case chipRemove
}

struct TFIconButtonStyle: ButtonStyle {
    var kind: TFIconButtonKind = .plain
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        TFIconButtonBody(configuration: configuration, kind: kind, tint: tint)
    }
}

extension ButtonStyle where Self == TFIconButtonStyle {
    static func tfIcon(_ kind: TFIconButtonKind = .plain, tint: Color? = nil) -> TFIconButtonStyle {
        TFIconButtonStyle(kind: kind, tint: tint)
    }
}

private struct TFIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: TFIconButtonKind
    let tint: Color?

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let isActive = isHovered || configuration.isPressed
        Group {
            switch kind {
            case .control:
                configuration.label
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint ?? TF.settingsText)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: TFButtonStyle.cornerRadius, style: .continuous)
                            .fill(isActive ? TF.settingsControlHover : TF.settingsControl)
                    )
            case .plain:
                configuration.label
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tint ?? (isActive ? TF.settingsText : TF.settingsTextSecondary))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isActive ? TF.settingsControl : .clear)
                    )
            case .chipRemove:
                configuration.label
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(tint ?? (isActive ? TF.settingsText : TF.settingsTextTertiary))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(isActive ? TF.settingsControlHover : .clear))
            }
        }
        .contentShape(Rectangle())
        .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
        .animation(TF.easeQuick, value: isHovered)
        .onHover { isHovered = $0 && isEnabled }
    }
}

/// The standard dismiss control for sheets and popovers: a compact glyph
/// inside a 30pt hit target with hover and press feedback.
struct TFCloseButton: View {
    static let hitSize: CGFloat = 30

    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark.circle.fill")
        }
        .buttonStyle(TFCloseButtonStyle())
        .accessibilityLabel(L("关闭", "Close"))
    }
}

private struct TFCloseButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TFCloseButtonBody(configuration: configuration)
    }
}

private struct TFCloseButtonBody: View {
    let configuration: ButtonStyleConfiguration

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        let isActive = isHovered || configuration.isPressed
        configuration.label
            .font(.system(size: 17))
            .foregroundStyle(isActive ? TF.settingsTextSecondary : TF.settingsTextTertiary)
            .frame(width: TFCloseButton.hitSize, height: TFCloseButton.hitSize)
            .background(Circle().fill(isActive ? TF.settingsControl : .clear))
            .contentShape(Circle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .animation(TF.easeQuick, value: isHovered)
            .onHover { isHovered = $0 && isEnabled }
    }
}
