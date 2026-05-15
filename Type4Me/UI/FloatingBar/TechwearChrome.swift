import SwiftUI

// MARK: - Techwear Chrome
//
// Instrument-panel decoration for the Cold Industrial theme's floating bar.
// This is a *pure overlay*: it composes on top of the existing bar content
// without touching `barContent`, the width logic, the phase state machine,
// or any of the existing dot / transcript views. The Warm theme never
// renders it — the call site in `FloatingBarView.capsuleBar` is gated by
// `TF.showsTechwearChrome`.
//
// Three chrome elements drawn from an industrial instrument-panel design
// vocabulary: two corner registration marks, a housed status lamp, and a
// mono telemetry readout.

private enum ChromeMetrics {
    static let stroke: CGFloat = 1

    // Corner registration marks
    static let markInset: CGFloat = 3.5
    static let markArm: CGFloat = 6

    // Housed status lamp — framed around the existing dot at the bar's left
    static let lampCenterX: CGFloat = 26      // matches RecordingDot/ErrorDot center
    static let housingSize: CGFloat = 24
    static let housingArm: CGFloat = 5
    static let standaloneLampDiameter: CGFloat = 7

    // Mono readouts (telemetry + bracket label)
    /// `--f-mono` from the Cold Industrial design tokens. Bundled as
    /// CourierPrime-Regular.ttf, activated via the app's ATSApplicationFontsPath.
    static let monoFontName = "Courier Prime"
    static let labelSize: CGFloat = 8
    static let edgePad: CGFloat = 7
    static let edgeInset: CGFloat = 3

    /// The bar must be at least this wide before the telemetry readout is
    /// drawn — narrow phases (preparing, empty recording) physically cannot
    /// hold it, so they stay minimal.
    static let readoutMinWidth: CGFloat = 130
}

// MARK: - L-Shaped Mark

/// One corner of a registration frame — an "L" drawn in the given corner of
/// its bounds. Used for both the bar's corner marks and the lamp housing.
private struct LMark: Shape {
    enum Corner { case topLeading, topTrailing, bottomLeading, bottomTrailing }
    let corner: Corner

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch corner {
        case .topLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        case .topTrailing:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomLeading:
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        case .bottomTrailing:
            path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        }
        return path
    }
}

private extension LMark {
    func chromeStroke(arm: CGFloat) -> some View {
        stroke(TF.settingsTextTertiary, lineWidth: ChromeMetrics.stroke)
            .frame(width: arm, height: arm)
    }
}

// MARK: - Corner Registration Marks

/// Two L-marks on the top corners — a light registration accent, not a busy
/// four-corner frame.
private struct CornerRegistrationMarks: View {
    var body: some View {
        ZStack {
            LMark(corner: .topLeading).chromeStroke(arm: ChromeMetrics.markArm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            LMark(corner: .topTrailing).chromeStroke(arm: ChromeMetrics.markArm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .padding(ChromeMetrics.markInset)
    }
}

// MARK: - Status Lamp Housing

/// Two L-marks (top-leading + bottom-trailing) that frame the bar's status
/// indicator like a recessed lamp socket.
private struct HousingBrackets: View {
    var body: some View {
        ZStack {
            LMark(corner: .topLeading).chromeStroke(arm: ChromeMetrics.housingArm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            LMark(corner: .bottomTrailing).chromeStroke(arm: ChromeMetrics.housingArm)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }
}

// MARK: - Mono Telemetry Readout

/// Small monospace status code at the bar's bottom-right. Recording shows a
/// live elapsed timer; the other phases show a fixed instrument code.
private struct TechwearTelemetry<S: FloatingBarState>: View {
    let state: S

    var body: some View {
        Group {
            if state.barPhase == .recording {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    readout("REC " + elapsed(at: context.date))
                }
            } else {
                readout(staticCode)
            }
        }
    }

    private var staticCode: String {
        switch state.barPhase {
        case .preparing: return "INIT"
        case .processing: return "CAL"
        case .done: return "DONE"
        case .error: return "ERR"
        default: return ""
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.custom(ChromeMetrics.monoFontName, size: ChromeMetrics.labelSize))
            .tracking(1.2)
            .foregroundStyle(TF.settingsTextTertiary)
    }

    private func elapsed(at date: Date) -> String {
        guard let start = state.recordingStartDate else { return "00:00" }
        let total = max(0, Int(date.timeIntervalSince(start)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Techwear Chrome Overlay

/// The full instrument overlay for the floating bar. Corner marks and the
/// lamp housing render in every visible phase; the right-edge readouts only
/// appear once the bar is wide enough to hold them.
struct TechwearChromeOverlay<S: FloatingBarState>: View {
    let state: S

    /// Phases without their own indicator (processing/done) get a lamp dot
    /// drawn inside the housing; phases that already have a dot return nil.
    private var standaloneLampColor: Color? {
        switch state.barPhase {
        case .processing: return TF.recording
        case .done: return TF.success
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geo in
            let showReadouts = geo.size.width >= ChromeMetrics.readoutMinWidth
            ZStack {
                CornerRegistrationMarks()

                statusLamp
                    .frame(width: ChromeMetrics.housingSize, height: ChromeMetrics.housingSize)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, ChromeMetrics.lampCenterX - ChromeMetrics.housingSize / 2)

                if showReadouts {
                    TechwearTelemetry(state: state)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, ChromeMetrics.edgePad)
                        .padding(.bottom, ChromeMetrics.edgeInset)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showReadouts)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var statusLamp: some View {
        ZStack {
            HousingBrackets()
            if let color = standaloneLampColor {
                Circle()
                    .fill(color)
                    .frame(width: ChromeMetrics.standaloneLampDiameter,
                           height: ChromeMetrics.standaloneLampDiameter)
                    .shadow(color: color.opacity(0.6), radius: 3)
            }
        }
    }
}
