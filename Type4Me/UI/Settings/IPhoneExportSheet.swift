import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI
import Type4MeTransferCore

/// Syncs a chosen set of models and modes to Type4Me on iPhone.
///
/// Small selections fit one QR code, which the iPhone camera opens directly.
/// Larger ones are split into numbered codes that cycle here until the
/// iPhone has scanned every one.
struct IPhoneExportSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var asrCandidates: [IPhoneConfigExporter.Candidate] = []
    @State private var llmCandidates: [IPhoneConfigExporter.Candidate] = []
    @State private var modeCandidates: [IPhoneConfigExporter.Candidate] = []
    @State private var selectedASRs: Set<String> = []
    @State private var defaultASR = ""
    @State private var selectedLLMs: Set<String> = []
    @State private var defaultLLM = ""
    @State private var selectedModes: Set<String> = []
    @State private var isRevealed = false
    @State private var frames: [NSImage] = []

    private static let qrSide: CGFloat = 280
    /// Time each code stays up while cycling. Long enough for the iPhone to
    /// lock on, short enough that a full round stays quick.
    private static let frameInterval: TimeInterval = 0.5

    private var payload: Type4MeTransferPayload? {
        IPhoneConfigExporter.makePayload(
            asrs: asrCandidates.map(\.id).filter(selectedASRs.contains),
            defaultASR: defaultASR,
            llms: llmCandidates.map(\.id).filter(selectedLLMs.contains),
            defaultLLM: defaultLLM,
            modes: modeCandidates.map(\.id).filter(selectedModes.contains)
        )
    }

    /// Changes whenever the selection does, to re-render the codes.
    private var selectionKey: String {
        [
            defaultASR, selectedASRs.sorted().joined(separator: ","),
            defaultLLM, selectedLLMs.sorted().joined(separator: ","),
            selectedModes.sorted().joined(separator: ","),
        ]
            .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("同步到 iPhone", "Sync to iPhone"))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                    Text(L(
                        "选好要同步的模型和模式，在 iPhone 版 Type4Me 里点「扫码同步」对准这里。内容多时会拆成几张码自动轮播，iPhone 扫齐所有码才算完成。",
                        "Pick the models and modes to sync, then tap Scan to Sync in Type4Me on iPhone and point it here. Larger selections are split into several codes that cycle automatically; the iPhone finishes once it has scanned them all."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                TFCloseButton { dismiss() }
            }

            if asrCandidates.isEmpty && llmCandidates.isEmpty && modeCandidates.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 22) {
                    VStack(alignment: .leading, spacing: 12) {
                        qrPanel
                        warning
                    }
                    .frame(width: Self.qrSide)

                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            asrSection
                            llmSection
                            modeSection
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 460)
                }
            }
        }
        .padding(24)
        .frame(width: 700)
        .background(TF.settingsBg)
        .onAppear(perform: load)
        .onChange(of: selectedASRs) { _, _ in fixDefaults() }
        .onChange(of: selectedLLMs) { _, _ in fixDefaults() }
        .onChange(of: selectionKey) { _, _ in render() }
    }

    // MARK: - QR

    private var qrPanel: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white)
                if frames.isEmpty {
                    Text(L("至少选一项", "Select at least one item"))
                        .font(.system(size: 12))
                        .foregroundStyle(Color.black.opacity(0.45))
                } else {
                    TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                        let index = frameIndex(at: context.date)
                        Image(nsImage: frames[index])
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(10)
                            .blur(radius: isRevealed ? 0 : 9)
                    }
                    if !isRevealed {
                        Button(L("显示二维码", "Show QR code")) { isRevealed = true }
                            .buttonStyle(.tf(.secondary, size: .small))
                    }
                }
            }
            .frame(width: Self.qrSide, height: Self.qrSide)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(TF.settingsTextTertiary.opacity(0.25), lineWidth: 1)
            )
            if frames.count > 1 {
                TimelineView(.periodic(from: .now, by: Self.frameInterval)) { context in
                    let index = frameIndex(at: context.date)
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            ForEach(frames.indices, id: \.self) { item in
                                Capsule()
                                    .fill(item == index ? TF.settingsText : TF.settingsTextTertiary.opacity(0.3))
                                    .frame(width: item == index ? 14 : 6, height: 6)
                            }
                        }
                        Text(L("共 \(frames.count) 张码，正在显示第 \(index + 1) 张", "\(frames.count) codes · showing \(index + 1)"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                            .monospacedDigit()
                    }
                }
            } else {
                Text(L("用 Type4Me 扫码，或 iPhone 相机扫码直接打开", "Scan in Type4Me, or with the iPhone camera"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
        }
    }

    private func frameIndex(at date: Date) -> Int {
        guard frames.count > 1 else { return 0 }
        return Int(date.timeIntervalSinceReferenceDate / Self.frameInterval) % frames.count
    }

    // MARK: - Selection

    private var asrSection: some View {
        section(
            L("语音识别", "Speech recognition"),
            note: asrCandidates.isEmpty
                ? L("iPhone 版支持所有云端识别服务，本地识别只能在 Mac 上用", "iPhone supports every cloud speech service; on-device engines stay on the Mac")
                : L("可以多选，在 iPhone 上切换。带「默认」的是 iPhone 上默认使用的。", "Pick several and switch on the iPhone. The one marked Default is used first.")
        ) {
            providerList(asrCandidates, selected: $selectedASRs, defaultID: $defaultASR)
        }
    }

    private var llmSection: some View {
        section(
            L("文本处理模型", "Text models"),
            note: llmCandidates.isEmpty
                ? L("iPhone 版支持所有云端文本模型，本机模型网关只能在 Mac 上用", "iPhone supports every cloud text model; local gateways stay on the Mac")
                : L("可以多选，在 iPhone 上切换。带「默认」的是 iPhone 上默认使用的。", "Pick several and switch on the iPhone. The one marked Default is used first.")
        ) {
            providerList(llmCandidates, selected: $selectedLLMs, defaultID: $defaultLLM)
        }
    }

    /// Checkboxes with one selected row marked Default.
    private func providerList(
        _ candidates: [IPhoneConfigExporter.Candidate],
        selected: Binding<Set<String>>,
        defaultID: Binding<String>
    ) -> some View {
        ForEach(candidates) { candidate in
            HStack(spacing: 8) {
                Toggle(isOn: binding(for: candidate.id, in: selected)) {
                    Text(candidate.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsText)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 8)
                if selected.wrappedValue.contains(candidate.id) {
                    if defaultID.wrappedValue == candidate.id {
                        Text(L("默认", "Default"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(TF.settingsAccentGreen)
                    } else {
                        Button(L("设为默认", "Make default")) { defaultID.wrappedValue = candidate.id }
                            .buttonStyle(.tf(.secondary, size: .small))
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        section(
            L("模式", "Modes"),
            note: L(
                "内置模式里只有快速、翻译、语音润色和代办适合手机；智能感知、Mac 操作、随便问、Prompt 优化只在 Mac 上用。你自己建的模式也可以同步。",
                "Of the built-in modes, only Quick, Translation, Voice Polish and Handle It suit the phone; Intelli Sense, Mac Action, Ask Anything and Prompt Optimizer stay on the Mac. Your own modes can sync too."
            )
        ) {
            ForEach(modeCandidates) { candidate in
                Toggle(isOn: binding(for: candidate.id, in: $selectedModes)) {
                    Text(candidate.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsText)
                }
                .toggleStyle(.checkbox)
            }
        }
    }

    private func section<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsText)
            content()
            if let note {
                Text(note)
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func binding(for id: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding(
            get: { set.wrappedValue.contains(id) },
            set: { on in
                if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
            }
        )
    }

    /// Each default must be one of the selected services.
    private func fixDefaults() {
        if !selectedASRs.contains(defaultASR) {
            defaultASR = asrCandidates.map(\.id).first(where: selectedASRs.contains) ?? ""
        }
        if !selectedLLMs.contains(defaultLLM) {
            defaultLLM = llmCandidates.map(\.id).first(where: selectedLLMs.contains) ?? ""
        }
    }

    private var warning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "key.fill")
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextSecondary)
                .padding(.top, 1)
            Text(L(
                "二维码里有你的 API Key，没有加密。只给自己的 iPhone 扫，不要截图分享。",
                "The QR codes contain your API keys unencrypted. Scan them only with your own iPhone; don't share screenshots."
            ))
            .font(.system(size: 11))
            .foregroundStyle(TF.settingsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        Text(L(
            "还没有可以同步的配置。iPhone 版支持所有云端语音识别和文本处理服务，本地模型只能在 Mac 上用。先在「模型」里配置好一个云端服务。",
            "Nothing to sync yet. iPhone supports every cloud speech and text service; local models stay on the Mac. Configure a cloud service under Models first."
        ))
        .font(.system(size: 12))
        .foregroundStyle(TF.settingsTextSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Actions

    private func load() {
        asrCandidates = IPhoneConfigExporter.asrCandidates()
        llmCandidates = IPhoneConfigExporter.llmCandidates()
        modeCandidates = IPhoneConfigExporter.modeCandidates()
        defaultASR = IPhoneConfigExporter.preferredASR(in: asrCandidates) ?? ""
        selectedASRs = defaultASR.isEmpty ? [] : [defaultASR]
        defaultLLM = IPhoneConfigExporter.preferredLLM(in: llmCandidates) ?? ""
        selectedLLMs = defaultLLM.isEmpty ? [] : [defaultLLM]
        selectedModes = Set(modeCandidates.map(\.id))
        render()
    }

    private func render() {
        guard let payload else {
            frames = []
            return
        }
        frames = ((try? Type4MeTransferCodec.encodeFrames(payload)) ?? []).compactMap(Self.qrImage(for:))
    }

    static func qrImage(for string: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // A screen shows the code undamaged, so the lowest error correction
        // is enough. It needs the fewest modules for the same data, which
        // gives larger modules the iPhone locks onto faster.
        filter.correctionLevel = "L"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
