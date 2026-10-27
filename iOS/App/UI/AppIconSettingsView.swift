import SwiftUI

struct AppIconSettingsView: View {
    @ObservedObject private var store = AppIconStore.shared
    @State private var pending: AppIconChoice?
    @State private var failed = false

    // Four across so every group lines up in the same columns.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)
    private let iconSize: CGFloat = 62

    var body: some View {
        Form {
            ForEach(AppIconChoice.Group.allCases) { group in
                Section {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                        ForEach(group.choices) { choice in
                            tile(choice)
                        }
                    }
                    .padding(.vertical, 8)
                } header: {
                    Text(group.title)
                } footer: {
                    footer(for: group)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("应用图标", "App Icon"))
        .navigationBarTitleDisplayMode(.inline)
        .disabled(!store.isSupported || pending != nil)
    }

    @ViewBuilder
    private func footer(for group: AppIconChoice.Group) -> some View {
        switch group {
        case .classic:
            Text(L("「跟随系统」会随主屏幕的浅色、深色和着色外观变化；其他图标固定不变。", "Automatic follows the Home Screen's light, dark and tinted looks. The others stay as they are."))
                .foregroundStyle(T4.secondary)
        case .keycap:
            if failed {
                Text(L("没能更换图标，请稍后再试。", "Couldn't change the icon. Try again in a moment."))
                    .foregroundStyle(T4.recording)
            }
        }
    }

    private func tile(_ choice: AppIconChoice) -> some View {
        let selected = store.current == choice
        let shape = RoundedRectangle(cornerRadius: iconSize * 0.2237, style: .continuous)
        return Button {
            select(choice)
        } label: {
            VStack(spacing: 8) {
                choice.preview
                    .resizable()
                    .scaledToFit()
                    .frame(width: iconSize, height: iconSize)
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(T4.border, lineWidth: 1))
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: iconSize * 0.2237 + 4, style: .continuous)
                            .strokeBorder(selected ? T4.ink : .clear, lineWidth: 2.5)
                    )
                Text(choice.shortTitle)
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? T4.ink : T4.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func select(_ choice: AppIconChoice) {
        pending = choice
        failed = false
        Task {
            do {
                try await store.select(choice)
            } catch {
                failed = true
            }
            pending = nil
        }
    }
}
