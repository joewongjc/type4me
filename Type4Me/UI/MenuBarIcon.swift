import AppKit
import SwiftUI

/// Menu bar status icon drawn from the Type4Me "4!" mark (`Assets/type4me-mark-mono.svg`).
/// Idle is a template image tinted by the system; while recording the dot lights up red.
@MainActor
enum MenuBarIcon {

    /// Status item image size in points; the mark is cropped horizontally to its ink.
    private static let size = NSSize(width: 12, height: 18)
    /// Side of the square SVG canvas, and the dot's geometry inside it.
    private static let canvas: CGFloat = 256
    private static let dotCenter = CGPoint(x: 128.9, y: 221.1)
    private static let dotRadius: CGFloat = 25

    private static let recordingRed = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.29, blue: 0.12, alpha: 1)   // #FF4A1F
            : NSColor(srgbRed: 0.91, green: 0.22, blue: 0.05, alpha: 1)  // #E8380D
    }

    private static let mark: NSImage? = Bundle.main
        .url(forResource: "type4me-mark-mono", withExtension: "svg", subdirectory: "Assets")
        .flatMap(NSImage.init(contentsOf:))

    private static let idleImage: NSImage? = mark.map { mark in
        let image = NSImage(size: size, flipped: true) { rect in
            drawMark(mark, in: rect)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Not a template, so the dot keeps its color; the glyph is tinted black or white at
    /// draw time from the menu bar's own appearance, matching neighbouring template icons.
    private static let recordingImage: NSImage? = mark.map { mark in
        NSImage(size: size, flipped: true) { rect in
            drawMark(mark, in: rect)
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (isDark ? NSColor.white : NSColor.black).set()
            rect.fill(using: .sourceAtop)

            let scale = rect.height / canvas
            let originX = (rect.width - canvas * scale) / 2
            let radius = (dotRadius + 2) * scale
            let center = CGPoint(x: originX + dotCenter.x * scale, y: dotCenter.y * scale)
            recordingRed.setFill()
            NSBezierPath(ovalIn: NSRect(
                x: center.x - radius, y: center.y - radius,
                width: radius * 2, height: radius * 2
            )).fill()
            return true
        }
    }

    /// Draws the square mark at full height, centered and clipped to the narrower image.
    private static func drawMark(_ mark: NSImage, in rect: NSRect) {
        let side = rect.height
        mark.draw(
            in: NSRect(x: (rect.width - side) / 2, y: 0, width: side, height: side),
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
    }

    @ViewBuilder
    static func label(isRecording: Bool) -> some View {
        if let image = isRecording ? recordingImage : idleImage {
            Image(nsImage: image)
                .accessibilityLabel("Type4Me")
        } else {
            // Unbundled builds (plain `swift build`) have no Assets directory.
            Image(systemName: isRecording ? "mic.fill" : "mic")
                .accessibilityLabel("Type4Me")
        }
    }
}
