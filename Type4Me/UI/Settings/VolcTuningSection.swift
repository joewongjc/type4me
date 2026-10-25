import SwiftUI

/// Experimental Volcano tuning panel. Changes are saved immediately and take
/// effect from the next recording.
struct VolcTuningSection: View, SettingsCardHelpers {
    @State private var settings = VolcTuningStorage.load()
    @State private var showResetConfirmation = false

    private let sliderWidth: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            presetsCard
            segmentationCard
            textCard
            finishCard
        }
        .onChange(of: settings) { _, newValue in
            VolcTuningStorage.save(newValue)
        }
        .alert(L("恢复默认参数", "Restore Default Parameters"), isPresented: $showResetConfirmation) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("恢复默认", "Restore"), role: .destructive) {
                settings = VolcTuningSettings()
                VolcTuningStorage.reset()
            }
        } message: {
            Text(L(
                "所有调参都会回到当前版本的默认值，下一次录音生效。",
                "Every parameter returns to the shipped default, starting with the next recording."
            ))
        }
    }

    // MARK: - Presets

    private var presetsCard: some View {
        settingsGroupCard(
            L("识别调参（实验）", "Recognition Tuning (Experimental)"),
            icon: "dial.medium",
            trailing: AnyView(
                Button(L("恢复默认", "Restore Defaults")) { showResetConfirmation = true }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .disabled(settings == VolcTuningSettings())
            )
        ) {
            Text(L(
                "只影响火山引擎。改动立即保存，从下一次录音开始生效；每次录音使用的参数会写进诊断日志（volc tuning 一行）。",
                "Volcano only. Changes save immediately and apply from the next recording; each recording logs its parameters (the \"volc tuning\" line in the diagnostic log)."
            ))
            .font(.system(size: 11))
            .foregroundStyle(TF.settingsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)

            SettingsDivider()

            settingsOptionRow(
                L("预设", "Presets"),
                subtitle: L(
                    "当前默认 = 正式版行为；均衡 = 1 秒判停 + 中文无空格拼接；快速 = 0.8 秒判停、松手最多等 0.6 秒、超时直接出字。",
                    "Default = shipped behavior; Balanced = 1 s endpoint + CJK join; Fast = 0.8 s endpoint, wait at most 0.6 s after release, then commit."
                ),
                controlWidth: SettingsControlWidth.provider
            ) {
                HStack(spacing: 6) {
                    presetButton(L("当前默认", "Default"), preset: VolcTuningSettings())
                    presetButton(L("均衡", "Balanced"), preset: Self.balancedPreset)
                    presetButton(L("快速", "Fast"), preset: Self.fastPreset)
                }
            }
        }
    }

    private func presetButton(_ title: String, preset: VolcTuningSettings) -> some View {
        let isActive = settings == preset
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { settings = preset }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? TF.settingsOnStrong : TF.settingsText)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? TF.settingsNavActive : TF.settingsCardAlt)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    static var balancedPreset: VolcTuningSettings {
        var preset = VolcTuningSettings()
        preset.endWindowSizeMs = 1000
        preset.forceToSpeechTimeMs = 1000
        preset.cjkAwareJoin = true
        return preset
    }

    static var fastPreset: VolcTuningSettings {
        var preset = balancedPreset
        preset.endWindowSizeMs = 800
        preset.finalWaitMs = 600
        preset.commitOnFinalTimeout = true
        preset.audioChunkMs = 100
        return preset
    }

    // MARK: - Segmentation

    private var segmentationCard: some View {
        settingsGroupCard(L("断句与判停", "Segmentation"), icon: "scissors") {
            settingsToggleRow(
                L("发送 end_window_size（静音判停）", "Send end_window_size (silence endpoint)"),
                subtitle: L(
                    "关闭后改用服务端语义分句；开着二遍识别时服务端按 800 ms 判停。",
                    "Off falls back to server semantic segmentation; with two-pass on, the server endpoints at 800 ms."
                ),
                isOn: $settings.sendEndWindowSize
            )
            SettingsDivider()
            msSliderRow(
                L("判停静音时长", "Endpoint silence"),
                subtitle: L(
                    "当前版本 3000 · 文档默认 800、最小 200 · 建议试 800–1200。越短越早定稿、松手越快；太短会把思考停顿切成两句。",
                    "Shipped 3000 · docs default 800, min 200 · try 800–1200. Shorter finalizes sooner and releases faster; too short splits thinking pauses."
                ),
                value: $settings.endWindowSizeMs,
                range: VolcTuningSettings.endWindowRange,
                step: 100,
                isEnabled: settings.sendEndWindowSize
            )
            SettingsDivider()
            settingsToggleRow(
                L("发送 force_to_speech_time", "Send force_to_speech_time"),
                subtitle: L("需配合静音判停使用。", "Works together with the silence endpoint."),
                isOn: $settings.sendForceToSpeechTime
            )
            SettingsDivider()
            msSliderRow(
                L("最短语音时长", "Minimum speech before endpoint"),
                subtitle: L(
                    "当前版本 0（低于文档最小值 1）· 文档推荐 1000。音频短于此值时服务端不判停，可减少开头被切碎。",
                    "Shipped 0 (below the documented min of 1) · docs recommend 1000. No endpoint before this much audio, so openings don't get chopped."
                ),
                value: $settings.forceToSpeechTimeMs,
                range: VolcTuningSettings.forceToSpeechRange,
                step: 100,
                isEnabled: settings.sendForceToSpeechTime
            )
            SettingsDivider()
            settingsToggleRow(
                L("发送 vad_segment_duration（语义切句）", "Send vad_segment_duration (semantic split)"),
                subtitle: L(
                    "只在关闭 end_window_size 时生效；它只分句、不判停，不改变 definite 出现的位置。",
                    "Only takes effect with end_window_size off; it splits sentences without endpointing, so definite timing is unchanged."
                ),
                isOn: $settings.sendVadSegmentDuration
            )
            SettingsDivider()
            msSliderRow(
                L("语义切句静音阈值", "Semantic split silence"),
                subtitle: L("文档默认 3000。", "Docs default 3000."),
                value: $settings.vadSegmentDurationMs,
                range: VolcTuningSettings.vadSegmentRange,
                step: 100,
                isEnabled: settings.sendVadSegmentDuration && !settings.sendEndWindowSize
            )
            SettingsDivider()
            settingsToggleRow(
                L("二遍识别（enable_nonstream）", "Two-pass recognition (enable_nonstream)"),
                subtitle: L(
                    "当前版本开。每句判停后用非流式模型单独重识别，更准；切得越碎上下文越少。关闭后不再有 definite 分句。",
                    "Shipped on. Each closed segment is re-recognized by the non-streaming model; finer cuts lose context. Off means no definite segments."
                ),
                isOn: $settings.enableNonstream
            )
        }
    }

    // MARK: - Text

    private var textCard: some View {
        settingsGroupCard(L("文本处理", "Text"), icon: "textformat") {
            settingsToggleRow(
                L("中文分句无空格拼接", "CJK-aware sentence join"),
                subtitle: L(
                    "当前版本关（原样使用服务端 result.text，两句中文之间会多一个空格，如“本 低”）。打开后按 Claude 的规则拼接：边界任一侧是中日文字或全角标点就不加空格。",
                    "Shipped off (uses the server's result.text, which puts a space between two Chinese sentences). On joins like Claude: no space when either side of the boundary is CJK or full-width punctuation."
                ),
                isOn: $settings.cjkAwareJoin
            )
            SettingsDivider()
            settingsToggleRow(
                L("标点（enable_punc）", "Punctuation (enable_punc)"),
                subtitle: L("当前版本开 · 文档默认开。", "Shipped on · docs default on."),
                isOn: $settings.enablePunc
            )
            SettingsDivider()
            settingsToggleRow(
                L("数字规范化（enable_itn）", "Inverse text normalization (enable_itn)"),
                subtitle: L(
                    "当前版本未发送（服务端默认开）。“一九七零年”→“1970年”。",
                    "Shipped unset (server default on). Spoken numbers become digits."
                ),
                isOn: $settings.enableITN
            )
            SettingsDivider()
            settingsToggleRow(
                L("语义顺滑（enable_ddc）", "Disfluency removal (enable_ddc)"),
                subtitle: L(
                    "当前版本开 · 文档默认关。删除语气词、重复词。",
                    "Shipped on · docs default off. Removes fillers and repetitions."
                ),
                isOn: $settings.enableDDC
            )
            SettingsDivider()
            settingsToggleRow(
                L("首字加速（enable_accelerate_text）", "Faster first characters (enable_accelerate_text)"),
                subtitle: L(
                    "当前版本关 · 文档默认关。首字更快出现，但首字准确率会下降。",
                    "Shipped off · docs default off. First characters appear sooner at some cost to their accuracy."
                ),
                isOn: $settings.enableAccelerateText
            )
            SettingsDivider()
            intSliderRow(
                L("加速强度（accelerate_score）", "Acceleration (accelerate_score)"),
                subtitle: L("0–20，越大越快。可以从 5–10 开始试。", "0–20; higher is faster. Start around 5–10."),
                value: $settings.accelerateScore,
                range: VolcTuningSettings.accelerateScoreRange,
                step: 1,
                unit: "",
                isEnabled: settings.enableAccelerateText
            )
            SettingsDivider()
            intSliderRow(
                L("上下文历史（context_history_length）", "Context history (context_history_length)"),
                subtitle: L(
                    "当前版本 20；设为 0 则不发送这个字段。",
                    "Shipped 20; 0 omits the field."
                ),
                value: $settings.contextHistoryLength,
                range: VolcTuningSettings.contextHistoryRange,
                step: 1,
                unit: "",
                isEnabled: true
            )
        }
    }

    // MARK: - Finish

    private var finishCard: some View {
        settingsGroupCard(L("松手与收尾", "Release & Finish"), icon: "hand.raised") {
            msSliderRow(
                L("松手后等最终结果的上限", "Max wait for the final result"),
                subtitle: L(
                    "当前版本 2000（不足 5 秒的短录音最多 1000）。实测中位数约 710、p90 约 940：设 800–1000 大多数情况仍拿得到完整结果。",
                    "Shipped 2000 (short recordings under 5 s cap at 1000). Measured median ~710, p90 ~940: 800–1000 still gets the full result most of the time."
                ),
                value: $settings.finalWaitMs,
                range: VolcTuningSettings.finalWaitRange,
                step: 100,
                isEnabled: true
            )
            SettingsDivider()
            settingsToggleRow(
                L("超时就直接用当前文字", "Commit current text on timeout"),
                subtitle: L(
                    "当前版本关：超时后继续等服务端结束（最多再等 5 秒）。打开后立刻写入当前文字，可能少最后几个字或标点。",
                    "Shipped off: keep waiting for the server to finish (up to 5 s more). On commits immediately and may drop the last few characters or punctuation."
                ),
                isOn: $settings.commitOnFinalTimeout
            )
            SettingsDivider()
            msSliderRow(
                L("短录音等首字", "Short recording first-text wait"),
                subtitle: L(
                    "当前版本 1000。录音不足 5 秒且还没出字时，等这么久仍没字就当作没说话。",
                    "Shipped 1000. For recordings under 5 s with no text yet, give up after this long and treat it as silence."
                ),
                value: $settings.shortRecordingFirstTextWaitMs,
                range: VolcTuningSettings.shortRecordingWaitRange,
                step: 100,
                isEnabled: true
            )
            SettingsDivider()
            settingsOptionRow(
                L("音频分包时长", "Audio packet size"),
                subtitle: L(
                    "当前版本 200 · 火山建议 100–200。更小的包让流式文字早一点出现，请求次数更多。",
                    "Shipped 200 · Volcano suggests 100–200. Smaller packets surface live text a little sooner with more requests."
                ),
                controlWidth: SettingsControlWidth.standard
            ) {
                settingsDropdown(
                    selection: Binding(
                        get: { String(settings.audioChunkMs) },
                        set: { settings.audioChunkMs = Int($0) ?? 200 }
                    ),
                    options: VolcTuningSettings.audioChunkOptions.map { (String($0), "\($0) ms") }
                )
            }
        }
    }

    // MARK: - Controls

    private func msSliderRow(
        _ label: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        isEnabled: Bool
    ) -> some View {
        intSliderRow(label, subtitle: subtitle, value: value, range: range, step: step, unit: "ms", isEnabled: isEnabled)
    }

    private func intSliderRow(
        _ label: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        step: Int,
        unit: String,
        isEnabled: Bool
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

                Text(unit.isEmpty ? "\(value.wrappedValue)" : "\(value.wrappedValue) \(unit)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(TF.settingsText)
                    .frame(width: 64, alignment: .trailing)
            }
            .disabled(!isEnabled)
        }
        .opacity(isEnabled ? 1.0 : 0.45)
    }
}
