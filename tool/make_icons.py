#!/usr/bin/env python3
"""Generate the launcher icon set.

A shield, matching the notification icon so the app reads the same in the shade and
on the home screen. The geometry is the same path as res/drawable/ic_tunnel.xml
rather than a lookalike, so the two cannot drift apart.

Kept to flat shapes with no thin strokes: a launcher icon is often drawn at 48px,
where fine detail turns to mush.

Android 8+ uses the adaptive pair (a solid background plus a foreground drawn inside
the 66/108 safe zone, since the system may mask it to any shape). API 24-25 predates
that and needs a complete square icon, so both are produced.

    python3 tool/make_icons.py
"""
from pathlib import Path

from PIL import Image, ImageDraw

BRAND = (76, 95, 213, 255)      # matches the app's ColorScheme seed
SHIELD = (255, 255, 255, 255)

RES = Path(__file__).resolve().parent.parent / "android/app/src/main/res"

# Launcher sizes per density, and the larger adaptive foreground canvas.
LAUNCHER = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FOREGROUND = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def _cubic(p0, p1, p2, p3, steps=24):
    """Samples one cubic bezier. PIL draws polygons, not curves."""
    points = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        points.append(
            (
                u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0],
                u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1],
            )
        )
    return points


# The outline from res/drawable/ic_tunnel.xml, in its 24x24 viewport:
#   M12,1 L3,5 v6 c0,5.55 3.84,10.74 9,12 c5.16,-1.26 9,-6.45 9,-12 V5 z
def _shield_points():
    points = [(12.0, 1.0), (3.0, 5.0), (3.0, 11.0)]
    points += _cubic((3, 11), (3, 16.55), (6.84, 21.74), (12, 23))[1:]
    points += _cubic((12, 23), (17.16, 21.74), (21, 16.55), (21, 11))[1:]
    points += [(21.0, 5.0)]
    return points


def draw_shield(size: int, scale: float) -> Image.Image:
    """Shield centred on a transparent canvas. `scale` is its height as a fraction."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)

    # The path spans y 1..23 and x 3..21 of a 24-unit box.
    span_y, span_x = 22.0, 18.0
    unit = size * scale / span_y
    offset_x = (size - span_x * unit) / 2 - 3 * unit
    offset_y = (size - span_y * unit) / 2 - 1 * unit

    draw.polygon(
        [(x * unit + offset_x, y * unit + offset_y) for x, y in _shield_points()],
        fill=SHIELD,
    )

    # A slim vertical bar reads as a tunnel through the shield, and is the only
    # detail that survives 48px. Anything finer turns to mush at that size.
    bar_w = span_x * unit * 0.14
    bar_top = 7.0 * unit + offset_y
    bar_bottom = 17.0 * unit + offset_y
    cx = 12.0 * unit + offset_x
    draw.rounded_rectangle(
        [cx - bar_w / 2, bar_top, cx + bar_w / 2, bar_bottom],
        radius=bar_w / 2,
        fill=BRAND,
    )
    return image


def write(image: Image.Image, density: str, name: str) -> None:
    target = RES / f"mipmap-{density}"
    target.mkdir(parents=True, exist_ok=True)
    image.save(target / f"{name}.png")


def main() -> None:
    for density, size in LAUNCHER.items():
        # Legacy square icon: background plus crown, rounded so it is not a hard box.
        legacy = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        ImageDraw.Draw(legacy).rounded_rectangle(
            [0, 0, size - 1, size - 1], radius=size * 0.22, fill=BRAND
        )
        legacy.alpha_composite(draw_shield(size, 0.60))
        write(legacy, density, "ic_launcher")

    for density, size in FOREGROUND.items():
        # Adaptive foreground: the shield must stay inside the 66/108 safe zone, so
        # it survives whatever mask the launcher applies.
        write(draw_shield(size, 0.42), density, "ic_launcher_foreground")

    values = RES / "values"
    values.mkdir(parents=True, exist_ok=True)
    (values / "ic_launcher_background.xml").write_text(
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<resources>\n"
        '    <color name="ic_launcher_background">#4C5FD5</color>\n'
        "</resources>\n"
    )

    adaptive = RES / "mipmap-anydpi-v26"
    adaptive.mkdir(parents=True, exist_ok=True)
    xml = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        '<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">\n'
        '    <background android:drawable="@color/ic_launcher_background" />\n'
        '    <foreground android:drawable="@mipmap/ic_launcher_foreground" />\n'
        '    <monochrome android:drawable="@mipmap/ic_launcher_foreground" />\n'
        "</adaptive-icon>\n"
    )
    (adaptive / "ic_launcher.xml").write_text(xml)
    (adaptive / "ic_launcher_round.xml").write_text(xml)

    print("icons written to", RES)


if __name__ == "__main__":
    main()
