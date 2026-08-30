import SwiftUI
import AppKit

/// Pure helper to calculate follow-tail horizontal offset for compact transcript.
///
/// When text width is within viewport, offset is 0 (leading aligned).
/// When text width exceeds viewport, offset is negative so the tail aligns with the right edge.
func compactTranscriptOffset(textWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
    -max(0, textWidth - viewportWidth)
}

/// Single-line live transcript row embedded in the expanded compact recording capsule.
///
/// Displays 12pt medium text in a 24pt lane (180pt total width, 164pt viewport width).
/// Follows the tail when text overflows, applying a subtle leading fade mask.
struct CompactLiveTranscriptRow: View {

    let text: String
    var theme: RecordingTheme = .dark

    private static let measurementFont = NSFont.systemFont(
        ofSize: TF.compactTranscriptFontSize,
        weight: .medium
    )

    private var textWidth: CGFloat {
        guard !text.isEmpty else { return 0 }
        return ceil((text as NSString).size(withAttributes: [.font: Self.measurementFont]).width)
    }

    private var viewportWidth: CGFloat {
        TF.compactIndicatorWidth - TF.compactTranscriptHorizontalInset * 2
    }

    private var offset: CGFloat {
        compactTranscriptOffset(textWidth: textWidth, viewportWidth: viewportWidth)
    }

    private var isOverflowing: Bool {
        textWidth > viewportWidth
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(text)
                .font(.system(size: TF.compactTranscriptFontSize, weight: .medium))
                .foregroundStyle(theme == .light ? TF.floatingTextLight : TF.floatingText)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .offset(x: offset)
                .frame(width: viewportWidth, alignment: .leading)
                .mask {
                    if isOverflowing {
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .white],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: TF.compactTranscriptLeadingFadeWidth)
                            Rectangle()
                        }
                    } else {
                        Rectangle()
                    }
                }
                .clipped()
        }
        .padding(.horizontal, TF.compactTranscriptHorizontalInset)
        .frame(width: TF.compactIndicatorWidth, height: TF.compactTranscriptLaneHeight)
        .accessibilityLabel(text)
        .accessibilityHidden(text.isEmpty)
    }
}
