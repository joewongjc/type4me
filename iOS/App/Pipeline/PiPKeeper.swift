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
    }

    func tearDown() {
        settledStateTask?.cancel()
        settledStateTask = nil
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
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.isActive = true
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
                owner.onLog?(L("画中画已开启，ContentType = invalid (-1)", "Picture in Picture on, ContentType = invalid (-1)"))
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in
            guard self.controller === controller else { return }
            self.settledStateTask?.cancel()
            self.settledStateTask = nil
            self.isActive = false
            self.onLog?(L("画中画已关闭", "Picture in Picture stopped"))
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
