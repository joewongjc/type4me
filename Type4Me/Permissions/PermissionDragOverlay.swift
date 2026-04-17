import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Panel Subclass

/// A non-activating floating panel that rides underneath the System Settings
/// window, carrying a draggable representation of Type4Me.app so the user
/// can drop it directly into the Accessibility list.
///
/// Shadow is painted entirely inside the SwiftUI content (via a soft shadow
/// on a rounded material shape). The native `hasShadow` is left off so we
/// don't get a hard rectangular shadow "skirt" fighting with the rounded
/// corners and bleeding onto the edges as visible fringing.
final class PermissionDragPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - SwiftUI Overlay View

/// The visual content of the drag overlay. The app icon is wrapped in a
/// SwiftUI `.onDrag` so any file-drop target (including the System Settings
/// Accessibility list) receives a `public.file-url` pointing at the live
/// `Type4Me.app` bundle. macOS's TCC registration treats a dropped app
/// bundle the same as adding it via the "+" button, which is why this
/// shortcut works.
private struct PermissionDragOverlayView: View {

    let appName: String
    let permissionName: String
    let iconImage: NSImage

    /// Outer padding reserved for the drop shadow. Must be matched by the
    /// controller when sizing the host panel so the shadow isn't clipped.
    static let shadowInset: CGFloat = 28

    var body: some View {
        ZStack {
            // Match Settings window cream background; soft shadow clipped to
            // the shape so nothing spills past the rounded corners.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsBg)
                .shadow(color: .black.opacity(0.18), radius: 22, x: 0, y: 10)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(TF.settingsCardAlt, lineWidth: 1)
                )

            VStack(alignment: .leading, spacing: 10) {
                // Top row: upward arrow + instruction text. Pure visual —
                // not the drag handle; the inner card below is.
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(TF.settingsAccentAmber)

                    instructionText
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Bottom row: the draggable app chip. This is the real drag
                // target — attaching `.onDrag` to this card mirrors Codex's
                // design and gives the user an explicit "grab me" surface.
                dragChip
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .padding(Self.shadowInset)
        .preferredColorScheme(.light)
    }

    /// Builds "拖 Type4Me 到上方列表以允许辅助功能" with the app and permission
    /// names emphasized, matching the Codex Computer Use visual pattern.
    private var instructionText: Text {
        Text(L("拖 ", "Drag "))
        + Text(appName).fontWeight(.semibold)
        + Text(L(" 到上方列表以允许", " to the list above to allow "))
        + Text(permissionName).fontWeight(.semibold)
    }

    private var dragChip: some View {
        HStack(spacing: 10) {
            Image(nsImage: iconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 32, height: 32)

            Text(appName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(TF.settingsCardAlt)
        )
        // Attaching `onDrag` here makes the whole chip a drag source — the
        // explicit "grab-me" surface Codex relies on. The pasteboard writes
        // the live `Type4Me.app` bundle URL so the target (System Settings
        // Accessibility list) gets a real file-URL drop, which TCC treats
        // the same as the "+" button's file-picker result.
        .onDrag {
            let provider = NSItemProvider()
            let url = Bundle.main.bundleURL as NSURL
            provider.registerObject(url, visibility: .all)
            return provider
        } preview: {
            HStack(spacing: 8) {
                Image(nsImage: iconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                Text(appName)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(TF.settingsBg)
            )
        }
    }
}

// MARK: - Controller

@MainActor
final class PermissionDragOverlayController {

    private var panel: PermissionDragPanel?
    private var followTimer: Timer?
    private var permissionPollTimer: Timer?
    private var onGranted: (() -> Void)?

    /// Show the overlay pinned to the System Settings window.
    ///
    /// - Parameters:
    ///   - appName: Name shown in the instruction and on the drag chip.
    ///   - permissionName: Name of the permission being requested, used to
    ///     complete the "Drag X to list above to allow Y" sentence.
    ///   - onGranted: Called once `AXIsProcessTrusted()` flips to true.
    func show(appName: String, permissionName: String, onGranted: @escaping () -> Void) {
        dismiss()
        self.onGranted = onGranted

        // Outer panel size includes transparent margin reserved for the drop
        // shadow; the opaque card is `contentSize` inside that margin.
        let contentSize = NSSize(width: 340, height: 120)
        let inset = PermissionDragOverlayView.shadowInset
        let panelSize = NSSize(
            width: contentSize.width + inset * 2,
            height: contentSize.height + inset * 2
        )
        let iconImage = NSApp.applicationIconImage ?? NSImage()

        let rootView = PermissionDragOverlayView(
            appName: appName,
            permissionName: permissionName,
            iconImage: iconImage
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.frame = NSRect(origin: .zero, size: panelSize)
        hosting.autoresizingMask = [.width, .height]

        let panel = PermissionDragPanel(
            contentRect: NSRect(origin: .zero, size: panelSize)
        )
        panel.contentView = hosting
        self.panel = panel

        reposition()
        panel.orderFrontRegardless()

        // Follow System Settings window motion at ~60fps so the overlay
        // stays glued to its target during user drag/resize. One
        // `CGWindowListCopyWindowInfo` call per tick is ~tens of μs — well
        // within the frame budget.
        //
        // Critical: register the timer in `.common` mode rather than the
        // default `.scheduledTimer` (which uses `.default`). When the user
        // is actively dragging the System Settings window, macOS puts the
        // main runloop into `.eventTracking` mode, and a default-mode timer
        // would pause exactly when we need it most. `.common` fires in both.
        let followInterval: TimeInterval = 1.0 / 60.0
        let follow = Timer(timeInterval: followInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reposition()
            }
        }
        RunLoop.main.add(follow, forMode: .common)
        followTimer = follow

        // Poll for authorization state so we can auto-dismiss and advance.
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.checkGranted()
            }
        }
    }

    func dismiss() {
        followTimer?.invalidate()
        followTimer = nil
        permissionPollTimer?.invalidate()
        permissionPollTimer = nil
        panel?.orderOut(nil)
        panel = nil
        onGranted = nil
    }

    private func checkGranted() {
        guard PermissionManager.hasAccessibilityPermission else { return }
        let callback = onGranted
        dismiss()
        callback?()
    }

    /// Place the overlay centered horizontally under the System Settings
    /// window with a small gap. Falls back to the bottom center of the active
    /// screen if System Settings can't be located (e.g. not yet visible).
    ///
    /// The panel is oversized by `shadowInset` on all sides (for the shadow).
    /// We offset by that inset so the visible card — not the transparent
    /// margin — is what snaps to the target window edge.
    private func reposition() {
        guard let panel else { return }
        let panelSize = panel.frame.size
        let inset = PermissionDragOverlayView.shadowInset
        let gap: CGFloat = 8

        if let target = SystemSettingsWindowLocator.findMainWindowFrame() {
            var x = target.minX + (target.width - panelSize.width) / 2
            // Pull the panel up by the shadow inset so the card's top edge
            // (not the invisible margin) lands `gap` points below System
            // Settings' bottom edge.
            var y = target.minY - panelSize.height - gap + inset

            // Clamp to the screen containing the System Settings window so
            // the card stays within the visible area. We clamp against the
            // panel frame (outer), accepting that the transparent shadow
            // margin may wrap onto screen edges.
            let screen = NSScreen.screens.first(where: { $0.frame.intersects(target) })
                ?? NSScreen.main
            if let visible = screen?.visibleFrame {
                x = max(visible.minX - inset, min(x, visible.maxX - panelSize.width + inset))
                y = max(visible.minY - inset, y)
            }

            panel.setFrameOrigin(NSPoint(x: x, y: y))
            return
        }

        let screen = NSScreen.main ?? NSScreen.screens.first
        if let visible = screen?.visibleFrame {
            let x = visible.midX - panelSize.width / 2
            let y = visible.minY + 60
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
