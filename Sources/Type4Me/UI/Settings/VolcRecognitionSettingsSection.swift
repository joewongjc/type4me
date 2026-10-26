import SwiftUI

/// Advanced Volcano recognition settings: a preset (accurate / fast) or a
/// custom set of parameters. Saved immediately; applies from the next recording.
struct VolcRecognitionSettingsSection: View, SettingsCardHelpers {
    @State private var profile = VolcRecognitionProfileStore.load()
    @State private var pendingResetSource: VolcRecognitionPreset?

    private let sliderWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetCard
            if profile.preset == .custom {
                requestCard
                clientCard
            }
        }
        .animation(.easeInOut(duration: 0.2), value: profile.preset)
        .onChange(of: profile) { _, newValue in
            VolcRecognitionProfileStore.save(newValue)
        }
        .alert(
            L("重置自定义设置", "Reset Custom Settings"),
            isPresented: Binding(
                get: { pendingResetSource != nil },
                set: { if !$0 { pendingResetSource = nil } }
            ),
            presenting: pendingResetSource
        ) { source in
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("重置", "Reset"), role: .destructive) {
                profile.custom = settings(for: source)
            }
        } message: { source in
            Text(L(
                "自定义设置会改成和「\(source.displayName)」一样，当前的调整将丢失。",
                "Custom settings will match \(source.displayName). Your current adjustments will be lost."
            ))
        }
    }

    // MARK: - Preset

    private var presetCard: some View {
        settingsGroupCard(
            L("识别高级设置", "Advanced Recognition"),
            icon: "slider.horizontal.3",
            trailing: profile.preset == .custom ? AnyView(resetMenu) : nil
        ) {
            settingsOptionRow(
                L("识别方案", "Recognition Profile"),
                subtitle: presetDescription(profile.preset),
                controlWidth: 240
            ) {
                settingsInlineSegmentedPicker(
                    selection: Binding(
                        get: { profile.preset.rawValue },
                        set: { raw in
                            guard let preset = VolcRecognitionPreset(rawValue: raw) else { return }
                            select(preset)
                        }
                    ),
                    options: VolcRecognitionPreset.allCases.map { ($0.rawValue, $0.displayName) },
                    segmentWidth: 72
                )
            }

            SettingsDivider()

            Text(L(
                "只影响火山引擎，从下一次录音开始生效。",
                "Applies to Volcano only, starting with the next recording."
            ))
            .font(.system(size: 10))
            .foregroundStyle(TF.settingsTextTertiary)
            .padding(.vertical, 8)
        }
    }

    private func presetDescription(_ preset: VolcRecognitionPreset) -> String {
        switch preset {
        case .accurate:
            return L(
                "end_window_size 3000 ms，force_to_speech_time 0。松手后最多等 2000 ms，超时继续等待。2026-10 评测中松手到出字的中位数约 690 ms。",
                "end_window_size 3000 ms, force_to_speech_time 0. Waits up to 2000 ms after release, then keeps waiting. Median release-to-text in the 2026-10 benchmark: about 690 ms."
            )
        case .fast:
            return L(
                "不发送 end_window_size，由服务端按约 800 ms 静音判停。松手后最多等 3000 ms，超时直接使用当前文本。评测中位数约 520 ms，停顿处出现句号的情况多于「准确」。",
                "end_window_size not sent, so the server ends sentences after about 800 ms of silence. Waits up to 3000 ms after release, then uses the current text. Benchmark median about 520 ms, with more full stops at pauses than Accurate."
            )
        case .custom:
            return L("使用下方参数。", "Uses the parameters below.")
        }
    }

    private var resetMenu: some View {
        Menu {
            Button(L("改成和「准确」一样", "Match Accurate")) { pendingResetSource = .accurate }
            Button(L("改成和「快速」一样", "Match Fast")) { pendingResetSource = .fast }
        } label: {
            Text(L("重置", "Reset"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(L("重置自定义设置", "Reset custom settings"))
    }

    private func select(_ preset: VolcRecognitionPreset) {
        guard preset != profile.preset else { return }
        if preset == .custom, profile.custom == nil {
            // Start from whatever the user was hearing a moment ago.
            profile.custom = profile.effectiveSettings
        }
        profile.preset = preset
    }

    private func settings(for preset: VolcRecognitionPreset) -> VolcTuningSettings {
        switch preset {
        case .accurate, .custom: return .accurate
        case .fast: return .fast
        }
    }

    // MARK: - Custom

    private var custom: VolcTuningSettings { profile.custom ?? .fast }

    private func customBinding<Value>(_ keyPath: WritableKeyPath<VolcTuningSettings, Value>) -> Binding<Value> {
        Binding(
            get: { custom[keyPath: keyPath] },
            set: { newValue in
                var settings = custom
                settings[keyPath: keyPath] = newValue
                profile.custom = settings
            }
        )
    }

    /// Volcano request fields, labelled with their API names.
    private var requestCard: some View {
        settingsGroupCard(L("请求参数", "Request Parameters"), icon: "curlybraces") {
            fieldToggleRow(
                "enable_nonstream",
                subtitle: L(
                    "二遍识别。每句判停后，服务端用非流式模型重新识别该句音频；只有重新识别的结果带 definite 标记。关闭后只返回流式识别结果。",
                    "Two-pass recognition. After each sentence ends, the server re-recognizes its audio with the non-streaming model; only that result is marked definite. When off, only streaming results are returned."
                ),
                isOn: customBinding(\.enableNonstream)
            )
            SettingsDivider()
            fieldToggleRow(
                "end_window_size",
                subtitle: L(
                    "判停所需的静音时长，文档默认 800 ms、最小 200 ms。发送后按静音时长分句，不再使用语义分句。不发送时：开启 enable_nonstream 则服务端约 800 ms 判停，否则使用语义分句。",
                    "Silence needed to end a sentence; documented default 800 ms, minimum 200 ms. When sent, sentences split by silence instead of meaning. When not sent: about 800 ms with enable_nonstream on, otherwise meaning-based splitting."
                ),
                isOn: Binding(
                    get: { custom.sendEndWindowSize },
                    set: { on in
                        var settings = custom
                        settings.sendEndWindowSize = on
                        if !on { settings.sendForceToSpeechTime = false }
                        profile.custom = settings
                    }
                )
            )
            if custom.sendEndWindowSize {
                SettingsDivider()
                millisecondsSliderRow(
                    L("取值", "Value"),
                    milliseconds: customBinding(\.endWindowSizeMs),
                    range: VolcTuningSettings.endWindowRange
                )
            }
            SettingsDivider()
            fieldToggleRow(
                "force_to_speech_time",
                subtitle: L(
                    "音频时长超过该值后才会判停，之前的静音不会结束句子。需要同时发送 end_window_size。文档最小值 1 ms、推荐 1000 ms，并提示可能影响准确率。",
                    "No sentence ends until the audio is longer than this. Requires end_window_size. Documented minimum 1 ms, recommended 1000 ms, noted as possibly affecting accuracy."
                ),
                isOn: customBinding(\.sendForceToSpeechTime),
                isEnabled: custom.sendEndWindowSize
            )
            if custom.sendEndWindowSize && custom.sendForceToSpeechTime {
                SettingsDivider()
                millisecondsSliderRow(
                    L("取值", "Value"),
                    milliseconds: customBinding(\.forceToSpeechTimeMs),
                    range: VolcTuningSettings.forceToSpeechRange
                )
            }
            SettingsDivider()
            fieldToggleRow(
                "vad_segment_duration",
                subtitle: L(
                    "语义分句的最大静音阈值，文档默认 3000 ms：静音超过该值即分句，但不改变 definite 出现的时机。发送 end_window_size 时失效。2026-10 实测中，把它从 3000 调到 4000 没有改变分句结果。",
                    "Maximum silence for meaning-based splitting; documented default 3000 ms. Longer silence always splits, without changing when definite appears. Ignored when end_window_size is sent. In 2026-10 tests, raising it from 3000 to 4000 did not change the splits."
                ),
                isOn: customBinding(\.sendVadSegmentDuration)
            )
            if custom.sendVadSegmentDuration {
                SettingsDivider()
                millisecondsSliderRow(
                    L("取值", "Value"),
                    milliseconds: customBinding(\.vadSegmentDurationMs),
                    range: VolcTuningSettings.vadSegmentRange
                )
            }
            SettingsDivider()
            fieldToggleRow(
                "enable_punc",
                subtitle: L("在识别结果中加入标点。文档默认开启。", "Adds punctuation to results. Documented default: on."),
                isOn: customBinding(\.enablePunc)
            )
            SettingsDivider()
            fieldToggleRow(
                "enable_itn",
                subtitle: L(
                    "文本规范化，把数字、日期等转成书面形式，例如“一九七零年”→“1970年”。文档默认开启。",
                    "Inverse text normalization: numbers, dates and similar become written form, e.g. “nineteen seventy” → “1970”. Documented default: on."
                ),
                isOn: customBinding(\.enableITN)
            )
            SettingsDivider()
            fieldToggleRow(
                "enable_ddc",
                subtitle: L(
                    "语义顺滑，删除语气词、停顿词和语义重复的词。文档默认关闭。",
                    "Disfluency removal: deletes fillers, hesitation words and repeated words. Documented default: off."
                ),
                isOn: customBinding(\.enableDDC)
            )
            SettingsDivider()
            fieldToggleRow(
                "enable_accelerate_text",
                subtitle: L(
                    "加快首字返回，文档说明会降低首字准确率。文档默认关闭。",
                    "Returns the first characters sooner; documented to lower their accuracy. Documented default: off."
                ),
                isOn: Binding(
                    get: { custom.enableAccelerateText },
                    set: { on in
                        var settings = custom
                        settings.enableAccelerateText = on
                        if on && settings.accelerateScore == 0 { settings.accelerateScore = 10 }
                        profile.custom = settings
                    }
                )
            )
            if custom.enableAccelerateText {
                SettingsDivider()
                sliderRow(
                    "accelerate_score",
                    subtitle: L("首字加速率，取值 0–20，越大首字返回越快。", "First-character speed-up, 0–20; higher returns sooner."),
                    value: customBinding(\.accelerateScore),
                    range: VolcTuningSettings.accelerateScoreRange,
                    step: 1,
                    format: { "\($0)" }
                )
            }
            SettingsDivider()
            sliderRow(
                "context_history_length",
                subtitle: L(
                    "火山文档中没有找到这个字段的说明。取值 0 时不发送。「准确」为 20，「快速」为 50。",
                    "No description of this field was found in the Volcano docs. 0 omits it. Accurate uses 20, Fast uses 50."
                ),
                value: customBinding(\.contextHistoryLength),
                range: VolcTuningSettings.contextHistoryRange,
                step: 1,
                format: { "\($0)" }
            )
        }
    }

    /// Handling done by Type4Me itself; no Volcano field behind these.
    private var clientCard: some View {
        settingsGroupCard(L("客户端处理", "Client Handling"), icon: "laptopcomputer") {
            settingsToggleRow(
                L("分句拼接", "Sentence Joining"),
                subtitle: L(
                    "开启：把各句文本直接相连，相邻任一侧是中文或全角标点时不加空格，英文之间加一个空格。关闭：使用服务端的 result.text，句与句之间有一个 ASCII 空格。",
                    "On: joins sentence texts directly, with no space when either side is Chinese or full-width punctuation and one space between English words. Off: uses the server's result.text, which has an ASCII space between sentences."
                ),
                isOn: customBinding(\.cjkAwareJoin)
            )
            SettingsDivider()
            millisecondsSliderRow(
                L("松手后最长等待", "Maximum Wait After Release"),
                subtitle: L(
                    "停止录音后，等待服务端最终结果的上限。不足 5 秒的录音另取 1000 ms 与此值中较小的一个。",
                    "Upper limit for waiting on the server's final result after recording stops. Recordings under 5 s use the smaller of this and 1000 ms."
                ),
                milliseconds: customBinding(\.finalWaitMs),
                range: VolcTuningSettings.finalWaitRange
            )
            SettingsDivider()
            settingsOptionRow(
                L("超时处理", "On Timeout"),
                subtitle: L(
                    "超过等待上限后的做法。直接使用当前文本时，服务端尚未返回的末尾文字不会出现在结果里。",
                    "What happens after the wait limit. With the current text, any ending the server has not returned yet is missing."
                ),
                controlWidth: SettingsControlWidth.standard
            ) {
                settingsDropdown(
                    selection: Binding(
                        get: { custom.commitOnFinalTimeout ? "commit" : "wait" },
                        set: { value in
                            var settings = custom
                            settings.commitOnFinalTimeout = value == "commit"
                            profile.custom = settings
                        }
                    ),
                    options: [
                        ("commit", L("使用当前文本", "Use Current Text")),
                        ("wait", L("继续等待，最多 5000 ms", "Keep Waiting, Up to 5000 ms")),
                    ]
                )
            }
            SettingsDivider()
            millisecondsSliderRow(
                L("短录音首字等待", "Short Recording First-Text Wait"),
                subtitle: L(
                    "录音不足 5 秒且还没有任何识别文本时的等待上限，超时后视为没有语音。",
                    "For recordings under 5 s with no text yet, the wait limit before treating the recording as silent."
                ),
                milliseconds: customBinding(\.shortRecordingFirstTextWaitMs),
                range: VolcTuningSettings.shortRecordingWaitRange
            )
            SettingsDivider()
            settingsOptionRow(
                L("音频分包时长", "Audio Packet Length"),
                subtitle: L(
                    "录音时每个音频包包含的时长。火山建议 100–200 ms。",
                    "Duration of audio in each packet sent while recording. Volcano suggests 100–200 ms."
                ),
                controlWidth: SettingsControlWidth.standard
            ) {
                settingsDropdown(
                    selection: Binding(
                        get: { String(custom.audioChunkMs) },
                        set: { value in
                            var settings = custom
                            settings.audioChunkMs = Int(value) ?? 200
                            profile.custom = settings
                        }
                    ),
                    options: VolcTuningSettings.audioChunkOptions.map { (String($0), "\($0) ms") }
                )
            }
        }
    }

    private func fieldToggleRow(
        _ field: String,
        subtitle: String,
        isOn: Binding<Bool>,
        isEnabled: Bool = true
    ) -> some View {
        settingsOptionRow(field, subtitle: subtitle, controlWidth: SettingsControlWidth.toggle) {
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(TF.settingsInk)
                .disabled(!isEnabled)
                .accessibilityLabel(field)
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }

    // MARK: - Controls

    private func millisecondsSliderRow(
        _ label: String,
        subtitle: String? = nil,
        milliseconds: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        sliderRow(
            label,
            subtitle: subtitle,
            value: milliseconds,
            range: range,
            step: 100,
            format: { "\($0) ms" }
        )
    }

    private func sliderRow(
        _ label: String,
        subtitle: String?,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        format: @escaping (Int) -> String
    ) -> some View {
        settingsOptionRow(label, subtitle: subtitle, controlWidth: sliderWidth, isIndented: subtitle == nil) {
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(value.wrappedValue) },
                        set: { value.wrappedValue = Int(($0 / Double(step)).rounded()) * step }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: Double(step)
                )
                .controlSize(.small)
                .tint(TF.settingsInk)
                .accessibilityLabel(label)
                .accessibilityValue(format(value.wrappedValue))

                Text(format(value.wrappedValue))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(TF.settingsText)
                    .frame(width: 72, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}
