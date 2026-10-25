import SwiftUI

/// Visual tokens matching the Mac `TF` settings palette, so the iPhone app
/// reads as the same product as the Mac window.
enum T4 {
    /// `TF.settingsBg`
    static let background = Color(light: 0xF6F6F6, dark: 0x1A1A1A)
    /// `TF.settingsCard`
    static let card = Color(light: 0xFFFFFF, dark: 0x292929)
    /// `TF.settingsCardAlt`, the grey stats card on the Mac Home.
    static let cardAlt = Color(light: 0xEEEEEE, dark: 0x333333)
    /// `TF.settingsText`
    static let ink = Color(light: 0x131313, dark: 0xF0F0F0)
    /// `TF.settingsTextSecondary`
    static let secondary = Color(light: 0x4D4D4D, dark: 0xC7C7C7)
    /// `TF.settingsTextTertiary`
    static let tertiary = Color(light: 0x7A7A7A, dark: 0xABABAB)
    /// `TF.settingsBorder`: ink at 7.5 %.
    static let border = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.075) : UIColor(white: 0, alpha: 0.075) })
    static let separator = border
    /// `TF.settingsControl`
    static let control = Color(light: 0xF1F1F1, dark: 0x333333)
    static let amber = Color(light: 0xC27D29, dark: 0xD4913D)
    static let amberSoft = Color(hex: 0xF0B852)
    static let recording = Color(hex: 0xD6574A)
    static let success = Color(light: 0x4D9E59, dark: 0x75D182)
    static let capsule = Bar.background

    static let cornerCard: CGFloat = 20
}

/// The Mac Home canvas: a faint dot grid behind the cards. Drawn once into
/// a small tile and repeated, so scrolling never re-rasterises thousands of
/// dots.
struct DottedCanvas: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Image(uiImage: Self.tile(dark: colorScheme == .dark)), scale: 1))
            .background(T4.background)
            .ignoresSafeArea()
    }

    private static var cache: [Bool: UIImage] = [:]

    private static func tile(dark: Bool) -> UIImage {
        if let cached = cache[dark] { return cached }
        let step: CGFloat = 11
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: step, height: step), format: format).image { context in
            UIColor(white: dark ? 1 : 0, alpha: dark ? 0.07 : 0.075).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: step / 2 - 0.75, y: step / 2 - 0.75, width: 1.5, height: 1.5))
        }
        cache[dark] = image
        return image
    }
}

/// The Type4Me mark: the "4!" logo from the Mac app (ink "4", red dot).
struct BrandMark: View {
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Image("MarkGlyph")
                .resizable()
                .renderingMode(.template)
                .foregroundStyle(T4.ink)
            Image("MarkDot")
                .resizable()
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Section heading above a card, as in the Mac settings pages: the title is
/// a label for the group, not one of its choices.
struct SectionHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(alignment: .lastTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(T4.ink)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(T4.tertiary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 4)
        .padding(.top, 10)
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Small grey "内置" style badge from the Mac mode list.
struct T4Badge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(T4.tertiary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(T4.control, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Full-width primary action: ink-tinted Liquid Glass capsule.
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(T4.background)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Capsule())
            .glassEffect(.regular.tint(T4.ink).interactive(), in: Capsule())
            .opacity(configuration.isPressed ? 0.9 : 1)
    }
}

/// Full-width secondary action: clear Liquid Glass capsule.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(T4.ink)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Capsule())
            .glassEffect(.regular.interactive(), in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: T4.cornerCard, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T4.card, in: shape)
            .overlay(shape.strokeBorder(T4.border, lineWidth: 1))
    }
}

extension View {
    func t4Card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}
