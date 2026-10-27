#!/usr/bin/env python3
"""Generate the README hero images in the current Type4Me app style.

Writes four files into docs/images/ (or the directory given as argv[1]):
    header.svg, header-dark.svg        Chinese, light / dark
    header-en.svg, header-en-dark.svg  English, light / dark

Visual language mirrors the app:
- neutral canvas with a faint dot grid (main window background)
- bold system headline from HomeDashboardView ("说出想法，即刻成文" / "Say it. Shape it.")
- "我的模式" card with green-tinted hotkey chips (home page)
- handwritten wordmark from the app bundle (sidebar)
- the recording bar as FloatingBarView draws it: Liquid Glass over the dot grid
  (light recording theme on the light header, dark on the dark one), Siri orb on
  the left, glass cancel button on the right; the bar is centred and grows out
  from the middle on its 0.3s spring as glyphs stream in
  (SMIL loop sampled at 30 Hz; a still copy is shown under prefers-reduced-motion)
- blue accent from the home heatmap / usage overview

Re-run after changing copy:  python3 scripts/readme/gen_header.py
"""
import math
import re
import sys
from pathlib import Path
from xml.sax.saxutils import escape

W, H = 1200, 600

FONT = ("-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'PingFang SC', "
        "'Hiragino Sans GB', 'Microsoft YaHei', 'Segoe UI', 'Helvetica Neue', Arial, sans-serif")

COPY = {
    "zh": {
        "lang": "zh-CN",
        "title": "Type4Me — macOS 语音输入法",
        "badges": ["macOS 14+", "MIT 开源"],
        "headline": "说出想法，即刻成文",
        "headline_size": 60,
        "sub": ["macOS 语音输入法：边说边出字，", "一个快捷键完成润色、翻译、提问与 Mac 操作。"],
        "pills": ["流式识别", "本地 / 云端引擎", "8 种模式", "词汇 Skill", "用量看板"],
        # Text is streamed in glyph by glyph. Offsets and widths are in app points,
        # measured with NSFont.systemFont(ofSize: 14, weight: .medium) like
        # FloatingBarView (CTLine offsets; width as NSString.size of the prefix).
        "listening": ("倾听中", 41.7),
        "transcript": "实时流式语音识别，自定义语音工作流。",
        "glyph_x": [0.0, 13.9, 27.8, 41.7, 55.6, 69.5, 83.3, 97.2, 111.1, 125.2, 139.1, 153.0,
                    166.9, 180.8, 194.7, 208.6, 222.4, 236.3],
        "prefix_w": [13.9, 27.8, 41.7, 55.6, 69.5, 83.3, 97.2, 111.1, 118.2, 139.1, 153.0, 166.9,
                     180.8, 194.7, 208.6, 222.4, 236.3, 243.4],
        "glyph_step": 0.12,
        "card_title": "我的模式",
        "card_sub": "在任何地方用快捷键开始口述",
        "modes": [
            ("快速模式", "直接转写，最快出字", "fn"),
            ("智能感知", "按场景整理表达", "⌥ 1"),
            ("翻译模式", "说中文，出英文", "⌥ 2"),
            ("随便问", "选中内容直接提问", "⌥ 3"),
            ("Mac 操作", "一句话控制电脑", "⌥ 4"),
        ],
        "active": 1,
        "recording": "录音中",
        "footer_r": "免费 · 开源 · 数据留在本机",
    },
    "en": {
        "lang": "en",
        "title": "Type4Me — Voice Input for macOS",
        "badges": ["macOS 14+", "MIT License"],
        "headline": "Say it. Shape it.",
        "headline_size": 64,
        "sub": ["Voice input for macOS. Text streams in as you speak —", "polish, translate, ask or act with one hotkey."],
        "pills": ["Streaming ASR", "Local / Cloud", "8 Modes", "Vocab Skill", "Usage Stats"],
        "listening": ("Listening", 60.5),
        "transcript": "Streaming ASR, custom voice workflows.",
        "glyph_x": [0.0, 9.0, 14.2, 19.5, 27.4, 35.2, 47.5, 51.1, 59.3, 67.9, 71.5, 81.1, 90.1,
                    99.3, 103.5, 107.2, 115.0, 123.3, 130.7, 135.8, 144.0, 156.4, 160.0, 167.5,
                    175.6, 179.2, 187.0, 195.0, 198.7, 209.6, 217.7, 223.2, 230.9, 236.0, 239.6,
                    247.7, 258.6, 265.9],
        "prefix_w": [9.0, 14.2, 19.6, 27.4, 35.2, 47.5, 51.1, 59.3, 67.9, 71.5, 81.1, 90.1, 99.3,
                     103.5, 107.2, 115.0, 123.3, 130.7, 135.8, 144.0, 156.4, 160.0, 167.7, 175.6,
                     179.2, 187.0, 195.0, 198.7, 209.7, 217.7, 223.2, 230.9, 236.0, 239.6, 247.9,
                     258.7, 265.9, 270.1],
        "glyph_step": 0.06,
        "card_title": "My Modes",
        "card_sub": "Start dictating anywhere with a hotkey",
        "modes": [
            ("Quick Mode", "Raw transcript, fastest", "fn"),
            ("Intelli Sense", "Context-aware polish", "⌥ 1"),
            ("Translate", "Speak one, type another", "⌥ 2"),
            ("Ask Anything", "Ask about the selection", "⌥ 3"),
            ("Mac Actions", "Control your Mac by voice", "⌥ 4"),
        ],
        "active": 1,
        "recording": "Recording",
        "footer_r": "Free · Open source · Your data stays local",
    },
}

THEMES = {
    "light": {
        "bg": "#FFFFFF", "edge": "#000000", "edge_op": 0.08, "dot": "#000000", "dot_op": 0.055,
        "text": "#131313", "text2": "#7A7A7A", "text3": "#9A9A9A",
        "pill": "#F1F1F1", "pill_text": "#333333", "badge_bg": "#FFFFFF", "badge_text": "#4D4D4D",
        "card": "#FFFFFF", "card_edge_op": 0.075, "rule_op": 0.07, "shadow_op": 0.08,
        "icon_btn": "#F1F1F1", "icon_line": "#555555",
        "chip": "#EAF4EA", "chip_edge": "#CBE3CE", "chip_text": "#1F3A24", "chip_icon": "#3E8E4A",
        "active_a": "#EEF3FF", "active_b": "#F6F8FF", "accent": "#3B6FF0", "accent_text": "#2F5FE0",
        "field_op": 0.16, "wordmark": "#131313",
        # recording bar in the app's light theme: clear glass, dark text
        "glass_tint": "#FFFFFF", "glass_tint_op": 0.84, "glass_dots": "#000000", "glass_dots_op": 0.04,
        "glass_body_top": 0.55, "lens": "#FFFFFF", "lens_op": 0.85, "shadow_near_op": 0.22,
        "shadow_far_op": 0.12, "rim": [("#FFFFFF", 0.95), ("#FFFFFF", 0.35), ("#000000", 0.05), ("#000000", 0.14)],
        "edge": 0.07, "cap_text": "#1C1C1E", "glint_op": (0.9, 0.0),
        "cancel": {"base": ("#FFFFFF", 0.35), "dome": [("#FFFFFF", 0.65), ("#FFFFFF", 0.30), ("#000000", 0.04)],
                   "rim": [("#FFFFFF", 0.85), ("#FFFFFF", 0.30), ("#000000", 0.10)], "gloss": 0.50,
                   "x": ("#1C1C1E", 0.78)},
    },
    "dark": {
        "bg": "#161618", "edge": "#FFFFFF", "edge_op": 0.10, "dot": "#FFFFFF", "dot_op": 0.06,
        "text": "#F4F4F5", "text2": "#A1A1A6", "text3": "#7C7C82",
        "pill": "#2A2A2D", "pill_text": "#E4E4E7", "badge_bg": "#1F1F22", "badge_text": "#C7C7CC",
        "card": "#1F1F22", "card_edge_op": 0.10, "rule_op": 0.09, "shadow_op": 0.35,
        "icon_btn": "#2C2C2F", "icon_line": "#BDBDC2",
        "chip": "#1C2E21", "chip_edge": "#2E4A35", "chip_text": "#CFEAD4", "chip_icon": "#6BC47A",
        "active_a": "#1B2440", "active_b": "#1D2333", "accent": "#5B8BFF", "accent_text": "#8FB0FF",
        "field_op": 0.14, "wordmark": "#F4F4F5",
        # recording bar in the app's dark theme (its default)
        "glass_tint": "#2C2C30", "glass_tint_op": 0.72, "glass_dots": "#FFFFFF", "glass_dots_op": 0.05,
        "glass_body_top": 0.10, "lens": "#FFFFFF", "lens_op": 0.12, "shadow_near_op": 0.55,
        "shadow_far_op": 0.40, "rim": [("#FFFFFF", 0.55), ("#FFFFFF", 0.10), ("#FFFFFF", 0.04), ("#FFFFFF", 0.30)],
        "edge": 0.0, "cap_text": "#FFFFFF", "glint_op": (0.55, 0.28),
        "cancel": {"base": ("#000000", 0.38), "dome": [("#FFFFFF", 0.12), ("#FFFFFF", 0.06), ("#FFFFFF", 0.02)],
                   "rim": [("#FFFFFF", 0.30), ("#FFFFFF", 0.14), ("#FFFFFF", 0.06)], "gloss": 0.22,
                   "x": ("#FFFFFF", 0.82)},
    },
}


def text_w(s, size):
    """Rough advance width: CJK ≈ 1em, latin ≈ 0.5–0.66em."""
    w = 0.0
    for ch in s:
        if ord(ch) > 0x2E80:
            w += size
        elif ch in " .,;:'|·":
            w += size * 0.3
        elif ch.isupper():
            w += size * 0.66
        else:
            w += size * 0.52
    return w


# Wordmark from the app bundle (Sources/Type4Me/Resources/Assets), so the header
# follows the logo when it changes. Letters take the theme ink; the dot stays red.
WORDMARK_SVG = Path(__file__).resolve().parents[2] / "Sources/Type4Me/Resources/Assets/type4me-wordmark-light.svg"
_wm = WORDMARK_SVG.read_text(encoding="utf-8")
WORDMARK_BOX = tuple(float(v) for v in re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', _wm).groups())
WORDMARK_LETTERS, WORDMARK_DOT = re.findall(r'<path d="([^"]+)"', _wm)[:2]
WORDMARK_RED = re.findall(r'<path d="[^"]+" fill="([^"]+)"', _wm)[1]
WORDMARK_H = 44

# Recording bar geometry in app points (TF.bar* / TF.recording* in DesignSystem.swift),
# drawn at SCALE so the 55pt bar is 72px tall.
SCALE = 72 / 55
BAR_MIN_W, BAR_MAX_W = 180, 400
CHROME_W = 45 + 35 + 5 + 10 + 8 * 2   # orb + cancel + leading/trailing inset + two gaps
CAP_H = 55 * SCALE
CAP_R = CAP_H / 2
CONTROL_INSET = 27.5 * SCALE          # orb and cancel centres sit 27.5pt in from each edge
CAP_CX, CAP_CY = 352, 454             # the panel is centred, so the bar grows out from here
TEXT_DX = 2.5 * SCALE                 # text is centred between the controls, not the bar

# One loop: appear, listen, stream glyphs in, hold, dismiss.
LOOP = 8.0
SHOW, LISTEN_END = 0.35, 1.5
HIDE_AT, HIDE = 6.9, 0.4
COMMA_PAUSE = 0.14
GLYPH_FADE = 0.16
SWEEP = (0.45, 1.0)                   # LiquidGlassText's 0.55s silver sheen
SPRING_RESPONSE = 0.3                 # TF.recordingCapsuleSpringResponse, dampingFraction 1
SAMPLE_HZ = 30                        # spring samples; the browser interpolates between them
LEAD = 0.16                           # bar and line start moving just before a glyph lands
TEXT_SIDE_INSETS = (5 + 45 + 8, 8 + 35 + 10)  # text area: past the orb, short of cancel
EASE = "0.2 0.8 0.25 1"
FLAT = "0 0 1 1"


def bar_w(text_pt):
    return min(BAR_MAX_W, max(BAR_MIN_W, text_pt + CHROME_W)) * SCALE


def glyph_times(c):
    times, t = [], LISTEN_END
    for ch in c["transcript"]:
        times.append(t)
        t += c["glyph_step"] + (COMMA_PAUSE if ch in "，,。." else 0)
    return times


def motion(c):
    """Sampled (time, bar width, text width) keyframes, in px.

    Each new glyph moves the targets; a critically damped spring follows them,
    as the capsule's .spring(response: 0.3, dampingFraction: 1) does. Like
    recordingPeakWidth the bar only grows.
    """
    times = glyph_times(c)
    widths = [w * SCALE for w in c["prefix_w"]]
    base = bar_w(c["listening"][1])

    def targets(t):
        n = sum(1 for g in times if g <= t)
        if n == 0:
            return base, widths[0]
        return max(bar_w(p) for p in c["prefix_w"][:n]), widths[n - 1]

    omega = 2 * 3.141592653589793 / SPRING_RESPONSE
    t0, t1 = LISTEN_END - LEAD, times[-1] + 0.8
    bw, bv, tw, tv = base, 0.0, widths[0], 0.0
    frames = [(0.0, base, widths[0])]
    dt, step, t, next_sample = 1 / 960, 1 / SAMPLE_HZ, t0, t0
    while t <= t1 + 1e-9:
        if t >= next_sample - 1e-9:
            frames.append((t, bw, tw))
            next_sample += step
        tb, tt = targets(t + LEAD)
        bv += (omega * omega * (tb - bw) - 2 * omega * bv) * dt
        bw += bv * dt
        tv += (omega * omega * (tt - tw) - 2 * omega * tv) * dt
        tw += tv * dt
        t += dt
    final_b, final_t = targets(t1)
    frames.append((t1 + step, final_b, final_t))
    gone = HIDE_AT + HIDE
    frames += [(gone, final_b, final_t), (gone + 0.05, base, widths[0]), (LOOP, base, widths[0])]
    return frames, final_b, final_t


def key_times(times):
    return ";".join(f"{x / LOOP:.4f}" for x in times)


def track(frames, fn, attr=None):
    """Linear SMIL track through the sampled frames; fn maps a frame to a value."""
    vals = [fn(f) for f in frames]
    common = (f'values="{";".join(vals)}" keyTimes="{key_times(f[0] for f in frames)}" '
              f'dur="{LOOP}s" repeatCount="indefinite"')
    if attr:
        return f'<animate attributeName="{attr}" {common}/>'
    return f'<animateTransform attributeName="transform" type="translate" {common}/>'


def fade(attr, values, times):
    return (f'<animate attributeName="{attr}" values="{";".join(values)}" keyTimes="{key_times(times)}" '
            f'dur="{LOOP}s" repeatCount="indefinite"/>')


def bar_rect(frames, w, inset=0.0, dy=0.0, extra=""):
    """The bar outline (or an inset copy), animated with the width when frames is set."""
    x, width = CAP_CX - w / 2 + inset, w - 2 * inset
    anim = ""
    if frames:
        anim = (track(frames, lambda f: f"{CAP_CX - f[1] / 2 + inset:.1f}", "x")
                + track(frames, lambda f: f"{f[1] - 2 * inset:.1f}", "width"))
    return (f'<rect x="{x:.1f}" y="{CAP_CY - CAP_R + dy:.1f}" width="{width:.1f}" height="{CAP_H:.1f}" '
            f'rx="{CAP_R:.1f}" {extra}>{anim}</rect>')


def stops(pairs, offsets):
    return "".join(f'<stop offset="{o}" stop-color="{c}" stop-opacity="{a}"/>' for (c, a), o in zip(pairs, offsets))


def glass_defs(t):
    user = f'filterUnits="userSpaceOnUse" x="0" y="0" width="{W}" height="{H}"'
    return f"""  <pattern id="fieldDots" width="16" height="16" patternUnits="userSpaceOnUse">
    <circle cx="2" cy="2" r="1.1" fill="{t['dot']}"/>
  </pattern>
  <pattern id="lensDots" width="16" height="16" patternUnits="userSpaceOnUse">
    <circle cx="2" cy="2" r="1.1" fill="{t['glass_dots']}"/>
  </pattern>
  <radialGradient id="fieldFade" cx="{CAP_CX}" cy="{CAP_CY}" r="330" gradientUnits="userSpaceOnUse"
                  gradientTransform="translate({CAP_CX} {CAP_CY}) scale(1 0.32) translate({-CAP_CX} {-CAP_CY})">
    <stop offset="0" stop-color="#fff"/><stop offset="0.55" stop-color="#fff" stop-opacity="0.6"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
  <mask id="fieldMask"><rect width="{W}" height="{H}" fill="url(#fieldFade)"/></mask>
  <rect id="field" x="0" y="{CAP_CY - 110}" width="720" height="220" fill="url(#fieldDots)" mask="url(#fieldMask)"/>
  <filter id="lensSoft" {user}><feGaussianBlur stdDeviation="0.6"/></filter>
  <filter id="nearShadow" {user}><feGaussianBlur stdDeviation="5"/></filter>
  <filter id="farShadow" {user}><feGaussianBlur stdDeviation="16"/></filter>
  <filter id="lensBlur" {user}><feGaussianBlur stdDeviation="5"/></filter>
  <filter id="shineBlur" {user}><feGaussianBlur stdDeviation="0.7"/></filter>
  <linearGradient id="glassBody" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="{t['glass_body_top']}"/>
    <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="{t['glass_body_top'] / 2}"/>
  </linearGradient>
  <linearGradient id="glassRim" x1="0" y1="0" x2="0" y2="1">{stops(t['rim'], (0, 0.4, 0.7, 1))}</linearGradient>
  <radialGradient id="cancelGlass" cx="35%" cy="30%" r="60%">{stops(t['cancel']['dome'], (0, 0.5, 1))}</radialGradient>
  <linearGradient id="cancelRim" x1="0" y1="0" x2="1" y2="1">{stops(t['cancel']['rim'], (0, 0.45, 1))}</linearGradient>
  <linearGradient id="cancelGloss" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="{t['cancel']['gloss']}"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
  </linearGradient>
"""


# Finish button orb in the default Siri preset.
ORB = ('<circle r="28" fill="url(#orbBase)"/>'
       '<g clip-path="url(#orbClip)">'
       '<g class="orb-spin" filter="url(#blur6)">'
       '<ellipse cx="-6" cy="2" rx="17" ry="7" fill="#168DFF" opacity="0.95"/>'
       '<ellipse cx="7" cy="-3" rx="14" ry="6" fill="#CE2CCB" opacity="0.85"/>'
       '</g>'
       '<g class="orb-spin2" filter="url(#blur3)">'
       '<ellipse cx="2" cy="4" rx="13" ry="4" fill="#956CFF" opacity="0.95"/>'
       '<ellipse cx="-3" cy="-1" rx="9" ry="2.6" fill="#EAF4FF" opacity="0.9"/>'
       '</g></g>'
       '<circle r="27.5" fill="none" stroke="url(#orbRim)" stroke-width="1.6"/>'
       '<ellipse cx="-8" cy="-15" rx="9" ry="4" fill="#fff" opacity="0.18"/>')

# LiquidGlassCancelButton at rest, in the bar's theme.
CANCEL_R = 35 * SCALE / 2


def cancel_button(t):
    c = t["cancel"]
    return (f'<circle r="{CANCEL_R:.1f}" fill="{c["base"][0]}" fill-opacity="{c["base"][1]}"/>'
            f'<circle r="{CANCEL_R:.1f}" fill="url(#cancelGlass)"/>'
            f'<circle r="{CANCEL_R - 0.5:.1f}" fill="none" stroke="url(#cancelRim)" stroke-width="1"/>'
            f'<ellipse cx="{-0.08 * 2 * CANCEL_R:.1f}" cy="{-0.22 * 2 * CANCEL_R:.1f}" '
            f'rx="{0.275 * 2 * CANCEL_R:.1f}" ry="{0.11 * 2 * CANCEL_R:.1f}" fill="url(#cancelGloss)"/>'
            '<path d="M -5.4 -5.4 L 5.4 5.4 M 5.4 -5.4 L -5.4 5.4" '
            f'stroke="{c["x"][0]}" stroke-opacity="{c["x"][1]}" stroke-width="2.2" stroke-linecap="round"/>')

def arc(cx, cy, r, a0, a1):
    p = lambda a: (cx + r * math.cos(math.radians(a)), cy + r * math.sin(math.radians(a)))
    (x0, y0), (x1, y1) = p(a0), p(a1)
    return f"M {x0:.1f} {y0:.1f} A {r:.1f} {r:.1f} 0 0 1 {x1:.1f} {y1:.1f}"


def sheen_stops(t):
    """LiquidGlassText's silver sweep: dark text glints white in the light theme,
    0.7 white brightens to full white in the dark one."""
    if t["cap_text"] != "#FFFFFF":
        ink = t["cap_text"]
        pairs = [(ink, 1), (ink, 0.75), ("#FFFFFF", 1), (ink, 0.75), (ink, 1)]
    else:
        pairs = [("#FFFFFF", 0.70), ("#FFFFFF", 0.85), ("#FFFFFF", 1), ("#FFFFFF", 0.85), ("#FFFFFF", 0.70)]
    return stops(pairs, (0, 0.35, 0.5, 0.65, 1))


def capsule(c, t, animated):
    """Recording bar in the Liquid Glass theme that matches the page."""
    sfx = "A" if animated else "S"
    frames, wf, twf = motion(c)
    fr = frames if animated else None
    left = lambda f: f"{CAP_CX - f[1] / 2:.1f},0"
    right = lambda f: f"{CAP_CX + f[1] / 2:.1f},0"
    o = [f'<g class="{"anim" if animated else "still"}">']
    if animated:
        # appear / dismiss: fade with a slight scale about the bar centre
        times = key_times([0, SHOW, HIDE_AT, HIDE_AT + HIDE, LOOP])
        o.append(f'<g><animate attributeName="opacity" values="0;1;1;0;0" keyTimes="{times}" '
                 f'calcMode="spline" keySplines="{EASE};{FLAT};{EASE};{FLAT}" dur="{LOOP}s" repeatCount="indefinite"/>')
        o.append(f'<g transform="translate({CAP_CX},{CAP_CY})"><g>'
                 f'<animateTransform attributeName="transform" type="scale" values="0.94;1;1;0.97;0.97" '
                 f'keyTimes="{times}" calcMode="spline" keySplines="{EASE};{FLAT};{EASE};{FLAT}" '
                 f'dur="{LOOP}s" repeatCount="indefinite"/>'
                 f'<g transform="translate({-CAP_CX},{-CAP_CY})">')
    o.append(f'<defs><clipPath id="capClip{sfx}">{bar_rect(fr, wf)}</clipPath>'
             f'<mask id="capOut{sfx}" maskUnits="userSpaceOnUse" x="0" y="0" width="{W}" height="{H}">'
             f'<rect width="{W}" height="{H}" fill="#fff"/>{bar_rect(fr, wf, extra="fill=\"#000\"")}</mask></defs>')
    # drop shadow only outside the glass (GlassOuterShadow), plus a soft lift for the hero
    o.append(f'<g mask="url(#capOut{sfx})">'
             + bar_rect(fr, wf, inset=4 * SCALE, dy=12,
                        extra=f'fill="#000" fill-opacity="{t["shadow_far_op"]}" filter="url(#farShadow)"')
             + bar_rect(fr, wf, inset=4 * SCALE, dy=2 * SCALE,
                        extra=f'fill="#000" fill-opacity="{t["shadow_near_op"]}" filter="url(#nearShadow)"')
             + '</g>')
    # the glass: tinted body over the magnified dot grid behind it, lit from above,
    # with a soft lens glow inside the rim
    o.append(f'<g clip-path="url(#capClip{sfx})">'
             + bar_rect(fr, wf, extra=f'fill="{t["glass_tint"]}" fill-opacity="{t["glass_tint_op"]}"')
             + f'<rect x="0" y="{CAP_CY - 60}" width="720" height="120" fill="url(#lensDots)" '
               f'opacity="{t["glass_dots_op"]}" filter="url(#lensSoft)" '
               f'transform="translate({CAP_CX},{CAP_CY}) scale(1.18) translate({-CAP_CX},{-CAP_CY})"/>'
             + bar_rect(fr, wf, extra='fill="url(#glassBody)"')
             + bar_rect(fr, wf, extra=f'fill="none" stroke="{t["lens"]}" stroke-opacity="{t["lens_op"]}" '
                                     'stroke-width="12" filter="url(#lensBlur)"')
             + '</g>')
    o.append(bar_rect(fr, wf, inset=0.6, extra='fill="none" stroke="url(#glassRim)" stroke-width="1.2"'))
    if t["edge"]:
        # on a white page the clear glass needs a faint edge to read at all
        o.append(bar_rect(fr, wf, extra=f'fill="none" stroke="#000" stroke-opacity="{t["edge"]}" stroke-width="1"'))

    # left end: specular glint on the rim + orb (finish button)
    o.append(f'<g transform="translate({CAP_CX - wf / 2:.1f},0)">{track(fr, left) if fr else ""}'
             f'<path d="{arc(CAP_R, CAP_CY, CAP_R - 1.6, 195, 265)}" fill="none" stroke="#fff" '
             f'stroke-opacity="{t["glint_op"][0]}" stroke-width="1.6" stroke-linecap="round" filter="url(#shineBlur)"/>'
             f'<g transform="translate({CONTROL_INSET:.1f},{CAP_CY}) scale({45 * SCALE / 56:.3f})">{ORB}</g></g>')

    # text, centred between the controls: each glyph fades in at its measured
    # offset while the line re-centres on the same spring as the bar
    tx, ty = CAP_CX + TEXT_DX, CAP_CY + 6.5
    if animated:
        hint, hint_pt = c["listening"]
        hw = hint_pt * SCALE
        g = 0.18 * hw
        x_from, x_to = tx - hw / 2 - 0.30 * hw, tx - hw / 2 + 1.30 * hw
        o.append(f'<linearGradient id="sheen" gradientUnits="userSpaceOnUse" x1="{-g:.1f}" y1="0" x2="{g:.1f}" y2="0" '
                 f'gradientTransform="translate({x_from:.1f},0)">'
                 f'<animateTransform attributeName="gradientTransform" type="translate" '
                 f'values="{x_from:.1f},0;{x_from:.1f},0;{x_to:.1f},0;{x_to:.1f},0" '
                 f'keyTimes="{key_times([0, SWEEP[0], SWEEP[1], LOOP])}" dur="{LOOP}s" repeatCount="indefinite"/>'
                 + sheen_stops(t) + '</linearGradient>')
        o.append(f'<text x="{tx:.1f}" y="{ty:.1f}" text-anchor="middle" class="cap-text" '
                 f'style="fill:url(#sheen)" opacity="0">'
                 f'{fade("opacity", ["1", "1", "0", "0"], [0, LISTEN_END - 0.22, LISTEN_END - 0.04, LOOP])}'
                 f'{escape(hint)}</text>')
    spans = []
    gtimes = glyph_times(c)
    for ch, gx, gt in zip(c["transcript"], c["glyph_x"], gtimes):
        anim = fade("fill-opacity", ["0", "0", "1", "1"], [0, gt, gt + GLYPH_FADE, LOOP]) if animated else ""
        spans.append(f'<tspan x="{gx * SCALE:.1f}">{anim}{escape(ch)}</tspan>')
    line_anim = track(fr, lambda f: f"{tx - f[2] / 2:.1f},0") if fr else ""
    # clipped to the text area between the controls, like the overlay in recordingText
    lo, ro = (v * SCALE for v in TEXT_SIDE_INSETS)
    area = (track(fr, lambda f: f"{CAP_CX - f[1] / 2 + lo:.1f}", "x")
            + track(fr, lambda f: f"{f[1] - lo - ro:.1f}", "width")) if fr else ""
    o.append(f'<clipPath id="textClip{sfx}"><rect x="{CAP_CX - wf / 2 + lo:.1f}" y="{CAP_CY - CAP_R:.1f}" '
             f'width="{wf - lo - ro:.1f}" height="{CAP_H:.1f}">{area}</rect></clipPath>')
    o.append(f'<g clip-path="url(#textClip{sfx})"><g transform="translate({tx - twf / 2:.1f},0)">{line_anim}'
             f'<text y="{ty:.1f}" class="cap-text">{"".join(spans)}</text></g></g>')

    # right end: fainter lower glint + glass cancel button
    o.append(f'<g transform="translate({CAP_CX + wf / 2:.1f},0)">{track(fr, right) if fr else ""}'
             f'<path d="{arc(-CAP_R, CAP_CY, CAP_R - 1.6, 20, 80)}" fill="none" stroke="#fff" '
             f'stroke-opacity="{t["glint_op"][1]}" stroke-width="1.4" stroke-linecap="round" filter="url(#shineBlur)"/>'
             f'<g transform="translate({-CONTROL_INSET:.1f},{CAP_CY})">{cancel_button(t)}</g></g>')
    if animated:
        o.append("</g></g></g></g>")
    o.append("</g>")
    return "".join(o)

def build(lang, theme):
    c, t = COPY[lang], THEMES[theme]
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
             f'role="img" aria-label="{escape(c["title"])}" lang="{c["lang"]}">')
    o.append(f"<title>{escape(c['title'])}</title>")
    o.append(f"""<defs>
  <style>
    text {{ font-family: {FONT}; }}
    .badge {{ font-size: 13px; font-weight: 500; fill: {t['badge_text']}; }}
    .h1 {{ font-weight: 800; fill: {t['text']}; letter-spacing: -1px; }}
    .sub {{ font-size: 19px; font-weight: 400; fill: {t['text2']}; }}
    .pill {{ font-size: 14px; font-weight: 500; fill: {t['pill_text']}; }}
    .cap-text {{ font-size: {14 * SCALE:.1f}px; font-weight: 500; fill: {t['cap_text']}; }}
    .ct {{ font-size: 19px; font-weight: 700; fill: {t['text']}; }}
    .cs {{ font-size: 13px; fill: {t['text2']}; }}
    .mt {{ font-size: 16px; font-weight: 600; fill: {t['text']}; }}
    .md {{ font-size: 13px; fill: {t['text3']}; }}
    .chip {{ font-size: 14px; font-weight: 600; fill: {t['chip_text']}; }}
    .rec {{ font-size: 12px; font-weight: 600; fill: {t['accent_text']}; }}
    .foot {{ font-size: 13px; fill: {t['text3']}; letter-spacing: 0.4px; }}
    .orb-spin {{ transform-origin: 0 0; animation: spin 7s linear infinite; }}
    .orb-spin2 {{ transform-origin: 0 0; animation: spin 11s linear infinite reverse; }}
    .pulse {{ animation: pulse 1.6s ease-in-out infinite; }}
    .still {{ display: none; }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    @keyframes pulse {{ 0%,100% {{ opacity: 1; }} 50% {{ opacity: .35; }} }}
    @media (prefers-reduced-motion: reduce) {{
      .orb-spin, .orb-spin2, .pulse {{ animation: none; }}
      .anim {{ display: none; }}
      .still {{ display: inline; }}
    }}
  </style>
  <pattern id="dots" width="16" height="16" patternUnits="userSpaceOnUse">
    <circle cx="2" cy="2" r="1" fill="{t['dot']}" fill-opacity="{t['dot_op']}"/>
  </pattern>
  <linearGradient id="dotfade" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#fff" stop-opacity="0"/>
    <stop offset="0.45" stop-color="#fff" stop-opacity="0.25"/>
    <stop offset="1" stop-color="#fff" stop-opacity="1"/>
  </linearGradient>
  <mask id="dotmask"><rect width="{W}" height="{H}" fill="url(#dotfade)"/></mask>
  <filter id="shadow" x="-20%" y="-20%" width="140%" height="160%">
    <feDropShadow dx="0" dy="10" stdDeviation="16" flood-color="#000" flood-opacity="{t['shadow_op']}"/>
  </filter>
  <filter id="blur6"><feGaussianBlur stdDeviation="6"/></filter>
  <filter id="blur3"><feGaussianBlur stdDeviation="3"/></filter>
  <radialGradient id="orbBase" cx="50%" cy="50%" r="50%">
    <stop offset="0" stop-color="#1A1F3A"/>
    <stop offset="1" stop-color="#030409"/>
  </radialGradient>
  <linearGradient id="orbRim" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.75"/>
    <stop offset="0.5" stop-color="#FFFFFF" stop-opacity="0.15"/>
    <stop offset="1" stop-color="#FFFFFF" stop-opacity="0.45"/>
  </linearGradient>
  <clipPath id="orbClip"><circle cx="0" cy="0" r="27"/></clipPath>
  <linearGradient id="activeRow" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{t['active_a']}"/>
    <stop offset="1" stop-color="{t['active_b']}"/>
  </linearGradient>
""" + glass_defs(t) + "</defs>")

    # canvas
    o.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="24" fill="{t["bg"]}" '
             f'stroke="{t["edge"]}" stroke-opacity="{t["edge_op"]}"/>')
    o.append(f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="24" fill="url(#dots)" mask="url(#dotmask)"/>')

    # brand row: the handwritten wordmark, as at the top of the app's sidebar
    k = WORDMARK_H / WORDMARK_BOX[1]
    o.append(f'<g transform="translate(60,{61 - WORDMARK_H / 2:.1f}) scale({k:.4f})" aria-hidden="true">'
             f'<path d="{WORDMARK_LETTERS}" fill="{t["wordmark"]}"/><path d="{WORDMARK_DOT}" fill="{WORDMARK_RED}"/></g>')

    # badges top right
    bx = W - 64
    for b in reversed(c["badges"]):
        w = text_w(b, 13) + 24
        bx -= w
        o.append(f'<rect x="{bx:.1f}" y="46" width="{w:.1f}" height="30" rx="15" fill="{t["badge_bg"]}" '
                 f'stroke="{t["edge"]}" stroke-opacity="{t["card_edge_op"]+0.02}"/>')
        o.append(f'<text x="{bx + w/2:.1f}" y="65.5" text-anchor="middle" class="badge">{escape(b)}</text>')
        bx -= 8

    # headline + subtitle
    o.append(f'<text x="62" y="196" class="h1" font-size="{c["headline_size"]}">{escape(c["headline"])}</text>')
    for i, line in enumerate(c["sub"]):
        o.append(f'<text x="64" y="{246 + i*30}" class="sub">{escape(line)}</text>')

    # feature pills
    px = 64
    for p in c["pills"]:
        w = text_w(p, 14) + 28
        o.append(f'<rect x="{px:.1f}" y="316" width="{w:.1f}" height="32" rx="16" fill="{t["pill"]}"/>')
        o.append(f'<text x="{px + w/2:.1f}" y="337" text-anchor="middle" class="pill">{escape(p)}</text>')
        px += w + 8

    # recording bar: the backdrop it floats over, then an animated and a still copy
    o.append(f'<use href="#field" opacity="{t["field_op"]}"/>')
    o.append(capsule(c, t, animated=True))
    o.append(capsule(c, t, animated=False))

    # "My modes" card
    kx0, ky0, kw, kh = 712, 112, 424, 410
    o.append(f'<g filter="url(#shadow)"><rect x="{kx0}" y="{ky0}" width="{kw}" height="{kh}" rx="20" '
             f'fill="{t["card"]}" stroke="{t["edge"]}" stroke-opacity="{t["card_edge_op"]}"/></g>')
    o.append(f'<text x="{kx0+24}" y="{ky0+40}" class="ct">{escape(c["card_title"])}</text>')
    o.append(f'<text x="{kx0+24}" y="{ky0+62}" class="cs">{escape(c["card_sub"])}</text>')
    o.append(f'<circle cx="{kx0+kw-38}" cy="{ky0+44}" r="16" fill="{t["icon_btn"]}"/>')
    for i, dy in enumerate((-5, 0, 5)):
        x1 = kx0 + kw - 46
        o.append(f'<line x1="{x1}" y1="{ky0+44+dy}" x2="{x1+16}" y2="{ky0+44+dy}" stroke="{t["icon_line"]}" '
                 'stroke-width="1.4" stroke-linecap="round"/>')
        o.append(f'<circle cx="{x1 + (4, 11, 6)[i]}" cy="{ky0+44+dy}" r="2.2" fill="{t["icon_btn"]}" '
                 f'stroke="{t["icon_line"]}" stroke-width="1.3"/>')
    o.append(f'<line x1="{kx0+24}" y1="{ky0+82}" x2="{kx0+kw-24}" y2="{ky0+82}" stroke="{t["edge"]}" '
             f'stroke-opacity="{t["rule_op"]}"/>')

    row_h = 62
    ry = ky0 + 90
    for i, (name, desc, key) in enumerate(c["modes"]):
        active = i == c["active"]
        if active:
            o.append(f'<rect x="{kx0+10}" y="{ry}" width="{kw-20}" height="{row_h-4}" rx="14" fill="url(#activeRow)"/>')
        o.append(f'<text x="{kx0+24}" y="{ry+25}" class="mt">{escape(name)}</text>')
        if active:
            nx = kx0 + 24 + text_w(name, 16) + 12
            o.append(f'<circle class="pulse" cx="{nx+4:.1f}" cy="{ry+19}" r="4" fill="{t["accent"]}"/>')
            o.append(f'<text x="{nx+13:.1f}" y="{ry+23.5}" class="rec">{escape(c["recording"])}</text>')
        o.append(f'<text x="{kx0+24}" y="{ry+45}" class="md">{escape(desc)}</text>')
        # hotkey chip: green tint + cycle glyph, as on the home page
        cw_ = text_w(key, 14) + 50
        cxr = kx0 + kw - 26 - cw_
        cy_ = ry + row_h / 2 - 2
        o.append(f'<rect x="{cxr:.1f}" y="{cy_-15:.1f}" width="{cw_:.1f}" height="30" rx="15" '
                 f'fill="{t["chip"]}" stroke="{t["chip_edge"]}"/>')
        gx, gy = cxr + 17, cy_
        o.append(f'<g transform="translate({gx:.1f},{gy:.1f})" fill="none" stroke="{t["chip_icon"]}" '
                 'stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'
                 '<path d="M 4.6 -2.2 A 5 5 0 0 0 -4.4 -2"/><path d="M -4.6 2.2 A 5 5 0 0 0 4.4 2"/>'
                 '<path d="M -4.6 -4.6 L -4.4 -2 L -1.8 -2.2"/><path d="M 4.6 4.6 L 4.4 2 L 1.8 2.2"/></g>')
        o.append(f'<text x="{cxr+30:.1f}" y="{cy_+5:.1f}" class="chip">{escape(key)}</text>')
        if i < len(c["modes"]) - 1 and not active and i + 1 != c["active"]:
            o.append(f'<line x1="{kx0+24}" y1="{ry+row_h-2}" x2="{kx0+kw-24}" y2="{ry+row_h-2}" '
                     f'stroke="{t["edge"]}" stroke-opacity="{t["rule_op"] - 0.01}"/>')
        ry += row_h

    # footer
    o.append(f'<line x1="64" y1="{H-62}" x2="640" y2="{H-62}" stroke="{t["edge"]}" stroke-opacity="{t["rule_op"]}"/>')
    o.append(f'<text x="64" y="{H-34}" class="foot">github.com/joewongjc/type4me</text>')
    o.append(f'<text x="640" y="{H-34}" text-anchor="end" class="foot">{escape(c["footer_r"])}</text>')
    o.append("</svg>")
    return "\n".join(o) + "\n"


if __name__ == "__main__":
    out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[2] / "docs" / "images"
    out.mkdir(parents=True, exist_ok=True)
    for lang, stem in (("zh", "header"), ("en", "header-en")):
        (out / f"{stem}.svg").write_text(build(lang, "light"), encoding="utf-8")
        (out / f"{stem}-dark.svg").write_text(build(lang, "dark"), encoding="utf-8")
    print(f"wrote 4 headers to {out}")
