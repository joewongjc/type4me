import SwiftUI

/// The punctuation key. A tap types a comma; flicking up types the full
/// stop shown in the corner; holding opens the other marks and a switch
/// between full-width and ASCII, picked by sliding along and letting go.
struct PunctuationKey: View {
    @ObservedObject var model: KeyboardModel
    @State private var touch: Touch?
    @State private var opening: Task<Void, Never>?

    private struct Touch {
        var flicked = false
        var menuOpen = false
        var selected = 0
    }

    static let width: CGFloat = 56
    private static let cell: CGFloat = 40
    private static let menuInset: CGFloat = 4
    private static let flick: CGFloat = 18
    private static let holdDelay: Duration = .milliseconds(250)
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        let marks = model.punctuation
        face(marks)
            .glassEffect(.regular.tint(KB.keyTint).interactive(), in: shape)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { changed($0, marks: marks) }
                    .onEnded { _ in ended(marks: marks) }
            )
            .overlay(alignment: .bottomLeading) {
                if let touch, touch.menuOpen {
                    menu(marks, selected: touch.selected)
                        .offset(y: -52)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                }
            }
            .animation(.spring(response: 0.22, dampingFraction: 0.9), value: touch?.menuOpen)
            .onDisappear { opening?.cancel() }
            .accessibilityElement()
            .accessibilityLabel(L("标点", "Punctuation"))
            .accessibilityValue(marks.main)
            .accessibilityHint(L("上滑输入句号，长按选择更多标点", "Flick up for a full stop, hold for more marks"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.insert(marks.main) }
            .accessibilityActions {
                ForEach(marks.more, id: \.self) { mark in
                    Button(mark) { model.insert(mark) }
                }
                Button(L("切换中英文标点", "Switch full-width and ASCII punctuation")) { model.togglePunctuationWidth() }
            }
    }

    private func face(_ marks: (main: String, more: [String])) -> some View {
        let flicked = touch?.flicked == true
        return Text(flicked ? marks.more[0] : marks.main)
            .font(.system(size: 18))
            .foregroundStyle(KB.ink)
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            // The corner mark says the key holds more, and what a flick types.
            .overlay(alignment: .topTrailing) {
                Text(marks.more[0])
                    .font(.system(size: 11))
                    .foregroundStyle(KB.secondary)
                    .opacity(flicked ? 0 : 1)
                    .padding(.top, 3)
                    .padding(.trailing, 7)
            }
            .contentShape(shape)
    }

    private func menu(_ marks: (main: String, more: [String]), selected: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(marks.more.enumerated()), id: \.offset) { index, mark in
                Text(mark)
                    .font(.system(size: 20))
                    .foregroundStyle(index == selected ? KB.micGlyph : KB.ink)
                    .frame(width: Self.cell, height: 44)
                    .background {
                        if index == selected { shape.fill(KB.ink) }
                    }
            }
            // The last cell switches full-width and ASCII; the current one
            // reads darker.
            let toggle = marks.more.count
            HStack(spacing: 1) {
                Text("中").foregroundStyle(model.fullWidthPunctuation ? ink(toggle, selected) : dim(toggle, selected))
                Text("/").foregroundStyle(dim(toggle, selected))
                Text("英").foregroundStyle(model.fullWidthPunctuation ? dim(toggle, selected) : ink(toggle, selected))
            }
                .font(.system(size: 13, weight: .medium))
                .frame(width: Self.cell, height: 44)
                .background {
                    if selected == marks.more.count { shape.fill(KB.ink) }
                }
        }
        .padding(Self.menuInset)
        .background(KB.key, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .fixedSize()
    }

    private func ink(_ index: Int, _ selected: Int) -> Color { index == selected ? KB.micGlyph : KB.ink }
    private func dim(_ index: Int, _ selected: Int) -> Color {
        (index == selected ? KB.micGlyph : KB.ink).opacity(0.35)
    }

    private func changed(_ value: DragGesture.Value, marks: (main: String, more: [String])) {
        guard var current = touch else {
            touch = Touch()
            KeyFeedback.play(.character)
            opening = Task {
                try? await Task.sleep(for: Self.holdDelay)
                guard !Task.isCancelled, touch?.flicked == false else { return }
                touch?.menuOpen = true
                KeyFeedback.playTick()
            }
            return
        }
        if current.menuOpen {
            let index = Int(((value.location.x - Self.menuInset) / Self.cell).rounded(.down))
            let clamped = min(max(index, 0), marks.more.count)
            if clamped != current.selected {
                current.selected = clamped
                KeyFeedback.playTick()
            }
        } else {
            let flicked = value.translation.height < -Self.flick
            if flicked != current.flicked {
                current.flicked = flicked
                if flicked { opening?.cancel() }
                KeyFeedback.playTick()
            }
        }
        touch = current
    }

    private func ended(marks: (main: String, more: [String])) {
        opening?.cancel()
        defer { touch = nil }
        guard let touch else { return }
        if touch.menuOpen {
            if touch.selected == marks.more.count {
                model.togglePunctuationWidth()
            } else {
                model.insert(marks.more[touch.selected])
            }
        } else {
            model.insert(touch.flicked ? marks.more[0] : marks.main)
        }
    }
}

/// The space bar. A tap types a space; dragging sideways moves the cursor
/// a character per step, like the system keyboard's trackpad.
struct SpaceKey: View {
    @ObservedObject var model: KeyboardModel
    @State private var pressed = false
    @State private var tracking = false
    /// Where the last cursor step happened, in drag translation.
    @State private var anchor: CGFloat = 0

    private static let start: CGFloat = 10
    private static let step: CGFloat = 9
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        ZStack {
            Text(L("空格", "space"))
                .opacity(tracking ? 0 : 1)
            Image(systemName: "arrow.left.and.right")
                .opacity(tracking ? 1 : 0)
        }
        .font(.system(size: 16))
        .foregroundStyle(KB.ink)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(shape)
        .glassEffect(.regular.tint(KB.keyTint).interactive(), in: shape)
        .animation(.easeInOut(duration: 0.12), value: tracking)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !pressed {
                        pressed = true
                        KeyFeedback.play(.character)
                    }
                    let dx = value.translation.width
                    if !tracking {
                        guard abs(dx) > Self.start else { return }
                        tracking = true
                        anchor = dx > 0 ? Self.start : -Self.start
                    }
                    let steps = Int(((dx - anchor) / Self.step).rounded(.towardZero))
                    guard steps != 0 else { return }
                    model.moveCursor(by: steps)
                    anchor += CGFloat(steps) * Self.step
                    KeyFeedback.playTick()
                }
                .onEnded { _ in
                    if !tracking { model.insert(" ") }
                    pressed = false
                    tracking = false
                }
        )
        .accessibilityElement()
        .accessibilityLabel(L("空格", "Space"))
        .accessibilityHint(L("左右拖动可以移动光标", "Drag sideways to move the cursor"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.insert(" ") }
    }
}
