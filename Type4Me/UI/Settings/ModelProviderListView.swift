import SwiftUI

// MARK: - Master Provider List View

struct ModelProviderListView: View {
    let category: ModelCategory
    @Binding var selectedASR: ASRProvider
    @Binding var selectedLLM: LLMProvider
    let defaultASR: ASRProvider
    let defaultLLM: LLMProvider

    @State private var hoveredASR: ASRProvider?
    @State private var hoveredLLM: LLMProvider?

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                switch category {
                case .asr:
                    asrSection(group: .recommended)
                    asrSection(group: .local)
                    asrSection(group: .cloud)
                case .llm:
                    llmSection(group: .recommended)
                    llmSection(group: .local)
                    llmSection(group: .cloud)
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 8)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 230)
    }

    // MARK: - ASR Section & Row

    @ViewBuilder
    private func asrSection(group: ModelProviderGroup) -> some View {
        let providers = ModelSettingsHelpers.asrProviders(in: group)
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)

                ForEach(providers, id: \.rawValue) { provider in
                    asrRow(provider)
                }
            }
        }
    }

    private func asrRow(_ provider: ASRProvider) -> some View {
        let isSelected = selectedASR == provider
        let isDefault = defaultASR == provider
        let isHovered = hoveredASR == provider
        let isBatch = !ASRProviderRegistry.capabilities(for: provider).supportsRealtimeRecognition
        let hasConfig = ModelSettingsHelpers.hasConfiguredCredentials(for: provider)

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedASR = provider
            }
        } label: {
            HStack(spacing: 8) {
                // Provider Brand Icon
                BrandIconView(asr: provider, size: 18)

                // Provider Name & Batch tag
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(provider.displayName)
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .foregroundStyle(TF.settingsText)
                            .lineLimit(1)

                        if isBatch {
                            Text(L("非实时", "Batch"))
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(TF.settingsTextTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(TF.settingsCardAlt))
                        }
                    }
                }

                Spacer(minLength: 4)

                // Default badge
                if isDefault {
                    Text(L("默认", "Default"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(TF.settingsAccentBlue.opacity(0.12))
                        )
                }

                // Green verified dot indicator
                if hasConfig {
                    Circle()
                        .fill(TF.settingsAccentGreen)
                        .frame(width: 6, height: 6)
                        .settingsTooltip(L("已配置凭据", "Configured"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? TF.settingsSidebarActive
                            : (isHovered ? TF.settingsSidebarHover : Color.clear)
                    )
            )
        }
        .buttonStyle(SettingsListRowButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredASR = hovering ? provider : nil
            }
        }
    }

    // MARK: - LLM Section & Row

    @ViewBuilder
    private func llmSection(group: ModelProviderGroup) -> some View {
        let providers = ModelSettingsHelpers.llmProviders(in: group)
        if !providers.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 2)

                ForEach(providers, id: \.rawValue) { provider in
                    llmRow(provider)
                }
            }
        }
    }

    private func llmRow(_ provider: LLMProvider) -> some View {
        let isSelected = selectedLLM == provider
        let isDefault = defaultLLM == provider
        let isHovered = hoveredLLM == provider
        let hasConfig = ModelSettingsHelpers.hasConfiguredCredentials(for: provider)

        return Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                selectedLLM = provider
            }
        } label: {
            HStack(spacing: 8) {
                // Provider Brand Icon
                BrandIconView(llm: provider, size: 18)

                // Provider Name
                Text(provider.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)

                Spacer(minLength: 4)

                // Default badge
                if isDefault {
                    Text(L("默认", "Default"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentBlue)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(TF.settingsAccentBlue.opacity(0.12))
                        )
                }

                // Green verified dot indicator
                if hasConfig {
                    Circle()
                        .fill(TF.settingsAccentGreen)
                        .frame(width: 6, height: 6)
                        .settingsTooltip(L("已配置凭据", "Configured"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? TF.settingsSidebarActive
                            : (isHovered ? TF.settingsSidebarHover : Color.clear)
                    )
            )
        }
        .buttonStyle(SettingsListRowButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredLLM = hovering ? provider : nil
            }
        }
    }
}
