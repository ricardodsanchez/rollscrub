#!/usr/bin/env python3
"""Draws the RollScrub app icon and packages it as an .icns.

    python3 icon/make-icon.py

Two photographs stacked with an offset: the duplicate behind, dimmed, and the
one being kept in front. The palette is the site's — darkroom charcoal ground,
chinagraph amber — so the app and its page read as the same product.

Everything is drawn at 4x and downsampled, because PIL's shape drawing is
aliased and a 1024px icon shows every jagged edge on a Retina display.
"""

from pathlib import Path
import subprocess
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 4  # supersample factor
SIZE = 1024 * S

# Darkroom palette, matched to the site's dark theme.
GROUND_TOP = (34, 30, 26)
GROUND_BOTTOM = (14, 12, 11)
AMBER = (232, 131, 58)
AMBER_DIM = (150, 84, 37)
BACK_FILL = (46, 42, 38)
BACK_EDGE = (74, 68, 60)
PAPER = (237, 234, 228)
SKY = (86, 104, 118)
HILL = (48, 60, 60)


def rounded(draw, box, radius, **kw):
    draw.rounded_rectangle(box, radius=radius, **kw)


def build() -> Image.Image:
    img = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # --- ground -----------------------------------------------------------
    # Big Sur onward, the artwork sits in a rounded square inset from the
    # canvas rather than filling it; matching that keeps it the same visual
    # weight as every other icon in the Dock.
    inset = int(SIZE * 0.098)
    box = (inset, inset, SIZE - inset, SIZE - inset)
    radius = int(SIZE * 0.185)

    ground = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    gd = ImageDraw.Draw(ground)
    height = box[3] - box[1]
    for y in range(height):
        t = y / max(height - 1, 1)
        gd.line(
            [(box[0], box[1] + y), (box[2], box[1] + y)],
            fill=tuple(
                int(GROUND_TOP[i] + (GROUND_BOTTOM[i] - GROUND_TOP[i]) * t)
                for i in range(3)
            ) + (255,),
        )
    mask = Image.new("L", (SIZE, SIZE), 0)
    rounded(ImageDraw.Draw(mask), box, radius, fill=255)
    img.paste(ground, (0, 0), mask)

    # A single hairline of light along the top edge: without it the ground
    # reads as flat paint rather than a lit surface.
    sheen = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded(
        ImageDraw.Draw(sheen), box, radius,
        outline=(255, 255, 255, 26), width=int(3 * S),
    )
    img.alpha_composite(sheen)

    # --- the duplicate, behind -------------------------------------------
    fw, fh = int(SIZE * 0.44), int(SIZE * 0.365)
    frame_r = int(SIZE * 0.030)
    # Nudged up and left of true centre: the front photograph is far heavier
    # visually, so centring the pair geometrically leaves it sitting low-right.
    cx, cy = SIZE // 2 - int(SIZE * 0.012), SIZE // 2 - int(SIZE * 0.014)
    off = int(SIZE * 0.058)

    back = (cx - fw // 2 - off, cy - fh // 2 - off,
            cx + fw // 2 - off, cy + fh // 2 - off)
    rounded(d, back, frame_r, fill=BACK_FILL + (255,),
            outline=BACK_EDGE + (255,), width=int(5 * S))

    # The back frame carries a dimmed copy of the same photograph, so it reads
    # as a second picture rather than an empty box or a drop shadow.
    bpad = int(9 * S)
    binner = (back[0] + bpad, back[1] + bpad, back[2] - bpad, back[3] - bpad)
    dim = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    dd = ImageDraw.Draw(dim)
    dd.rectangle(binner, fill=(60, 66, 70, 255))
    bh = binner[1] + int((binner[3] - binner[1]) * 0.60)
    dd.polygon(
        [(binner[0], binner[3]), (binner[0], bh + int(20 * S)),
         (binner[0] + (binner[2] - binner[0]) * 0.42, bh - int(24 * S)),
         (binner[2], bh + int(26 * S)), (binner[2], binner[3])],
        fill=(44, 50, 50, 255),
    )
    bmask = Image.new("L", (SIZE, SIZE), 0)
    rounded(ImageDraw.Draw(bmask), binner, int(frame_r * 0.55), fill=255)
    img.paste(dim, (0, 0), bmask)

    # --- the one being kept, in front ------------------------------------
    front = (cx - fw // 2 + off, cy - fh // 2 + off,
             cx + fw // 2 + off, cy + fh // 2 + off)

    shadow = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    rounded(
        ImageDraw.Draw(shadow),
        (front[0], front[1] + int(10 * S), front[2], front[3] + int(10 * S)),
        frame_r, fill=(0, 0, 0, 150),
    )
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(int(14 * S))))

    rounded(d, front, frame_r, fill=PAPER + (255,))

    # The photograph inside it: sky, hill, sun. Abstract enough to stay
    # legible at 16px, specific enough to read as a photo and not a document.
    pad = int(10 * S)
    inner = (front[0] + pad, front[1] + pad, front[2] - pad, front[3] - pad)
    inner_r = int(frame_r * 0.55)

    photo = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    pd = ImageDraw.Draw(photo)
    pd.rectangle(inner, fill=SKY + (255,))
    hill_top = inner[1] + int((inner[3] - inner[1]) * 0.58)
    pd.polygon(
        [(inner[0], inner[3]), (inner[0], hill_top + int(26 * S)),
         (inner[0] + (inner[2] - inner[0]) * 0.38, hill_top - int(30 * S)),
         (inner[0] + (inner[2] - inner[0]) * 0.62, hill_top + int(24 * S)),
         (inner[0] + (inner[2] - inner[0]) * 0.80, hill_top - int(12 * S)),
         (inner[2], hill_top + int(30 * S)), (inner[2], inner[3])],
        fill=HILL + (255,),
    )
    sun_r = int(SIZE * 0.026)
    sun_c = (inner[0] + (inner[2] - inner[0]) * 0.74,
             inner[1] + (inner[3] - inner[1]) * 0.27)
    pd.ellipse(
        [sun_c[0] - sun_r, sun_c[1] - sun_r, sun_c[0] + sun_r, sun_c[1] + sun_r],
        fill=AMBER + (255,),
    )

    pmask = Image.new("L", (SIZE, SIZE), 0)
    rounded(ImageDraw.Draw(pmask), inner, inner_r, fill=255)
    img.paste(photo, (0, 0), pmask)

    return img.resize((1024, 1024), Image.LANCZOS)


def main() -> int:
    here = Path(__file__).resolve().parent
    master = build()
    png = here / "RollScrub-1024.png"
    master.save(png)

    iconset = here / "RollScrub.iconset"
    if iconset.exists():
        for f in iconset.iterdir():
            f.unlink()
    iconset.mkdir(exist_ok=True)

    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            suffix = "" if scale == 1 else "@2x"
            master.resize((px, px), Image.LANCZOS).save(
                iconset / f"icon_{base}x{base}{suffix}.png"
            )

    icns = here / "RollScrub.icns"
    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(icns)], check=True
    )
    print(f"wrote {icns.relative_to(here.parent)} and {png.relative_to(here.parent)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
