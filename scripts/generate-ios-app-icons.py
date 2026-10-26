#!/usr/bin/env python3
"""Generate the iOS alternate app icons and their Settings previews.

The hand-made originals stay the source of truth:
  iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png                 (light)
  iOS/App/Assets.xcassets/AppIcon.appiconset/AppIcon-DarkAppearance.png  (dark)
The "4" and the dot are lifted from the light original, so re-running this
after an edit to the originals keeps every variant in step.

Requires Pillow:  python3 -m venv /tmp/icons && /tmp/icons/bin/pip install pillow
Run:              /tmp/icons/bin/python scripts/generate-ios-app-icons.py
"""

import json
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "iOS/App/Assets.xcassets"
DEFAULT_SET = ASSETS / "AppIcon.appiconset"
PREVIEWS = ASSETS / "AppIconPreviews"

N = 1024
SS = 2  # supersampling for the keycap's curves and blurs
PREVIEW = 180

INK, PAPER = (17, 17, 17), (245, 245, 242)
RED_LIGHT, RED_DARK = (232, 56, 13), (255, 74, 31)

# The dot sits below this row in the original, the "4" above it.
SPLIT_Y = 712


def load_marks():
    light = Image.open(DEFAULT_SET / "AppIcon.png").convert("RGB")
    # Ink coverage from luminance, dot coverage from the green channel
    # (white and ink are neutral; only the red dot lacks green).
    glyph = light.convert("L").point(lambda v: max(0, min(255, round((255 - v) * 255 / (255 - 17)))))
    dot = light.getchannel("G").point(lambda v: max(0, min(255, round((255 - v) * 255 / (255 - 56)))))
    ImageDraw.Draw(glyph).rectangle([0, SPLIT_Y, N, N], fill=0)
    ImageDraw.Draw(dot).rectangle([0, 0, N, SPLIT_Y], fill=0)
    return glyph, dot


GLYPH, DOT = load_marks()


def solid(color, size=N, alpha=255):
    return Image.new("RGBA", (size, size), color + (alpha,))


def stamp(canvas, glyph_color, dot_color, scale=1.0, cy=512):
    """Paint the "4" and dot, scaled about the icon centre, centred at cy."""
    size = canvas.size[0]
    k = size / N
    side = round(N * scale * k)
    glyph = GLYPH.resize((side, side), Image.LANCZOS)
    dot = DOT.resize((side, side), Image.LANCZOS)
    offset = (round((size - side) / 2), round(cy * k - side / 2))
    canvas.paste(solid(glyph_color, side), offset, glyph)
    canvas.paste(solid(dot_color, side), offset, dot)
    return canvas


def vertical_gradient(size, top, bottom):
    ramp = Image.linear_gradient("L").resize((size, size))
    return Image.composite(solid(bottom, size), solid(top, size), ramp)


def rounded(size, box, radius):
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius, fill=255)
    return mask


def side_shade(size):
    """V-shaped mask: strongest at the left and right edges, clear in the middle."""
    ramp = Image.linear_gradient("L").rotate(90, expand=True).resize((size, size))
    return ImageChops.difference(ramp, Image.new("L", (size, size), 128)).point(lambda v: max(0, v - 70) * 255 // 58)


def fade_from_top(size, reach, power):
    """1 at the top, 0 from `reach` (of 255) down."""
    return Image.linear_gradient("L").resize((size, size)).point(lambda v: round(255 * max(0, 1 - v / reach) ** power))


def tinted_paste(img, color, mask, strength):
    img.paste(solid(color, img.size[0]), (0, 0), mask.point(lambda v: round(v * strength)))


def keycap(p):
    z = N * SS
    s = lambda v: round(v * SS)
    img = vertical_gradient(z, p["bg_top"], p["bg_bottom"])

    # Drop shadow, plus a tight contact shadow right under the cap.
    drop = rounded(z, [s(130), s(250), s(894), s(960)], s(190)).filter(ImageFilter.GaussianBlur(s(46)))
    tinted_paste(img, (0, 0, 0), drop, p["shadow"])
    contact = rounded(z, [s(126), s(150), s(898), s(918)], s(184)).filter(ImageFilter.GaussianBlur(s(10)))
    tinted_paste(img, (0, 0, 0), contact, p["contact"])

    # Skirt: the cap's sides, deeper at the bottom so the top face reads as
    # raised, and darker at the left and right where they turn from the light.
    skirt = [s(120), s(120), s(904), s(904)]
    skirt_mask = rounded(z, skirt, s(180))
    img.paste(vertical_gradient(z, p["skirt_top"], p["skirt_bottom"]), (0, 0), skirt_mask)
    tinted_paste(img, (0, 0, 0), ImageChops.multiply(skirt_mask, side_shade(z)), p["side"])
    outline = Image.new("L", (z, z), 0)
    ImageDraw.Draw(outline).rounded_rectangle(skirt, s(180), outline=255, width=s(3))
    tinted_paste(img, p["outline"], outline, p["outline_strength"])
    lip = Image.new("L", (z, z), 0)
    ImageDraw.Draw(lip).rounded_rectangle([v + d for v, d in zip(skirt, (s(3), s(3), -s(3), -s(3)))], s(177), outline=255, width=s(4))
    tinted_paste(img, (255, 255, 255), ImageChops.multiply(lip, fade_from_top(z, 160, 1.4)), p["lip"])

    # Top face, with the shadow it casts onto the skirt below it.
    face = [s(176), s(140), s(848), s(800)]
    face_mask = rounded(z, face, s(140))
    under = rounded(z, [s(176), s(160), s(848), s(830)], s(140)).filter(ImageFilter.GaussianBlur(s(14)))
    tinted_paste(img, (0, 0, 0), ImageChops.subtract(under, face_mask), p["under"])
    img.paste(vertical_gradient(z, p["face_top"], p["face_bottom"]), (0, 0), face_mask)

    # Dish: shading toward the rim of the top face.
    inner = rounded(z, [s(206), s(166), s(818), s(772)], s(116)).filter(ImageFilter.GaussianBlur(s(30)))
    tinted_paste(img, p["dish_color"], ImageChops.subtract(face_mask, inner), p["dish"])

    # Gloss in the upper left, a bright top edge and a dark bottom edge.
    gloss = Image.new("L", (z, z), 0)
    ImageDraw.Draw(gloss).ellipse([s(200), s(150), s(640), s(470)], fill=255)
    tinted_paste(img, (255, 255, 255), ImageChops.multiply(gloss.filter(ImageFilter.GaussianBlur(s(70))), face_mask), p["gloss"])
    edge = Image.new("L", (z, z), 0)
    ImageDraw.Draw(edge).rounded_rectangle(face, s(140), outline=255, width=s(3))
    tinted_paste(img, (255, 255, 255), ImageChops.multiply(edge, fade_from_top(z, 170, 1.2)), p["highlight"])
    from_bottom = Image.linear_gradient("L").resize((z, z)).point(lambda v: round(255 * max(0, (v - 150) / 105) ** 1.2))
    tinted_paste(img, (0, 0, 0), ImageChops.multiply(edge, from_bottom), p["lowlight"])

    stamp(img, p["glyph"], p["dot"], scale=0.7, cy=470)
    return img.resize((N, N), Image.LANCZOS).convert("RGB")


LIGHT_BACKGROUND = dict(bg_top=(236, 234, 229), bg_bottom=(222, 219, 212), shadow=0.51, contact=0.27)
# The dark cap sits on mid grey: on near-black its edges and gloss disappear.
GREY_BACKGROUND = dict(bg_top=(84, 84, 88), bg_bottom=(58, 58, 62), shadow=0.78, contact=0.59)

KEYCAPS = {
    "KeycapLight": dict(
        LIGHT_BACKGROUND,
        skirt_top=(222, 218, 210), skirt_bottom=(186, 181, 171), side=0.22,
        outline=(120, 114, 104), outline_strength=0.43, lip=0.78,
        face_top=(255, 255, 253), face_bottom=(236, 233, 227), under=0.47,
        dish=0.16, dish_color=(140, 134, 122), gloss=0.55, highlight=1.0, lowlight=0.24,
        glyph=INK, dot=RED_LIGHT,
    ),
    "KeycapDark": dict(
        GREY_BACKGROUND,
        skirt_top=(44, 44, 46), skirt_bottom=(16, 16, 17), side=0.45,
        outline=(0, 0, 0), outline_strength=0.78, lip=0.27,
        face_top=(66, 66, 68), face_bottom=(42, 42, 44), under=0.78,
        dish=0.45, dish_color=(14, 14, 15), gloss=0.13, highlight=0.59, lowlight=0.63,
        glyph=PAPER, dot=RED_DARK,
    ),
    "KeycapRed": dict(
        LIGHT_BACKGROUND,
        skirt_top=(214, 50, 12), skirt_bottom=(160, 32, 4), side=0.25,
        outline=(110, 20, 0), outline_strength=0.47, lip=0.55,
        face_top=(252, 82, 38), face_bottom=(228, 54, 14), under=0.59,
        dish=0.28, dish_color=(140, 26, 0), gloss=0.30, highlight=0.78, lowlight=0.35,
        glyph=(255, 255, 255), dot=(255, 255, 255),
    ),
}


def write_icon_set(name, files):
    """files: list of (filename, image or None to keep the file, appearance or None)."""
    folder = ASSETS / f"{name}.appiconset"
    folder.mkdir(exist_ok=True)
    images = []
    for filename, image, appearance in files:
        if image is not None:
            image.save(folder / filename)
        entry = {"filename": filename, "idiom": "universal", "platform": "ios", "size": "1024x1024"}
        if appearance:
            entry = {"appearances": [{"appearance": "luminosity", "value": appearance}], **entry}
        images.append(entry)
    write_json(folder / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})


def write_preview(name, light, dark=None):
    folder = PREVIEWS / f"AppIconPreview-{name}.imageset"
    folder.mkdir(parents=True, exist_ok=True)
    images = []
    for filename, image, appearance in [(f"{name}.png", light, None), (f"{name}-Dark.png", dark, "dark")]:
        if image is None:
            continue
        image.convert("RGB").resize((PREVIEW, PREVIEW), Image.LANCZOS).save(folder / filename)
        entry = {"filename": filename, "idiom": "universal"}
        if appearance:
            entry["appearances"] = [{"appearance": "luminosity", "value": appearance}]
        images.append(entry)
    write_json(folder / "Contents.json", {"images": images, "info": {"author": "xcode", "version": 1}})


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def main():
    light = Image.open(DEFAULT_SET / "AppIcon.png").convert("RGB")
    dark = Image.open(DEFAULT_SET / "AppIcon-DarkAppearance.png").convert("RGB")

    # Tinted Home Screen: iOS keeps only luminance, so the dot is mid grey to
    # stay distinct from the white "4".
    tinted = stamp(Image.new("RGBA", (N, N), (0, 0, 0, 0)), (255, 255, 255), (150, 150, 150))
    write_icon_set("AppIcon", [
        ("AppIcon.png", None, None),
        ("AppIcon-DarkAppearance.png", None, "dark"),
        ("AppIcon-Tinted.png", tinted, "tinted"),
    ])

    red = stamp(solid(RED_LIGHT), (255, 255, 255), (255, 255, 255)).convert("RGB")

    alternates = {
        "Light": light,
        "Dark": dark,
        "Red": red,
        **{name: keycap(palette) for name, palette in KEYCAPS.items()},
    }
    for name, image in alternates.items():
        write_icon_set(f"AppIcon-{name}", [(f"AppIcon-{name}.png", image, None)])

    PREVIEWS.mkdir(exist_ok=True)
    write_json(PREVIEWS / "Contents.json", {"info": {"author": "xcode", "version": 1}})
    write_preview("System", light, dark)
    for name, image in alternates.items():
        write_preview(name, image)


if __name__ == "__main__":
    main()
