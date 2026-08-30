import SwiftUI

struct ModelSettingsTab: View, SettingsCardHelpers {

    var showsHeader = true
    let draftCoordinator: SettingsDraftCoordinator

    @State private var selectedCategory: ModelCategory = .asr
    @State private var selectedASRProvider: ASRProvider = KeychainService.selectedASRProvider
    @State private var selectedLLMProvider: LLMProvider = KeychainService.selectedLLMProvider
    @State private var defaultASRProvider: ASRProvider = KeychainService.selectedASRProvider
    @State private var defaultLLMProvider: LLMProvider = KeychainService.selectedLLMProvider
    @AppStorage("tf_sensevoiceEnabled") private var sensevoiceEnabled = true
    @AppStorage("tf_qwen3FinalEnabled") private var qwen3FinalEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                SettingsSectionHeader(
                    label: L("模型", "MODELS"),
                    title: L("模型配置", "Model Configuration"),
                    description: L("语音识别与文本处理引擎配置。", "ASR and LLM engine configuration.")
                )
            }

            // Top Liquid Glass Capsule Picker
            categoryPicker
                .padding(.bottom, 16)

            // Master-Detail Split Layout
            HStack(alignment: .top, spacing: 0) {
                // Left: Provider List
                ModelProviderListView(
                    category: selectedCategory,
                    selectedASR: $selectedASRProvider,
                    selectedLLM: $selectedLLMProvider,
                    defaultASR: defaultASRProvider,
                    defaultLLM: defaultLLMProvider
                )
                .padding(.trailing, 14)

                // Divider
                Rectangle()
                    .fill(TF.settingsTextTertiary.opacity(0.2))
                    .frame(width: 1)
                    .padding(.vertical, 4)

                // Right: Provider Detail
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        switch selectedCategory {
                        case .asr:
                            ASRProviderDetailView(
                                provider: selectedASRProvider,
                                isDefault: selectedASRProvider == defaultASRProvider,
                                onSetAsDefault: handleSetDefaultASR
                            )
                        case .llm:
                            LLMProviderDetailView(
                                provider: selectedLLMProvider,
                                isDefault: selectedLLMProvider == defaultLLMProvider,
                                onSetAsDefault: handleSetDefaultLLM
                            )
                        }
                    }
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            defaultASRProvider = KeychainService.selectedASRProvider
            defaultLLMProvider = KeychainService.selectedLLMProvider
            selectedASRProvider = defaultASRProvider
            selectedLLMProvider = defaultLLMProvider
        }
        .onReceive(NotificationCenter.default.publisher(for: .asrProviderDidChange)) { note in
            if let provider = note.object as? ASRProvider {
                defaultASRProvider = provider
            } else {
                defaultASRProvider = KeychainService.selectedASRProvider
            }
        }
    }

    // MARK: - Category Picker (Segmented Capsule)

    private var categoryPicker: some View {
        LiquidGlassTabPicker(
            items: ModelCategory.allCases,
            selection: selectedCategory,
            onSelectionChange: { newCategory in
                selectedCategory = newCategory
            }
        ) { category, isSelected, _ in
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 11, weight: .semibold))
                Text(category.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
            }
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
            .padding(.horizontal, 16)
            .frame(height: 30)
        }
        .fixedSize()
    }

    // MARK: - Set Default Actions

    private func handleSetDefaultASR(_ provider: ASRProvider) {
        let oldProvider = defaultASRProvider
        KeychainService.selectedASRProvider = provider
        defaultASRProvider = provider

        // Manage server lifecycle for Sherpa local ASR
        if oldProvider == .sherpa && provider != .sherpa {
            Task {
                await SenseVoiceServerManager.shared.stopQwen3()
                #if HAS_SHERPA_ONNX
                SenseVoiceASRClient.releaseCachedModels()
                #endif
            }
        } else if provider == .sherpa {
            if !sensevoiceEnabled && !qwen3FinalEnabled {
                qwen3FinalEnabled = true
            }
            Task {
                try? await SenseVoiceServerManager.shared.start()
            }
        }
    }

    private func handleSetDefaultLLM(_ provider: LLMProvider) {
        KeychainService.selectedLLMProvider = provider
        defaultLLMProvider = provider
    }
}
