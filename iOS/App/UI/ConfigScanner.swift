import AVFoundation
import SwiftUI
import Type4MeTransferCore

/// Scans the codes the Mac shows under「设置 › 模型 › 同步到 iPhone」.
///
/// A large sync is split into several codes that the Mac cycles through. The
/// scanner keeps what it already has, shows how many are in, and hands over
/// the payload only once every code has been read. Each code stays up for
/// half a second on the Mac, so decoding runs on every camera frame.
struct ConfigScannerSheet: View {
    /// A code the system camera already read, when that is how we got here.
    var seed: String?
    /// Receives the complete payload, ready for the import page.
    let onPayload: (Type4MeTransferPayload) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var assembler = Type4MeTransferAssembler()
    @State private var received: Set<Int> = []
    @State private var total = 0
    @State private var failure: String?
    @State private var finished = false
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let frames = debugFrames {
                    // Simulator check: replay codes as the Mac would cycle them.
                    Color.black.ignoresSafeArea()
                        .task {
                            var index = 0
                            while !finished {
                                handle(frames[index % frames.count])
                                index += 1
                                try? await Task.sleep(for: .milliseconds(500))
                            }
                        }
                    statusPanel
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                } else if camera == .authorized, QRScanner.isAvailable {
                    QRScanner(onCode: handle)
                        .ignoresSafeArea()
                    statusPanel
                        .padding(.horizontal, 20)
                        .padding(.bottom, 28)
                } else if camera == .notDetermined {
                    Color.black.ignoresSafeArea()
                } else {
                    unavailable
                }
            }
            .navigationTitle(L("扫码同步", "Scan to Sync"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel"), systemImage: "xmark") { dismiss() }
                }
            }
        }
        .onAppear {
            if let seed { handle(seed) }
        }
        .task {
            guard camera == .notDetermined else { return }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            camera = granted ? .authorized : .denied
        }
    }

    private var debugFrames: [String]? {
        #if DEBUG
        let lines = DemoSeed.debugFile("T4M_SCAN_FILE")?.split(separator: "\n").map(String.init) ?? []
        return lines.isEmpty ? nil : lines
        #else
        return nil
        #endif
    }

    // MARK: - Status

    private var statusPanel: some View {
        VStack(spacing: 10) {
            if total > 1 {
                HStack(spacing: 4) {
                    ForEach(1...total, id: \.self) { index in
                        Capsule()
                            .fill(received.contains(index) ? Color.white : Color.white.opacity(0.25))
                            .frame(height: 6)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: received)
                Text(L("已扫 \(received.count) / \(total) 张，保持对准，Mac 上的码会自动切换", "\(received.count) of \(total) scanned. Keep pointing; the codes on the Mac change by themselves"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .monospacedDigit()
            } else {
                Text(L("对准 Mac 上「同步到 iPhone」的二维码", "Point at the Sync to iPhone code on your Mac"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
            }
            if let failure {
                Text(failure)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(red: 1, green: 0.62, blue: 0.56))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(.black.opacity(0.35)), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var unavailable: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.badge.ellipsis")
                .font(.system(size: 40))
                .foregroundStyle(T4.tertiary)
            Text(camera == .authorized
                ? L("这台设备现在不能扫码", "Scanning isn't available on this device")
                : L("需要相机权限才能扫码", "Scanning needs camera access"))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(T4.ink)
            Text(L(
                "同步时用相机扫 Mac 上的二维码。到系统设置里允许 Type4Me 使用相机后再试。",
                "Syncing scans the code on your Mac with the camera. Allow camera access for Type4Me in Settings, then try again."
            ))
            .font(.system(size: 14))
            .foregroundStyle(T4.secondary)
            .multilineTextAlignment(.center)
            if camera != .authorized {
                Button(L("打开系统设置", "Open Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .buttonStyle(SecondaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DottedCanvas())
    }

    // MARK: - Assembling

    private func handle(_ code: String) {
        guard !finished else { return }
        switch assembler.add(code) {
        case .ignored:
            break
        case .progress(let parts, let count):
            if !parts.isSubset(of: received) || count != total {
                UISelectionFeedbackGenerator().selectionChanged()
            }
            received = parts
            total = count
            failure = nil
        case .complete(let payload):
            finished = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onPayload(payload)
        case .failed(let error):
            received = []
            total = 0
            if case .unsupportedVersion = error {
                failure = L("这是新版 Mac 导出的配置，先更新 iPhone 版 Type4Me。", "This comes from a newer Mac version. Update Type4Me on your iPhone first.")
            } else {
                failure = L("这组码没能拼出完整配置，正在重新扫描。", "Those codes didn't add up to a complete setup. Scanning again.")
            }
        }
    }
}

/// Live QR decoding with `AVCaptureMetadataOutput`, which reads every frame
/// (about 30 a second). VisionKit's data scanner tracks items instead and is
/// slow to notice a code that changes in place, so it missed frames of the
/// Mac's cycling codes.
private struct QRScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    static var isAvailable: Bool { AVCaptureDevice.default(for: .video) != nil }

    func makeUIViewController(context: Context) -> QRCaptureController {
        let controller = QRCaptureController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: QRCaptureController, context: Context) {
        controller.onCode = onCode
    }

    static func dismantleUIViewController(_ controller: QRCaptureController, coordinator: ()) {
        controller.stop()
    }
}

final class QRCaptureController: UIViewController {
    var onCode: ((String) -> Void)? {
        didSet { engine.onCode = onCode }
    }

    private let engine = QRCaptureEngine()
    private let preview = AVCaptureVideoPreviewLayer()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = engine.session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        engine.start()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    func stop() { engine.stop() }
}

/// Owns the capture session; everything except `onCode` runs on its queue.
private final class QRCaptureEngine: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Called on the main queue with each newly seen code.
    @MainActor var onCode: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.type4me.ios.qr-scanner")
    private var last: String?

    func start() {
        queue.async { [self] in
            configure()
            session.startRunning()
        }
    }

    func stop() {
        queue.async { [self] in
            if session.isRunning { session.stopRunning() }
        }
    }

    private func configure() {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }
        session.beginConfiguration()
        // Dense codes read better from more pixels.
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = output.availableMetadataObjectTypes.contains(.qr) ? [.qr] : []
        }
        session.commitConfiguration()
        tune(device)
    }

    /// Focus close and zoom in just enough that a code held near the lens is
    /// still sharp: newer main cameras can't focus closer than ~20 cm.
    /// Follows Apple's AVCamBarcode sample.
    private func tune(_ device: AVCaptureDevice) {
        guard (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }

        let minimumFocus = Float(device.minimumFocusDistance)
        guard minimumFocus > 0 else { return }
        let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let fill = Float(dimensions.height) / Float(dimensions.width)
        let halfField = device.activeFormat.videoFieldOfView / 2 * .pi / 180
        // The Mac's code is about 6 cm across; plan for a 4 cm one.
        let codeDistance = (40 / fill) / tan(halfField)
        guard codeDistance < minimumFocus else { return }
        let zoom = CGFloat(minimumFocus / codeDistance)
        device.videoZoomFactor = min(zoom, device.activeFormat.videoMaxZoomFactor, 3)
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        for object in metadataObjects {
            guard let code = object as? AVMetadataMachineReadableCodeObject,
                  let value = code.stringValue, value != last
            else { continue }
            last = value
            DispatchQueue.main.async { [self] in
                MainActor.assumeIsolated { onCode?(value) }
            }
        }
    }
}
