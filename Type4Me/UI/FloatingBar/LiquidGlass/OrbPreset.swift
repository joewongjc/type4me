//
//  OrbPreset.swift
//  Type4Me
//
//  Native presets directly ported from LerSent001/orb.
//  Copyright (c) 2026 LerSent001 (MIT License)
//  Pinned commit: fbf6eb81ad85e1125ed62027769bcfefc01d3613
//

import Foundation

public struct OrbPreset: Equatable {
    public let styleID: Int
    public let isAnimated: Bool
    /// How much the rendered image changes per unit of shader phase.
    ///
    /// Measured offscreen: each fluid is rendered at 120x120 at eight spread-out
    /// phases, each against the same fluid advanced by 0.05, and the mean
    /// absolute per-channel difference inside the orb is averaged and divided by
    /// the step. The numbers are stable to about +/-2% across runs.
    ///
    /// The fluids differ by more than 12x here — `frost` at 3.9 barely moves
    /// for the same phase advance that carries `siri` at 50.7 through a whole
    /// gesture. The preset `speed` field is not a usable substitute: it is a
    /// phase multiplier, and it is nearly uncorrelated with this (frost ships at
    /// speed 2.22, siri at 0.82). Without this, one flow-speed curve makes some
    /// presets frantic and leaves others looking like a still image.
    ///
    /// Re-measure if a preset's zoom/warp/ridge/sharp or its fluid changes.
    public let flowResponse: Float
    public let uniforms: [Float]

    private static func rgb(_ hex: String) -> (Float, Float, Float, Float) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") { clean.removeFirst() }
        let scanner = Scanner(string: clean)
        var num: UInt64 = 0
        scanner.scanHexInt64(&num)
        let r = Float((num >> 16) & 0xFF) / 255.0
        let g = Float((num >> 8) & 0xFF) / 255.0
        let b = Float(num & 0xFF) / 255.0
        return (r, g, b, 1.0)
    }

    private static func makeSeed(
        speed: Float = 1.0,
        radius: Float = 0.94,
        zoom: Float = 0.3,
        warp: Float = 3.0,
        ridgeAmt: Float = 0.5,
        sharp: Float = 2.2,
        shade: Float = 0.3,
        sheen: Float = 0.36,
        gloss: Float = 0.28,
        shellMidAlpha: Float = 0.2,
        shellEdgeAlpha: Float = 1.0,
        exposure: Float = 1.0,
        styleFlowIndex: Float = 9.0,
        edgeSoftness: Float = 0.15,
        edgeGlow: Float = 0.0,
        glassEnabled: Bool = true,
        glassOpacity: Float = 1.0,
        contourDeform: Float = 0.0,
        bandDensity: Float = 2.0,
        chromaticShift: Float = 0.42,
        metalScale: Float = 0.77,
        metalStretch: Float = 0.23,
        metalAngle: Float = 65.0,
        metalOffset: Float = 0.0,
        metalPhase: Float = 0.0,
        metalEvolution: Float = 1.0,
        metalRoughness: Float = 0.22,
        metalDepth: Float = 0.25,
        colorA: String = "#F7FBFF",
        colorB: String = "#D6E8F7",
        colorC: String = "#A8C8F0",
        colorD: String = "#6F9EE8",
        highlightColor: String = "#FFFFFF",
        shellInner: String = "#FFFFFF",
        shellMid: String = "#D6E8F7",
        shellEdge: String = "#6F9EE8",
        sheenColor: String = "#EAF4FF",
        specColor: String = "#DCEAFF",
        canvasColor: String = "#000000",
        glowColor: String = "#6F9EE8"
    ) -> [Float] {
        var u = [Float](repeating: 0, count: 128)
        u[3] = speed
        u[4] = radius
        u[5] = zoom
        u[6] = warp
        u[7] = ridgeAmt
        u[8] = sharp
        u[9] = shade
        u[10] = sheen
        u[11] = gloss
        u[12] = shellMidAlpha
        u[13] = shellEdgeAlpha
        u[14] = exposure
        u[15] = styleFlowIndex
        u[16] = edgeSoftness
        u[17] = edgeGlow
        u[18] = 0.0 // paletteCount
        u[19] = glassEnabled ? 1.0 : 0.0
        u[20] = glassOpacity
        u[21] = contourDeform
        u[22] = bandDensity
        u[23] = chromaticShift
        u[24] = metalScale
        u[25] = metalStretch
        u[26] = metalAngle
        u[27] = metalOffset
        u[28] = metalPhase
        u[29] = metalEvolution
        u[30] = metalRoughness
        u[31] = metalDepth

        let colorHexes = [
            colorA, colorB, colorC, colorD,
            highlightColor, shellInner, shellMid, shellEdge,
            sheenColor, specColor, canvasColor, glowColor,
            "#F7FBFF", "#EFF6FD", "#E0EEF9", "#D4E6F7",
            "#BBD5F3", "#A6C7F0", "#87B0EB", "#6F9EE8",
            "#6F9EE8", "#6F9EE8", "#6F9EE8", "#6F9EE8"
        ]

        for (i, hex) in colorHexes.enumerated() {
            let (r, g, b, a) = rgb(hex)
            let base = 32 + i * 4
            u[base] = r
            u[base + 1] = g
            u[base + 2] = b
            u[base + 3] = a
        }
        return u
    }

    public static let siri = OrbPreset(
        styleID: 0,
        isAnimated: true,
        flowResponse: 50.72,
        uniforms: makeSeed(
            speed: 0.82,
            radius: 0.94,
            zoom: 0.36,
            warp: 3.2,
            ridgeAmt: 0.5,
            sharp: 2.2,
            shade: 0.12,
            sheen: 0.28,
            gloss: 0.24,
            shellMidAlpha: 0.18,
            shellEdgeAlpha: 1.0,
            exposure: 2.0,
            styleFlowIndex: 9.0,
            glassOpacity: 1.0,
            colorA: "#FFD86B",
            colorB: "#82F4FF",
            colorC: "#FF7BD5",
            colorD: "#8E6CFF",
            shellMid: "#9BF4FF",
            shellEdge: "#C5A9FF",
            canvasColor: "#030409",
            glowColor: "#956CFF"
        )
    )

    public static let blueDrop = OrbPreset(
        styleID: 1,
        isAnimated: true,
        flowResponse: 4.93,
        uniforms: makeSeed(
            speed: 0.9,
            radius: 0.94,
            zoom: 0.48,
            warp: 2.65,
            ridgeAmt: 0.42,
            sharp: 2.4,
            shade: 0.16,
            sheen: 0.22,
            gloss: 0.42,
            shellMidAlpha: 0.32,
            shellEdgeAlpha: 1.0,
            exposure: 1.24,
            styleFlowIndex: 20.0,
            glassOpacity: 1.0,
            contourDeform: 0.08,
            colorA: "#020B1D",
            colorB: "#0756B8",
            colorC: "#1EC8FF",
            colorD: "#DDFBFF",
            highlightColor: "#EAFBFF",
            shellInner: "#F6FDFF",
            shellMid: "#4FD7FF",
            shellEdge: "#466DFF",
            sheenColor: "#DDFBFF",
            specColor: "#A8D9FF",
            canvasColor: "#010207",
            glowColor: "#168DFF"
        )
    )

    public static let chromaticMetal = OrbPreset(
        styleID: 2,
        isAnimated: true,
        flowResponse: 27.67,
        uniforms: makeSeed(
            speed: 1.12,
            radius: 0.94,
            shade: 0.1,
            sheen: 0.14,
            gloss: 0.46,
            shellMidAlpha: 0.2,
            shellEdgeAlpha: 1.0,
            exposure: 1.08,
            styleFlowIndex: 22.0,
            glassOpacity: 1.0,
            metalRoughness: 0.16,
            metalDepth: 0.38,
            colorA: "#FBFCFB",
            colorB: "#7F8683",
            colorC: "#D6DAD8",
            colorD: "#33373A",
            highlightColor: "#FFFFFF",
            shellInner: "#F7FCFF",
            shellMid: "#6EDCFF",
            shellEdge: "#FF806D",
            sheenColor: "#F7FCFF",
            specColor: "#D9F3FF",
            canvasColor: "#050606",
            glowColor: "#BDEFFF"
        )
    )

    public static let frost = OrbPreset(
        styleID: 3,
        isAnimated: true,
        flowResponse: 3.93,
        uniforms: makeSeed(
            speed: 2.22,
            radius: 0.94,
            zoom: 0.36,
            warp: 3.7,
            ridgeAmt: 0.45,
            sharp: 2.05,
            shade: 0.3,
            sheen: 0.34,
            gloss: 0.28,
            shellMidAlpha: 0.2,
            shellEdgeAlpha: 1.0,
            exposure: 1.0,
            styleFlowIndex: 15.0,
            glassOpacity: 1.0,
            contourDeform: 0.04,
            colorA: "#F7FBFF",
            colorB: "#D6E8F7",
            colorC: "#A8C8F0",
            colorD: "#6F9EE8",
            shellMid: "#D6E8F7",
            shellEdge: "#6F9EE8",
            canvasColor: "#000000",
            glowColor: "#6F9EE8"
        )
    )

    public static let opal = OrbPreset(
        styleID: 4,
        isAnimated: true,
        flowResponse: 21.59,
        uniforms: makeSeed(
            speed: 1.5,
            radius: 0.94,
            zoom: 0.3,
            warp: 2.8,
            ridgeAmt: 0.36,
            sharp: 2.0,
            shade: 0.1,
            sheen: 0.3,
            gloss: 0.26,
            shellMidAlpha: 0.2,
            shellEdgeAlpha: 1.0,
            exposure: 1.12,
            styleFlowIndex: 13.0,
            glassOpacity: 1.0,
            colorA: "#FFF6E8",
            colorB: "#6EF2CF",
            colorC: "#FF91D8",
            colorD: "#756BFF",
            shellMid: "#CDE5FF",
            shellEdge: "#D9C8FF",
            canvasColor: "#07080D",
            glowColor: "#9E8CFF"
        )
    )

    public static let voiceWave = OrbPreset(
        styleID: 5,
        isAnimated: true,
        flowResponse: 21.85,
        uniforms: makeSeed(
            speed: 0.95,
            radius: 0.94,
            zoom: 0.36,
            warp: 2.6,
            ridgeAmt: 0.46,
            shade: 0.08,
            sheen: 0.22,
            gloss: 0.36,
            shellMidAlpha: 0.18,
            shellEdgeAlpha: 1.0,
            exposure: 1.35,
            styleFlowIndex: 19.0,
            glassOpacity: 1.0,
            contourDeform: 0.1,
            colorA: "#09030E",
            colorB: "#CE2CCB",
            colorC: "#FF5C71",
            colorD: "#7B53FF",
            highlightColor: "#FFD9F0",
            shellMid: "#E48BFF",
            shellEdge: "#FF7890",
            sheenColor: "#FFF1FA",
            specColor: "#E7D9FF",
            canvasColor: "#020105",
            glowColor: "#CE2CCB"
        )
    )

    public static let violetEmber = OrbPreset(
        styleID: 6,
        isAnimated: true,
        flowResponse: 30.83,
        uniforms: makeSeed(
            speed: 1.12,
            radius: 0.94,
            // Trimmed from zoom 0.58 / warp 4.7 / ridge 0.73 / sharp 3.3. At
            // 45pt those pushed the detail below one pixel and the ember read
            // as static rather than as flowing plasma.
            zoom: 0.44,
            warp: 3.6,
            ridgeAmt: 0.56,
            sharp: 2.5,
            shade: 0.18,
            sheen: 0.2,
            gloss: 0.34,
            shellMidAlpha: 0.28,
            shellEdgeAlpha: 1.0,
            exposure: 1.28,
            styleFlowIndex: 21.0,
            glassOpacity: 1.0,
            contourDeform: 0.04,
            colorA: "#100016",
            colorB: "#4A0E8F",
            colorC: "#A52EFF",
            colorD: "#F1A7FF",
            highlightColor: "#FFD6FF",
            shellInner: "#FCF5FF",
            shellMid: "#C257FF",
            shellEdge: "#6C2DFF",
            sheenColor: "#F8E6FF",
            specColor: "#D4B7FF",
            canvasColor: "#030006",
            glowColor: "#A52EFF"
        )
    )

    public static let aurora = OrbPreset(
        styleID: 7,
        isAnimated: true,
        flowResponse: 8.83,
        uniforms: makeSeed(
            speed: 3.0,
            radius: 0.94,
            zoom: 0.4,
            warp: 4.2,
            ridgeAmt: 0.62,
            sharp: 2.1,
            shade: 0.18,
            shellEdgeAlpha: 1.0,
            exposure: 1.18,
            styleFlowIndex: 10.0,
            glassOpacity: 1.0,
            contourDeform: 0.08,
            colorA: "#030816",
            colorB: "#20F0B6",
            colorC: "#32A8FF",
            colorD: "#A34BFF",
            shellMid: "#32A8FF",
            shellEdge: "#20F0B6",
            canvasColor: "#010207",
            glowColor: "#20F0B6"
        )
    )

    public static let chrome = OrbPreset(
        styleID: 8,
        isAnimated: true,
        flowResponse: 38.64,
        uniforms: makeSeed(
            speed: 2.0,
            radius: 0.94,
            zoom: 0.36,
            warp: 3.8,
            ridgeAmt: 0.44,
            // Softened from sharp 5.2 / shade 0.58: the hard black-and-white
            // break was the harshest edge in the set at this size.
            sharp: 3.6,
            shade: 0.44,
            shellEdgeAlpha: 1.0,
            exposure: 1.08,
            styleFlowIndex: 12.0,
            glassOpacity: 1.0,
            colorA: "#FFFFFF",
            colorB: "#B9C0CA",
            colorC: "#343A43",
            colorD: "#030405",
            shellMid: "#B9C0CA",
            shellEdge: "#FFFFFF",
            canvasColor: "#050608",
            glowColor: "#FFFFFF"
        )
    )

    public static let spectrum = OrbPreset(
        styleID: 9,
        isAnimated: true,
        flowResponse: 60.16,
        uniforms: makeSeed(
            speed: 1.8,
            radius: 0.94,
            zoom: 0.46,
            warp: 4.4,
            ridgeAmt: 0.72,
            shade: 0.06,
            sheen: 0.26,
            gloss: 0.24,
            shellEdgeAlpha: 1.0,
            // Deliberately left on makeSeed's default flow index of 9.0, the
            // Siri band shader. It looks like an oversight next to the unused
            // spectrum fluid at index 14, but index 14 renders a far plainer
            // band and this preset's whole appeal is the spectral palette
            // running through the Siri wave. Do not "fix" this.
            glassOpacity: 1.0,
            contourDeform: 0.03,
            colorA: "#FFFFFF",
            colorB: "#1677FF",
            colorC: "#F249A0",
            colorD: "#35E6B2",
            shellMid: "#66E8FF",
            shellEdge: "#D26CFF",
            canvasColor: "#03040A",
            glowColor: "#1677FF"
        )
    )

    public static let staticSiri = OrbPreset(
        styleID: 10,
        isAnimated: false,
        flowResponse: 50.72,
        uniforms: makeSeed(
            speed: 0.0,
            radius: 0.94,
            zoom: 0.36,
            warp: 3.2,
            ridgeAmt: 0.5,
            sharp: 2.2,
            shade: 0.12,
            sheen: 0.28,
            gloss: 0.24,
            shellMidAlpha: 0.18,
            shellEdgeAlpha: 1.0,
            exposure: 2.0,
            styleFlowIndex: 9.0,
            glassOpacity: 1.0,
            colorA: "#FFD86B",
            colorB: "#82F4FF",
            colorC: "#FF7BD5",
            colorD: "#8E6CFF",
            shellMid: "#9BF4FF",
            shellEdge: "#C5A9FF",
            canvasColor: "#030409",
            glowColor: "#956CFF"
        )
    )

    public static let staticGlass = staticSiri
}

extension RecordingVisualStyle {
    public var preset: OrbPreset {
        switch self {
        case .siri: return .siri
        case .blueDrop: return .blueDrop
        case .chromaticMetal: return .chromaticMetal
        case .frost: return .frost
        case .opal: return .opal
        case .voiceWave: return .voiceWave
        case .violetEmber: return .violetEmber
        case .aurora: return .aurora
        case .chrome: return .chrome
        case .spectrum: return .spectrum
        case .staticSiri: return .staticSiri
        }
    }
}
