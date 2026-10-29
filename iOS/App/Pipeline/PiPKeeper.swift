import AVKit
import CoreMedia
import UIKit

/// Keeps the PiP session needed to open the microphone from the background,
/// without leaving a visible window or the two glass endpoints on iOS 27.2.
/// AudioSessionKeeper owns the silent output; PiP never opens the microphone.
@MainActor
final class PiPKeeper: NSObject {
    var onLog: ((String) -> Void)?
    private(set) var isActive = false

    private let sourceView = SampleBufferView(
        frame: CGRect(x: 0, y: 0, width: 369, height: 0.1)
    )
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var settledStateTask: Task<Void, Never>?
    /// Test-period diagnostics: watches the content type while PiP runs, so
    /// the log shows when the glass endpoints could have come back.
    private var contentTypeWatch: Task<Void, Never>?
    private var lastLoggedContentType: Int?
    private var notificationObservers: [NSObjectProtocol] = []

    func prepare() {
        guard controller == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            onLog?(L("这台设备不支持画中画", "Picture in Picture isn't available on this device"))
            return
        }
        guard attachSourceView(), let buffer = Self.makeStillFrame() else {
            sourceView.removeFromSuperview()
            onLog?(L("画中画准备失败", "Couldn't prepare Picture in Picture"))
            return
        }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sourceView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = true
        self.controller = controller
        let controllerID = ObjectIdentifier(controller)
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] _, change in
            let possible = change.newValue ?? false
            Task { @MainActor in
                guard let self, self.controller.map(ObjectIdentifier.init) == controllerID else { return }
                if possible { self.ensureRunning() }
            }
        }
        // A single frame fixes the aspect ratio. No periodic renderer updates
        // are needed, and no malformed frame or user stash gesture is involved.
        sourceView.displayLayer.sampleBufferRenderer.enqueue(buffer)
        logContentType(L("画中画已创建", "PiP controller created"))
        observeSystemEvents()
    }

    // MARK: - Diagnostics

    /// The content type AVKit hands Pegasus: -1 hides the glass endpoints,
    /// anything else (VideoOnDemand by default) draws them.
    private func currentContentType(_ controller: AVPictureInPictureController) -> Int? {
        func object(_ receiver: NSObject, _ name: String) -> NSObject? {
            let selector = NSSelectorFromString(name)
            guard receiver.responds(to: selector) else { return nil }
            return receiver.perform(selector)?.takeUnretainedValue() as? NSObject
        }
        let getType = NSSelectorFromString("contentType")
        guard let adapter = object(controller, "platformAdapter"),
              let proxy = object(adapter, "pegasusProxy"),
              let state = object(proxy, "playbackState"),
              state.responds(to: getType) else { return nil }
        typealias GetType = @convention(c) (AnyObject, Selector) -> Int
        return unsafeBitCast(state.method(for: getType), to: GetType.self)(state, getType)
    }

    /// One line with the moment and what PiP looks like then. A type other
    /// than -1 while PiP is on means the endpoints are likely on screen.
    private func logContentType(_ moment: String) {
        guard let controller else { return }
        let type = currentContentType(controller)
        lastLoggedContentType = type
        let typeText = type.map(String.init) ?? L("读不到", "unreadable")
        let warning = controller.isPictureInPictureActive && type != -1 ? "⚠️ " : ""
        let app = UIApplication.shared.applicationState == .active ? L("前台", "foreground") : L("后台", "background")
        onLog?(L(
            "\(warning)画中画 \(moment)：ContentType = \(typeText)，\(controller.isPictureInPictureActive ? "开着" : "没开")，\(controller.isPictureInPicturePossible ? "可开" : "不可开")，App 在\(app)",
            "\(warning)PiP \(moment): ContentType = \(typeText), \(controller.isPictureInPictureActive ? "on" : "off"), \(controller.isPictureInPicturePossible ? "possible" : "not possible"), app in the \(app)"
        ))
    }

    /// Checks every two seconds while PiP is on and logs only a change, so
    /// a reset by AVKit shows up within a couple of seconds of happening.
    private func watchContentType() {
        contentTypeWatch?.cancel()
        contentTypeWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, let self, let controller = self.controller,
                      controller.isPictureInPictureActive else { return }
                if self.currentContentType(controller) != self.lastLoggedContentType {
                    self.logContentType(L("ContentType 变了", "ContentType changed"))
                }
            }
        }
    }

    /// The events suspected of resetting the content type.
    private func observeSystemEvents() {
        guard notificationObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let events: [(Notification.Name, (Notification) -> String)] = [
            (AVAudioSession.routeChangeNotification, { note in
                let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                return L("音频线路变化（原因 \(raw)）", "audio route changed (reason \(raw))")
            }),
            (AVAudioSession.interruptionNotification, { note in
                let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
                return raw == AVAudioSession.InterruptionType.began.rawValue
                    ? L("音频打断开始", "audio interruption began")
                    : L("音频打断结束", "audio interruption ended")
            }),
            (AVAudioSession.mediaServicesWereResetNotification, { _ in L("媒体服务重置", "media services reset") }),
            (UIApplication.didEnterBackgroundNotification, { _ in L("App 进入后台", "app entered the background") }),
            (UIApplication.willEnterForegroundNotification, { _ in L("App 回到前台", "app returning to the foreground") }),
        ]
        notificationObservers = events.map { name, describe in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let moment = describe(note)
                MainActor.assumeIsolated { self?.logContentType(moment) }
            }
        }
    }

    func tearDown() {
        settledStateTask?.cancel()
        settledStateTask = nil
        contentTypeWatch?.cancel()
        contentTypeWatch = nil
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
        notificationObservers = []
        possibleObservation = nil
        let oldController = controller
        controller = nil
        isActive = false
        oldController?.delegate = nil
        oldController?.stopPictureInPicture()
        sourceView.removeFromSuperview()
        sourceView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func ensureRunning() {
        guard let controller,
              !controller.isPictureInPictureActive,
              controller.isPictureInPicturePossible else { return }
        // AVKit initially supplies VideoOnDemand even for an invalid time
        // range. Pegasus draws glass endpoints for that content type.
        guard useUnspecifiedContentType(controller) else {
            onLog?(L("当前系统不支持隐藏画中画", "This iOS version can't hide Picture in Picture"))
            tearDown()
            return
        }
        logContentType(L("由 App 启动前", "about to be started by the app"))
        controller.startPictureInPicture()
    }

    /// Private Pegasus integration, verified on iOS 27.2 (24B5099f).
    /// 0 means Unknown; -1 is the unspecified/invalid content type that removes
    /// the glass endpoints while preserving the active PiP audio eligibility.
    /// Guard every selector: unsupported systems must not silently show dots.
    @discardableResult
    private func useUnspecifiedContentType(_ controller: AVPictureInPictureController) -> Bool {
        func object(_ receiver: NSObject, _ name: String) -> NSObject? {
            let selector = NSSelectorFromString(name)
            guard receiver.responds(to: selector) else { return nil }
            return receiver.perform(selector)?.takeUnretainedValue() as? NSObject
        }
        guard let adapter = object(controller, "platformAdapter"),
              let proxy = object(adapter, "pegasusProxy"),
              let state = object(proxy, "playbackState") else { return false }
        let update = NSSelectorFromString("updatePlaybackStateUsingBlock:")
        let setType = NSSelectorFromString("setContentType:")
        let getType = NSSelectorFromString("contentType")
        guard proxy.responds(to: update), state.responds(to: setType), state.responds(to: getType) else { return false }
        typealias SetType = @convention(c) (AnyObject, Selector, Int) -> Void
        typealias GetType = @convention(c) (AnyObject, Selector) -> Int
        typealias Update = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let block: @convention(block) (NSObject) -> Void = { mutableState in
            guard mutableState.responds(to: setType) else { return }
            unsafeBitCast(mutableState.method(for: setType), to: SetType.self)(mutableState, setType, -1)
        }
        unsafeBitCast(proxy.method(for: update), to: Update.self)(proxy, update, block as AnyObject)
        guard let updatedState = object(proxy, "playbackState"),
              updatedState.responds(to: getType) else { return false }
        return unsafeBitCast(updatedState.method(for: getType), to: GetType.self)(updatedState, getType) == -1
    }

    private func attachSourceView() -> Bool {
        if sourceView.superview != nil { return true }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow) else { return false }
        sourceView.isUserInteractionEnabled = false
        window.insertSubview(sourceView, at: 0)
        return true
    }

    private static func makeStillFrame() -> CMSampleBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, 5_040, 1, kCVPixelFormatType_32BGRA,
                                  attributes, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0, CVPixelBufferGetDataSize(pixelBuffer))
            let pixels = base.assumingMemoryBound(to: UInt8.self)
            for x in 0..<5_040 { pixels[x * 4 + 3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescription: format,
            sampleTiming: &timing, sampleBufferOut: &buffer
        ) == noErr, let buffer else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return buffer
    }
}

extension PiPKeeper: AVPictureInPictureControllerDelegate {
    /// Also reached when iOS starts PiP on its own as the app leaves, which
    /// skips `ensureRunning()`.
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        // Read synchronously when on the main thread, so the line shows the
        // type PiP is about to appear with.
        let log = { @MainActor in
            guard self.controller === controller else { return }
            self.logContentType(L("即将开启", "about to start"))
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated { log() }
        } else {
            Task { @MainActor in log() }
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.isActive = true
            self.logContentType(L("已开启", "started"))
            self.watchContentType()
            self.settledStateTask?.cancel()
            // Starting PiP updates AVKit's routing/playback state. Reapply once
            // after that transition, as in the successful device experiment.
            self.settledStateTask = Task { [weak owner = self, weak runningController = controller] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let owner, let runningController,
                      owner.controller === runningController, owner.isActive else { return }
                guard owner.useUnspecifiedContentType(runningController) else {
                    owner.onLog?(L("画中画隐藏状态设置失败", "Couldn't hide Picture in Picture"))
                    owner.tearDown()
                    return
                }
                owner.logContentType(L("开启 1 秒后补设", "reapplied 1 s after starting"))
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.settledStateTask?.cancel()
            self.settledStateTask = nil
            self.contentTypeWatch?.cancel()
            self.contentTypeWatch = nil
            self.isActive = false
            self.logContentType(L("已关闭", "stopped"))
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                               failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.isActive = false
            self.onLog?(L("画中画开启失败：\((error as NSError).domain) \((error as NSError).code)", "Picture in Picture failed: \((error as NSError).domain) \((error as NSError).code)"))
        }
    }
}

extension PiPKeeper: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {}
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange { .invalid }
    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool { false }
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                               completion completionHandler: @escaping () -> Void) { completionHandler() }
}

private final class SampleBufferView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}
