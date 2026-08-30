import SwiftUI

/// An Apple-grade fluid segmented tab picker featuring liquid glass materials,
/// continuous spring physics, instant press tactile feedback, and accessibility adaptations.
struct LiquidGlassTabPicker<Item: Hashable, Label: View>: View {
    let items: [Item]
    let selection: Item
    let onSelectionChange: (Item) -> Void
    let spacing: CGFloat
    @ViewBuilder let label: (Item, Bool, Bool) -> Label

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredItem: Item?
    @Namespace private var selectionNamespace

    init(
        items: [Item],
        selection: Item,
        spacing: CGFloat = 2,
        onSelectionChange: @escaping (Item) -> Void,
        @ViewBuilder label: @escaping (Item, Bool, Bool) -> Label
    ) {
        self.items = items
        self.selection = selection
        self.spacing = spacing
        self.onSelectionChange = onSelectionChange
        self.label = label
    }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(items, id: \.self) { item in
                tabButton(for: item)
            }
        }
        .padding(3)
        .background(trackBackground)
        .animation(
            reduceMotion ? .easeInOut(duration: 0.15) : .spring(response: 0.32, dampingFraction: 0.86),
            value: selection
        )
    }

    // MARK: - Tab Item Button

    private func tabButton(for item: Item) -> some View {
        let isSelected = selection == item
        let isHovered = hoveredItem == item

        return Button {
            select(item)
        } label: {
            label(item, isSelected, isHovered)
                .contentShape(Capsule())
        }
        .buttonStyle(LiquidGlassTabItemButtonStyle())
        .background {
            ZStack {
                if isSelected {
                    LiquidGlassSelectedPill(
                        colorScheme: colorScheme,
                        reduceTransparency: reduceTransparency
                    )
                    .matchedGeometryEffect(id: "liquid_glass_selected_pill", in: selectionNamespace)
                } else if isHovered {
                    LiquidGlassHoverPill()
                }
            }
        }
        .onHover { isHovering in
            updateHover(for: item, isHovering: isHovering)
        }
    }

    // MARK: - Track Background

    private var trackBackground: some View {
        Capsule()
            .fill(TF.settingsControl)
            .overlay {
                Capsule()
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.15 : 0.04), lineWidth: 0.5)
            }
    }

    // MARK: - Actions & Hover

    private func select(_ item: Item) {
        guard item != selection else { return }
        // Keep the selection-pill animation local to this control. Wrapping the
        // navigation mutation in `withAnimation` animates the whole settings page
        // replacement; the `.animation(_:value: selection)` on the track already
        // drives the matched-geometry pill on its own.
        onSelectionChange(item)
    }

    private func updateHover(for item: Item, isHovering: Bool) {
        withAnimation(.easeOut(duration: 0.12)) {
            if isHovering {
                hoveredItem = item
            } else if hoveredItem == item {
                hoveredItem = nil
            }
        }

        if isHovering {
            NSCursor.pointingHand.set()
        } else if hoveredItem == nil {
            NSCursor.arrow.set()
        }
    }
}

// MARK: - Selected Pill (Liquid Glass Material)

private struct LiquidGlassSelectedPill: View {
    let colorScheme: ColorScheme
    let reduceTransparency: Bool

    var body: some View {
        Capsule()
            .fill(pillFill)
            .overlay {
                // Specular light-catching rim (Fresnel reflection)
                Capsule()
                    .strokeBorder(specularBorderGradient, lineWidth: 0.5)
            }
            // Dual-layer depth: ambient dispersion shadow + micro contact shadow
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.35) : Color.black.opacity(0.06),
                radius: 3,
                x: 0,
                y: 1.5
            )
            .shadow(
                color: colorScheme == .dark ? Color.black.opacity(0.20) : Color.black.opacity(0.03),
                radius: 1,
                x: 0,
                y: 0.5
            )
    }

    private var pillFill: some ShapeStyle {
        if reduceTransparency {
            return AnyShapeStyle(colorScheme == .dark ? Color(white: 0.22) : Color.white)
        }
        if colorScheme == .dark {
            return AnyShapeStyle(Color.white.opacity(0.16))
        } else {
            return AnyShapeStyle(Color.white.opacity(0.96))
        }
    }

    private var specularBorderGradient: LinearGradient {
        if colorScheme == .dark {
            return LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.28), location: 0.0),
                    .init(color: Color.white.opacity(0.10), location: 0.5),
                    .init(color: Color.clear, location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        } else {
            return LinearGradient(
                stops: [
                    .init(color: Color.white.opacity(0.90), location: 0.0),
                    .init(color: Color.white.opacity(0.40), location: 0.35),
                    .init(color: Color.black.opacity(0.03), location: 0.80),
                    .init(color: Color.black.opacity(0.07), location: 1.0),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }
}

// MARK: - Hover Pill

private struct LiquidGlassHoverPill: View {
    var body: some View {
        Capsule()
            .fill(TF.settingsControlHover.opacity(0.9))
            .transition(.opacity.animation(.easeOut(duration: 0.12)))
    }
}

// MARK: - Tactile Button Style

private struct LiquidGlassTabItemButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.16, dampingFraction: 0.75), value: configuration.isPressed)
    }
}
