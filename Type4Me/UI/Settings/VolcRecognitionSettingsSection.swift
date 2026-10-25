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
                segmentationCard
                textCard
                releaseCard
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
                "停顿约 3 秒才断句，整句一起加标点。说话常停顿时标点更准，松手后约 0.7 秒出字。",
                "Waits for about 3 s of silence before ending a sentence, so pauses don't break punctuation. Text appears about 0.7 s after release."
            )
        case .fast:
            return L(
                "停顿约 0.8 秒就断句，松手后约 0.5 秒出字。停顿多时，句子中间可能多出句号。",
                "Ends a sentence after about 0.8 s of silence. Text appears about 0.5 s after release, but pauses may add stray full stops."
            )
        case .custom:
            return L(
                "按下面的设置识别。",
                "Uses the settings below."
            )
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

    // MARK: - Custom: segmentation

    private var custom: VolcTuningSettings { profile.custom ?? .accurate }

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

    private var segmentationCard: some View {
        settingsGroupCard(L("断句", "Sentence Breaks"), icon: "text.line.first.and.arrowtriangle.forward") {
            settingsToggleRow(
                L("逐句精修", "Refine Each Sentence"),
                subtitle: L(
                    "每句话结束后，用更准确的模型把这句再识别一遍。关闭后出字略快，但准确率会下降。",
                    "After each sentence, recognize it again with a more accurate model. Turning this off is slightly faster but less accurate."
                ),
                isOn: customBinding(\.enableNonstream)
            )

            SettingsDivider()

            settingsOptionRow(
                L("断句方式", "How Sentences End"),
                subtitle: custom.sendEndWindowSize
                    ? L("停顿超过设定时长就结束这一句。", "A sentence ends once you pause longer than the set time.")
                    : (custom.enableNonstream
                        ? L("由火山决定，停顿约 0.8 秒就结束这一句。", "Volcano decides, ending a sentence after about 0.8 s of silence.")
                        : L("由火山按语义判断一句话是否结束。", "Volcano decides from the meaning whether a sentence has ended.")),
                controlWidth: SettingsControlWidth.standard
            ) {
                settingsDropdown(
                    selection: Binding(
                        get: { custom.sendEndWindowSize ? "pause" : "auto" },
                        set: { value in
                            var settings = custom
                            settings.sendEndWindowSize = value == "pause"
                            // The opening grace only works together with a pause threshold.
                            settings.sendForceToSpeechTime = settings.sendEndWindowSize
                            profile.custom = settings
                        }
                    ),
                    options: [
                        ("auto", L("由火山决定", "Let Volcano Decide")),
                        ("pause", L("按停顿时长", "By Pause Length")),
                    ]
                )
            }

            if custom.sendEndWindowSize {
                SettingsDivider()
                secondsSliderRow(
                    L("停顿多久算一句结束", "Pause That Ends a Sentence"),
                    subtitle: L(
                        "越短出字越快，但思考时的停顿也会被断开，句中容易多出句号。说话常停顿建议 2.5–3 秒。",
                        "Shorter is faster but also breaks at thinking pauses, adding stray full stops. If you pause often, try 2.5–3 s."
                    ),
                    milliseconds: customBinding(\.endWindowSizeMs),
                    range: VolcTuningSettings.endWindowRange
                )

                SettingsDivider()
                secondsSliderRow(
                    L("开口保护", "Opening Grace"),
                    subtitle: L(
                        "刚开口的这段时间里不断句，避免开头被切碎。0 表示不保护，火山建议 1 秒。",
                        "No sentence breaks during this first stretch of speech, so the opening isn't chopped up. 0 turns it off; Volcano suggests 1 s."
                    ),
                    milliseconds: customBinding(\.forceToSpeechTimeMs),
                    range: VolcTuningSettings.forceToSpeechRange
                )
            }

            if !custom.enableNonstream && !custom.sendEndWindowSize {
                SettingsDivider()
                settingsToggleRow(
                    L("限制最长停顿", "Limit Pause Length"),
                    subtitle: L(
                        "按语义断句时，停顿超过设定时长也一定会断开。不开启时火山按 3 秒处理。",
                        "With meaning-based breaks, a pause longer than this always ends the sentence. Volcano uses 3 s when this is off."
                    ),
                    isOn: customBinding(\.sendVadSegmentDuration)
                )
                if custom.sendVadSegmentDuration {
                    SettingsDivider()
                    secondsSliderRow(
                        L("最长停顿", "Longest Pause"),
                        subtitle: L("停顿超过这个时长就断开。", "Pauses longer than this always end the sentence."),
                        milliseconds: customBinding(\.vadSegmentDurationMs),
                        range: VolcTuningSettings.vadSegmentRange
                    )
                }
            }
        }
    }

    // MARK: - Custom: text

    private var textCard: some View {
        settingsGroupCard(L("文字", "Text"), icon: "textformat") {
            settingsToggleRow(
                L("中文句子之间不加空格", "No Spaces Between Chinese Sentences"),
                subtitle: L(
                    "火山会在两句话之间插入空格。开启后中文直接相连，英文单词之间仍保留空格。",
                    "Volcano inserts a space between sentences. When on, Chinese sentences join directly while English words keep their spaces."
                ),
                isOn: customBinding(\.cjkAwareJoin)
            )
            SettingsDivider()
            settingsToggleRow(
                L("自动加标点", "Automatic Punctuation"),
                isOn: customBinding(\.enablePunc)
            )
            SettingsDivider()
            settingsToggleRow(
                L("数字写成阿拉伯数字", "Write Numbers as Digits"),
                subtitle: L("例如“一九七零年”写成“1970年”。", "For example, “nineteen seventy” becomes “1970”."),
                isOn: customBinding(\.enableITN)
            )
            SettingsDivider()
            settingsToggleRow(
                L("去掉口头禅和重复", "Remove Fillers and Repeats"),
                subtitle: L(
                    "删除“嗯”“那个”等语气词和无意义的重复。",
                    "Removes fillers such as “um” and unintended repetitions."
                ),
                isOn: customBinding(\.enableDDC)
            )
            SettingsDivider()
            settingsToggleRow(
                L("开头几个字更快出现", "Show First Words Sooner"),
                subtitle: L(
                    "说话时开头的字出现得更早，但这几个字可能不太准。",
                    "The first words appear sooner while you speak, but may be less accurate."
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
                    L("加速程度", "Speed-up Level"),
                    subtitle: L("数值越大越快，准确率下降也越多。", "Higher is faster, with a larger accuracy cost."),
                    value: customBinding(\.accelerateScore),
                    range: 1...VolcTuningSettings.accelerateScoreRange.upperBound,
                    step: 1,
                    format: { "\($0)" }
                )
            }
        }
    }

    // MARK: - Custom: release

    private var releaseCard: some View {
        settingsGroupCard(L("松手后", "After Release"), icon: "hand.raised") {
            secondsSliderRow(
                L("最长等待", "Maximum Wait"),
                subtitle: L(
                    "松手后最多等火山多久返回最终结果。大多数情况 1 秒内就会返回。",
                    "How long to wait for Volcano's final result after release. It usually arrives within 1 s."
                ),
                milliseconds: customBinding(\.finalWaitMs),
                range: VolcTuningSettings.finalWaitRange
            )
            SettingsDivider()
            settingsOptionRow(
                L("等不到时", "If It Takes Longer"),
                subtitle: L(
                    "直接输入更快，但可能少最后几个字。",
                    "Typing right away is faster but may miss the last few words."
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
                        ("commit", L("输入已识别的文字", "Type What's Recognized")),
                        ("wait", L("再多等最多 5 秒", "Wait Up to 5 s More")),
                    ]
                )
            }
            SettingsDivider()
            secondsSliderRow(
                L("短录音的等待", "Short Recording Wait"),
                subtitle: L(
                    "录音不足 5 秒且还没出字时，最多等这么久；仍没有文字就当作没说话。",
                    "For recordings under 5 s with no text yet, wait this long before treating it as silence."
                ),
                milliseconds: customBinding(\.shortRecordingFirstTextWaitMs),
                range: VolcTuningSettings.shortRecordingWaitRange
            )
            SettingsDivider()
            settingsOptionRow(
                L("音频发送间隔", "Audio Send Interval"),
                subtitle: L(
                    "录音时每隔多久把声音发给火山一次。间隔越短，文字出现得越及时，网络请求也越多。",
                    "How often audio is sent to Volcano while recording. Shorter intervals show text sooner but make more requests."
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
                    options: VolcTuningSettings.audioChunkOptions.map {
                        (String($0), L("\($0) 毫秒", "\($0) ms"))
                    }
                )
            }
        }
    }

    // MARK: - Controls

    private func secondsSliderRow(
        _ label: String,
        subtitle: String,
        milliseconds: Binding<Int>,
        range: ClosedRange<Int>
    ) -> some View {
        sliderRow(
            label,
            subtitle: subtitle,
            value: milliseconds,
            range: range,
            step: 100,
            format: { ms in
                let seconds = String(format: "%.1f", Double(ms) / 1000)
                return L("\(seconds) 秒", "\(seconds) s")
            }
        )
    }

    private func sliderRow(
        _ label: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        format: @escaping (Int) -> String
    ) -> some View {
        settingsOptionRow(label, subtitle: subtitle, controlWidth: sliderWidth, isIndented: true) {
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
                    .frame(width: 64, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}
