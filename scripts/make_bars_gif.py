"""Render docs/assets/bars.gif: animated bar charts comparing an original
function with its Zig port on memory and time.

usage: python scripts/make_bars_gif.py      (needs Pillow; fonts default to Windows paths)

Every number below is a measurement from examples/fuzzy-js on a Ryzen 7
5700X, Windows 11, Node.js 24.21 (medians):
  peak memory, one process        bench/peakmem.py --runs 15 -- <cmd>
  one process, all 288 cases      bench/peakmem.py --runs 15 -- <cmd>
  per call, after warm-up         zig-anything bench fuzzyScore
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

SECTIONS = [
    ("Peak memory", [("Node", 47.2), ("Zig port", 4.1)], "{:.1f} MB"),
    ("One process, all 288 cases", [("Node", 40.7), ("Zig port", 5.6)], "{:.1f} ms"),
    ("Per call, after warm-up", [("Node (V8 JIT)", 61.3), ("Zig port", 31.6)], "{:.1f} ns"),
]
FOOTER = "288 / 288 outputs byte-identical to the Node original"

W = 960
FPS = 30
BG = (13, 17, 23)
PANEL = (17, 22, 29)
CARD = (22, 27, 34)
BORDER = (48, 54, 61)
TEXT = (230, 237, 243)
DIM = (139, 148, 158)
ORANGE = (247, 164, 29)
GRAY = (139, 148, 158)
TRACK = (33, 38, 45)

FONT_DIR = os.environ.get("FONT_DIR", r"C:\Windows\Fonts")


def font(name, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)


F_TITLE = font("seguisb.ttf", 21)
F_SECTION = font("segoeuib.ttf", 16)
F_LABEL = font("segoeui.ttf", 15)
F_VALUE = font("consolab.ttf", 18)
F_FOOT = font("seguisb.ttf", 16)
F_TINY = font("segoeui.ttf", 12)

SECTION_H = 112
TOP = 70
H = TOP + len(SECTIONS) * (SECTION_H + 14) + 70


def ease_out(t):
    t = min(max(t, 0.0), 1.0)
    return 1 - (1 - t) ** 3


def tw(d, s, f):
    return d.textlength(s, font=f)


def frame(t):
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((8, 8, W - 8, H - 8), radius=18, fill=PANEL, outline=BORDER)
    runs = [("fuzzyScore, a JavaScript function, ported to Zig with ", TEXT), ("zig-anything", ORANGE)]
    x = (W - sum(tw(d, s, F_TITLE) for s, _ in runs)) / 2
    for s, c in runs:
        d.text((x, 24), s, font=F_TITLE, fill=c)
        x += tw(d, s, F_TITLE)

    for i, (title, rows, fmt) in enumerate(SECTIONS):
        y = TOP + i * (SECTION_H + 14)
        d.rounded_rectangle((32, y, W - 32, y + SECTION_H), radius=12, fill=CARD, outline=BORDER)
        d.text((52, y + 14), title, font=F_SECTION, fill=TEXT)
        top = max(v for _, v in rows)
        # Sections animate one after another.
        p = ease_out((t - 0.25 * i) / 0.9)
        for j, (label, value) in enumerate(rows):
            ry = y + 48 + j * 30
            port = j == len(rows) - 1
            d.text((52, ry), label, font=F_LABEL, fill=DIM)
            bx0, bx1 = 190, W - 170
            d.rounded_rectangle((bx0, ry + 3, bx1, ry + 19), radius=5, fill=TRACK)
            width = (bx1 - bx0) * value / top * p
            if width > 1:
                d.rounded_rectangle((bx0, ry + 3, bx0 + max(10, width), ry + 19), radius=5, fill=ORANGE if port else GRAY)
            shown = fmt.format(value * p)
            d.text((W - 52 - tw(d, shown, F_VALUE), ry), shown, font=F_VALUE, fill=ORANGE if port else TEXT)

    if t > 0.25 * (len(SECTIONS) - 1) + 0.9:
        fy = TOP + len(SECTIONS) * (SECTION_H + 14) + 4
        d.text(((W - tw(d, FOOTER, F_FOOT)) / 2, fy), FOOTER, font=F_FOOT, fill=DIM)
    note = "measured on Ryzen 7 5700X  \u00b7  Windows 11  \u00b7  Node.js 24  \u00b7  medians"
    d.text(((W - tw(d, note, F_TINY)) / 2, H - 34), note, font=F_TINY, fill=(88, 96, 105))
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join("docs", "assets", "bars.gif")
    lead, anim, hold = 0.4, 0.25 * (len(SECTIONS) - 1) + 1.0, 4.0
    frames, durations = [], []
    for k in range(int((lead + anim) * FPS)):
        frames.append(frame(k / FPS - lead))
        durations.append(round(1000 / FPS))
    frames.append(frame(anim + 1))
    durations.append(int(hold * 1000))
    palette = frames[-1].quantize(colors=96, method=Image.Quantize.MEDIANCUT)
    pal = [f.quantize(palette=palette, dither=Image.Dither.NONE) for f in frames]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"wrote {out}: {len(frames)} frames, {os.path.getsize(out) // 1024} KB")


if __name__ == "__main__":
    main()
