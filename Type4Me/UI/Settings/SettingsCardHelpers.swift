import SwiftUI

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

@MainActor
extension SettingsCardHelpers {

    func settingsGroupCard<Content: View>(
        _ title: String,
        icon: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentAmber)
                }
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                if let trailing {
                    trailing
                }
            }
            .padding(.bottom, 14)

            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsBg)
        )
    }

    func settingsField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            FixedWidthTextField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
        .padding(.vertical, 6)
    }

    func settingsTextAreaField(_ label: String, text: Binding<String>, prompt: String, note: String? = nil, onReset: (() -> Void)? = nil, wordLimit: Int? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            if note != nil || onReset != nil {
                HStack(spacing: 4) {
                    if let note {
                        Text(note)
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    if let onReset {
                        Button(L("从词汇表重新加载", "reload hotwords from vocabulary")) { onReset() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(TF.settingsAccentBlue)
                    }
                }
            }
            ZStack(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                }
                TextEditor(text: text)
                    .font(.system(size: 12))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            }
            .frame(minHeight: 72)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

            if let hint = textAreaWordHint(text.wrappedValue, limit: wordLimit) {
                Text(hint)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
        .padding(.vertical, 6)
    }

    func settingsPickerField(_ label: String, selection: Binding<String>, options: [FieldOption]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            settingsDropdown(
                selection: selection,
                options: options.map { ($0.value, $0.label) }
            )
        }
        .padding(.vertical, 6)
    }

    func settingsSecureField(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(TF.settingsTextTertiary)
            FixedWidthSecureField(text: text, placeholder: prompt)
                .padding(.horizontal, 12)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
        }
        .padding(.vertical, 6)
    }

    func credentialSummaryCard(rows: [(String, String)]) -> some View {
        let pairedRows = stride(from: 0, to: rows.count, by: 2).map { i in
            Array(rows[i..<min(i+2, rows.count)])
        }
        return VStack(spacing: 0) {
            ForEach(Array(pairedRows.enumerated()), id: \.offset) { index, pair in
                if index > 0 { SettingsDivider() }
                HStack(alignment: .top, spacing: 16) {
                    ForEach(Array(pair.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.0.uppercased())
                                .font(.system(size: 10, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(TF.settingsTextTertiary)
                            HStack {
                                Text(item.1)
                                    .font(.system(size: 13))
                                    .foregroundStyle(TF.settingsTextSecondary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .frame(height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(TF.settingsCardAlt)
                            )
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if pair.count == 1 {
                        Spacer().frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    // MARK: - Custom Controls

    /// Custom dropdown that matches the design mockup (rounded rect + chevron).
    func settingsDropdown(selection: Binding<String>, options: [(value: String, label: String)], icon: String? = nil) -> some View {
        let currentLabel = options.first(where: { $0.value == selection.wrappedValue })?.label ?? selection.wrappedValue
        return Menu {
            ForEach(options, id: \.value) { option in
                Button {
                    selection.wrappedValue = option.value
                } label: {
                    if option.value == selection.wrappedValue {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                Text(currentLabel)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsCardAlt)
            )
        }
        .buttonStyle(.plain)
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
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsAccentAmber))
    }

    func secondaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
    }

    func saveButton(action: @escaping () -> Void) -> some View {
        primaryButton(L("保存", "Save"), action: action)
    }

    /// A "test connection" button that shows its own status inline.
    func testButton(_ title: String, status: SettingsTestStatus, action: @escaping () -> Void) -> some View {
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
                case .failed(let msg):
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                    Text(msg)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(status.buttonForeground)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(status.buttonBackground))
        }
        .buttonStyle(.plain)
        .disabled(status == .testing)
    }

    func maskedSecret(_ value: String) -> String {
        guard !value.isEmpty else { return L("未设置", "Not set") }
        guard value.count > 8 else { return L("已保存", "Saved") }
        let prefix = value.prefix(4)
        let suffix = value.suffix(4)
        return "\(prefix)••••\(suffix)"
    }

    func textAreaWordHint(_ text: String, limit: Int? = nil) -> String? {
        let words = text
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        if let limit, words.count > limit {
            let effectiveWord = words[limit - 1]
            return L("共 \(words.count) 个词，仅发送前 \(limit) 个，第 \(limit) 个词：\(effectiveWord)",
                     "Currently \(words.count) words, only first \(limit) will be sent, last effective word is \(effectiveWord)")
        } else if let last = words.last {
            return L("共 \(words.count) 个词，最后一个有效词：\(last)",
                     "Currently \(words.count) words, last effective word is \(last)")
        }
        return nil
    }
}
