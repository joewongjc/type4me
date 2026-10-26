//
//  LiquidGlassShaders.metal
//  Type4Me
//
//  Liquid Glass Orb and Text Shaders ported from LerSent001/orb.
//  Copyright (c) 2026 LerSent001 (MIT License)
//  Pinned commit: fbf6eb81ad85e1125ed62027769bcfefc01d3613
//

#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>

using namespace metal;

// MARK: - Color Palette Helper

struct PaletteColors {
    half3 c0;
    half3 c1;
    half3 c2;
    half3 c3;
    half3 highlight;
};

static PaletteColors getPalette(int styleID) {
    PaletteColors p;
    switch (styleID) {
    case 0: // Siri Ripple (cyan, magenta, purple, soft blue)
        p.c0 = half3(0.15, 0.85, 0.95); // Cyan
        p.c1 = half3(0.95, 0.25, 0.70); // Magenta
        p.c2 = half3(0.55, 0.20, 0.95); // Deep Purple
        p.c3 = half3(0.20, 0.45, 0.98); // Soft Blue
        p.highlight = half3(0.95, 0.92, 1.0);
        break;
    case 1: // Blue Crystal Drop (sapphire, ice blue, deep ocean)
        p.c0 = half3(0.05, 0.35, 0.90);
        p.c1 = half3(0.30, 0.75, 1.00);
        p.c2 = half3(0.02, 0.15, 0.55);
        p.c3 = half3(0.50, 0.90, 1.00);
        p.highlight = half3(0.85, 0.95, 1.0);
        break;
    case 2: // Chromatic Liquid Metal (cool silver, chromatic blue/orange)
        p.c0 = half3(0.70, 0.75, 0.85);
        p.c1 = half3(0.35, 0.55, 0.85);
        p.c2 = half3(0.85, 0.50, 0.25);
        p.c3 = half3(0.90, 0.92, 0.95);
        p.highlight = half3(1.0, 1.0, 1.0);
        break;
    case 3: // Frost Fluid (frosted icy white, pale cyan, mist blue)
        p.c0 = half3(0.80, 0.92, 0.98);
        p.c1 = half3(0.50, 0.78, 0.92);
        p.c2 = half3(0.70, 0.85, 0.95);
        p.c3 = half3(0.95, 0.98, 1.00);
        p.highlight = half3(1.0, 1.0, 1.0);
        break;
    case 4: // Iridescent Opal (pearly milky white with rainbow sheen)
        p.c0 = half3(0.92, 0.88, 0.95);
        p.c1 = half3(0.40, 0.85, 0.80);
        p.c2 = half3(0.95, 0.50, 0.75);
        p.c3 = half3(0.60, 0.40, 0.95);
        p.highlight = half3(1.0, 0.98, 0.95);
        break;
    case 5: // Voiceprint Membrane (dark violet, coral, magenta, purple)
        p.c0 = half3(0.95, 0.30, 0.45); // Coral
        p.c1 = half3(0.75, 0.15, 0.85); // Magenta
        p.c2 = half3(0.35, 0.08, 0.65); // Dark Violet
        p.c3 = half3(0.98, 0.55, 0.35); // Amber Coral
        p.highlight = half3(1.0, 0.85, 0.90);
        break;
    case 6: // Violet Flame Core (violet core, bright edge flame)
        p.c0 = half3(0.50, 0.05, 0.95);
        p.c1 = half3(0.95, 0.20, 0.55);
        p.c2 = half3(0.25, 0.02, 0.60);
        p.c3 = half3(0.98, 0.60, 0.20);
        p.highlight = half3(1.0, 0.80, 0.98);
        break;
    case 7: // Aurora Veil (emerald green, neon cyan, deep violet)
        p.c0 = half3(0.10, 0.95, 0.60); // Emerald
        p.c1 = half3(0.15, 0.70, 0.98); // Neon Cyan
        p.c2 = half3(0.45, 0.10, 0.85); // Violet
        p.c3 = half3(0.05, 0.40, 0.30); // Deep Forest
        p.highlight = half3(0.85, 1.0, 0.90);
        break;
    case 8: // Liquid Chrome (high reflection monochrome)
        p.c0 = half3(0.85, 0.87, 0.90);
        p.c1 = half3(0.40, 0.42, 0.46);
        p.c2 = half3(0.15, 0.16, 0.18);
        p.c3 = half3(0.95, 0.96, 0.98);
        p.highlight = half3(1.0, 1.0, 1.0);
        break;
    case 9: // Color Soundfield (white, electric blue, lime, hot pink)
        p.c0 = half3(0.10, 0.80, 1.00); // Electric Blue
        p.c1 = half3(0.98, 0.20, 0.75); // Hot Pink
        p.c2 = half3(0.40, 0.95, 0.25); // Lime
        p.c3 = half3(0.98, 0.75, 0.10); // Amber
        p.highlight = half3(1.0, 1.0, 1.0);
        break;
    case 10: // Static (crisp red glass)
    default:
        p.c0 = half3(0.95, 0.18, 0.22); // Crimson
        p.c1 = half3(0.80, 0.08, 0.12); // Deep Red
        p.c2 = half3(0.60, 0.05, 0.08); // Dark Ruby
        p.c3 = half3(0.98, 0.35, 0.30); // Bright Coral
        p.highlight = half3(1.0, 0.85, 0.85);
        break;
    }
    return p;
}

// MARK: - Fluid Noise & Domain Warping

static float fluidField(float2 p, float t, float energy) {
    float2 p1 = p + float2(sin(p.y * 3.1 + t * 1.2), cos(p.x * 2.8 - t * 0.9)) * (0.35 + energy * 0.25);
    float2 p2 = p1 + float2(cos(p1.y * 4.2 - t * 1.5), sin(p1.x * 4.5 + t * 1.1)) * (0.25 + energy * 0.20);
    float v1 = sin(p2.x * 3.5 + t * 1.7) * cos(p2.y * 3.2 - t * 1.3);
    float v2 = sin(p2.y * 5.0 + t * 2.1) * cos(p2.x * 4.8 + t * 0.8);
    return (v1 + v2 * 0.5) * 0.5 + 0.5;
}

// MARK: - Liquid Glass Orb Fill Shader

[[ stitchable ]]
half4 liquidGlassFill(
    float2 position,
    float4 bounds,
    float time,
    float audioEnergy,
    float styleID,
    float motionEnabled
) {
    float2 size = max(bounds.zw, float2(1.0, 1.0));
    float2 uv = (position - bounds.xy) / size;
    float2 p = (uv - 0.5) * 2.0;
    float r2 = dot(p, p);

    // Outside unit circle
    if (r2 > 1.0) {
        return half4(0.0);
    }

    int sid = int(styleID + 0.5);
    PaletteColors pal = getPalette(sid);

    bool isStatic = (sid == 10) || (motionEnabled < 0.5);
    float t = isStatic ? 0.0 : (time * 1.6);
    float energy = isStatic ? 0.0 : clamp(audioEnergy, 0.0, 1.0);

    // 3D Sphere Normal
    float z = sqrt(max(0.0, 1.0 - r2));
    float3 N = float3(p.x, p.y, z);

    // Glass Refraction & Fresnel
    float fresnel = pow(1.0 - z, 2.2);
    float rim = smoothstep(0.7, 0.98, sqrt(r2));

    // Sample fluid texture through refracted sphere coords
    float2 fluidCoord = p * 1.2 + N.xy * 0.35;
    float n = isStatic ? (sin(p.x * 2.0) * cos(p.y * 2.0) * 0.25 + 0.5) : fluidField(fluidCoord, t, energy);

    // Multistage palette interpolation
    half3 baseColor;
    if (n < 0.33) {
        baseColor = mix(pal.c0, pal.c1, half(n / 0.33));
    } else if (n < 0.66) {
        baseColor = mix(pal.c1, pal.c2, half((n - 0.33) / 0.33));
    } else {
        baseColor = mix(pal.c2, pal.c3, half((n - 0.66) / 0.34));
    }

    // Specular Highlight (top-left primary light)
    float3 L1 = normalize(float3(-0.45, -0.65, 0.65));
    float3 V = float3(0.0, 0.0, 1.0);
    float3 H1 = normalize(L1 + V);
    float NdotH1 = max(0.0, dot(N, H1));
    float spec1 = pow(NdotH1, 28.0) * 1.1;

    // Secondary Rim Light (bottom-right subtle glow)
    float3 L2 = normalize(float3(0.5, 0.6, 0.4));
    float3 H2 = normalize(L2 + V);
    float spec2 = pow(max(0.0, dot(N, H2)), 16.0) * 0.35;

    // Glass Shell Composite
    half3 color = baseColor * half(0.75 + z * 0.35);
    color = mix(color, pal.highlight, half(fresnel * 0.55 + rim * 0.35));
    color += pal.highlight * half(spec1 + spec2);

    // Edge anti-aliasing
    float alpha = smoothstep(1.0, 0.94, sqrt(r2));

    return half4(color * half(alpha), half(alpha));
}

// MARK: - Liquid Glass Text Shader

[[ stitchable ]]
half4 liquidGlassText(
    float2 position,
    float4 bounds,
    float time,
    float audioEnergy,
    float styleID,
    float motionEnabled
) {
    float2 size = max(bounds.zw, float2(1.0, 1.0));
    float2 uv = (position - bounds.xy) / size;

    int sid = int(styleID + 0.5);
    PaletteColors pal = getPalette(sid);

    bool isStatic = (sid == 10) || (motionEnabled < 0.5);
    float t = isStatic ? 0.0 : (time * 1.3);
    float energy = isStatic ? 0.0 : clamp(audioEnergy, 0.0, 1.0);

    // Horizontal traveling wave field for text
    float2 p = uv * float2(size.x / 40.0, 1.0);
    float n = isStatic ? 0.5 : fluidField(p, t, energy);

    // Smooth color blend across text
    half3 textColor = mix(pal.c0, pal.c3, half(n));
    textColor = mix(textColor, pal.c1, half(sin(uv.x * 6.28 + t) * 0.5 + 0.5) * 0.4);

    // Ensure high contrast against dark floating bar background
    textColor = max(textColor, half3(0.75));

    // Specular sweep shimmer along text
    if (!isStatic) {
        float sweepPeriod = 3.0;
        float sweepProgress = fract((time * 0.5) / sweepPeriod);
        float distToSweep = abs(uv.x - sweepProgress * 1.4 + 0.2);
        float sweepGlow = smoothstep(0.18, 0.0, distToSweep);
        textColor = mix(textColor, pal.highlight, half(sweepGlow * 0.65));
    }

    return half4(textColor, 1.0);
}
