#!/usr/bin/env python3
"""Generate the README hero images in the current Type4Me app style.

Writes four files into docs/images/ (or the directory given as argv[1]):
    header.svg, header-dark.svg        Chinese, light / dark
    header-en.svg, header-en-dark.svg  English, light / dark

Visual language mirrors the app:
- neutral canvas with a faint dot grid (main window background)
- bold system headline from HomeDashboardView ("说出想法，即刻成文" / "Say it. Shape it.")
- "我的模式" card with green-tinted hotkey chips (home page)
- dark Liquid Glass recording capsule with the Siri orb preset
- blue accent from the home heatmap / usage overview

Re-run after changing copy:  python3 scripts/readme/gen_header.py
"""
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
        "transcript": "实时流式语音识别，自定义语音工作流。",
        "tooltip": "取消录制",
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
        "transcript": "Streaming ASR, custom voice workflows.",
        "tooltip": "Cancel",
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
        "capsule_edge": "#262729", "cap_shadow_op": 0.22,
    },
    "dark": {
        "bg": "#161618", "edge": "#FFFFFF", "edge_op": 0.10, "dot": "#FFFFFF", "dot_op": 0.06,
        "text": "#F4F4F5", "text2": "#A1A1A6", "text3": "#7C7C82",
        "pill": "#2A2A2D", "pill_text": "#E4E4E7", "badge_bg": "#1F1F22", "badge_text": "#C7C7CC",
        "card": "#1F1F22", "card_edge_op": 0.10, "rule_op": 0.09, "shadow_op": 0.35,
        "icon_btn": "#2C2C2F", "icon_line": "#BDBDC2",
        "chip": "#1C2E21", "chip_edge": "#2E4A35", "chip_text": "#CFEAD4", "chip_icon": "#6BC47A",
        "active_a": "#1B2440", "active_b": "#1D2333", "accent": "#5B8BFF", "accent_text": "#8FB0FF",
        "capsule_edge": "#3A3B3F", "cap_shadow_op": 0.5,
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


def build(lang, theme):
    c, t = COPY[lang], THEMES[theme]
    o = []
    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" '
             f'role="img" aria-label="{escape(c["title"])}" lang="{c["lang"]}">')
    o.append(f"<title>{escape(c['title'])}</title>")
    o.append(f"""<defs>
  <style>
    text {{ font-family: {FONT}; }}
    .brand {{ font-size: 22px; font-weight: 700; fill: {t['text']}; letter-spacing: -0.2px; }}
    .badge {{ font-size: 13px; font-weight: 500; fill: {t['badge_text']}; }}
    .h1 {{ font-weight: 800; fill: {t['text']}; letter-spacing: -1px; }}
    .sub {{ font-size: 19px; font-weight: 400; fill: {t['text2']}; }}
    .pill {{ font-size: 14px; font-weight: 500; fill: {t['pill_text']}; }}
    .cap-text {{ font-size: 19px; font-weight: 600; fill: #FFFFFF; }}
    .tip {{ font-size: 15px; font-weight: 600; fill: #FFFFFF; }}
    .esc {{ font-size: 12px; font-weight: 700; fill: #FFFFFF; }}
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
    .wipe {{ animation: wipe 7s cubic-bezier(.4,0,.6,1) infinite; }}
    .caret {{ animation: blink 1s steps(1) infinite; }}
    @keyframes spin {{ to {{ transform: rotate(360deg); }} }}
    @keyframes pulse {{ 0%,100% {{ opacity: 1; }} 50% {{ opacity: .35; }} }}
    /* 0% is the fully revealed frame so static renderers show the whole sentence. */
    @keyframes wipe {{ 0%,38% {{ transform: translateX(var(--w)); }} 40%,44% {{ transform: translateX(0); }} 92%,100% {{ transform: translateX(var(--w)); }} }}
    @keyframes blink {{ 50% {{ opacity: 0; }} }}
    @media (prefers-reduced-motion: reduce) {{
      .orb-spin, .orb-spin2, .pulse, .wipe, .caret {{ animation: none; }}
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
  <filter id="capShadow" x="-10%" y="-40%" width="120%" height="200%">
    <feDropShadow dx="0" dy="14" stdDeviation="14" flood-color="#000" flood-opacity="{t['cap_shadow_op']}"/>
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
  <radialGradient id="cancelFill" cx="40%" cy="30%" r="80%">
    <stop offset="0" stop-color="#6B6B6B"/>
    <stop offset="1" stop-color="#2C2C2C"/>
  </radialGradient>
  <clipPath id="orbClip"><circle cx="0" cy="0" r="27"/></clipPath>
  <clipPath id="capClip"><rect x="64" y="418" width="576" height="72" rx="36"/></clipPath>
  <linearGradient id="activeRow" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="{t['active_a']}"/>
    <stop offset="1" stop-color="{t['active_b']}"/>
  </linearGradient>
</defs>""")

    # canvas
    o.append(f'<rect x="0.5" y="0.5" width="{W-1}" height="{H-1}" rx="24" fill="{t["bg"]}" '
             f'stroke="{t["edge"]}" stroke-opacity="{t["edge_op"]}"/>')
    o.append(f'<rect x="1" y="1" width="{W-2}" height="{H-2}" rx="24" fill="url(#dots)" mask="url(#dotmask)"/>')

    # brand row: waveform.circle.fill + name, as in the sidebar
    o.append(f'<g transform="translate(64,62)"><circle cx="16" cy="0" r="16" fill="{t["text"]}"/>')
    for dx, hh in [(-8, 5), (-4, 9), (0, 13), (4, 8), (8, 4)]:
        o.append(f'<rect x="{16+dx-1.2:.1f}" y="{-hh/2:.1f}" width="2.4" height="{hh}" rx="1.2" fill="{t["bg"]}"/>')
    o.append('<text x="44" y="8" class="brand">Type4Me</text></g>')

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

    # recording capsule (always dark: the default Liquid Glass theme)
    cx0, cy0, cw, ch = 64, 418, 576, 72
    o.append(f'<g filter="url(#capShadow)"><rect x="{cx0}" y="{cy0}" width="{cw}" height="{ch}" rx="{ch/2}" '
             f'fill="#111214" stroke="{t["capsule_edge"]}" stroke-width="1.5"/></g>')
    tip_w = text_w(c["tooltip"], 15) + 70
    tx = cx0 + cw - tip_w + 6
    o.append(f'<rect x="{tx:.1f}" y="{cy0-56}" width="{tip_w:.1f}" height="40" rx="12" fill="#111214" '
             f'stroke="{t["capsule_edge"]}"/>')
    o.append(f'<text x="{tx+16:.1f}" y="{cy0-31}" class="tip">{escape(c["tooltip"])}</text>')
    o.append(f'<rect x="{tx+tip_w-52:.1f}" y="{cy0-47}" width="38" height="22" rx="11" fill="#8A8A8A"/>')
    o.append(f'<text x="{tx+tip_w-33:.1f}" y="{cy0-31.5}" text-anchor="middle" class="esc">esc</text>')

    ox, oy = cx0 + 41, cy0 + ch / 2
    o.append(f'<g transform="translate({ox},{oy})">'
             '<circle r="28" fill="url(#orbBase)"/>'
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
             '<ellipse cx="-8" cy="-15" rx="9" ry="4" fill="#fff" opacity="0.18"/>'
             '</g>')

    # transcript; a capsule-coloured cover slides right to "type" it. The resting
    # transform is the fully revealed state.
    text_x = cx0 + 84
    tw = min(text_w(c["transcript"], 19) + 8, cw - 84 - 70)
    o.append(f'<text x="{text_x}" y="{oy+7}" class="cap-text">{escape(c["transcript"])}</text>')
    o.append(f'<g clip-path="url(#capClip)"><g class="wipe" style="--w:{tw:.0f}px" transform="translate({tw:.0f},0)">'
             f'<rect x="{text_x-2}" y="{cy0+2}" width="{cw}" height="{ch-4}" fill="#111214"/>'
             f'<rect class="caret" x="{text_x}" y="{oy-12}" width="2.5" height="24" rx="1.25" fill="#8FB4FF"/>'
             '</g></g>')

    kx, ky = cx0 + cw - 38, oy
    o.append(f'<g transform="translate({kx},{ky})">'
             '<circle r="22" fill="url(#cancelFill)" stroke="#fff" stroke-opacity="0.28"/>'
             '<path d="M -6.5 -6.5 L 6.5 6.5 M 6.5 -6.5 L -6.5 6.5" stroke="#fff" stroke-width="2.6" stroke-linecap="round"/>'
             '</g>')

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
