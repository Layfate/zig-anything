"""Render docs/assets/demo.gif: a side-by-side race of an original function
and its Zig port, using numbers measured with `zig-anything bench`.

usage: python scripts/make_demo_gif.py      (needs Pillow; fonts default to Windows paths)

The timings are measurements, not illustrations. The animation plays 10x
slower than real time so a run that takes milliseconds stays visible.
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

# ---- measured data (examples/levenshtein-py, `zig-anything bench levenshtein`)
CASES = 253
ORIGINAL_MS = 134.6  # one process, every case once
PORT_MS = 6.5
PER_CALL_SPEEDUP = 164  # 51.1 us -> 0.31 us per call
SLOWDOWN = 10  # animation plays 10x slower than real time

# ---- look
W, H = 960, 392
FPS = 30
BG = (13, 17, 23)
PANEL = (17, 22, 29)
CARD = (22, 27, 34)
BORDER = (48, 54, 61)
BORDER_HOT = (247, 164, 29)
TEXT = (230, 237, 243)
DIM = (139, 148, 158)
ORANGE = (247, 164, 29)
GRAY_BAR = (139, 148, 158)
TRACK = (48, 54, 61)
GREEN = (63, 185, 80)

FONT_DIR = os.environ.get("FONT_DIR", r"C:\Windows\Fonts")


def font(name, size):
    return ImageFont.truetype(os.path.join(FONT_DIR, name), size)


F_TITLE = font("seguisb.ttf", 21)
F_HEAD = font("segoeuib.ttf", 21)
F_SMALL = font("segoeui.ttf", 14)
F_MONO = font("consola.ttf", 15)
F_BIG = font("consolab.ttf", 58)
F_BODY = font("segoeui.ttf", 15)
F_FOOT = font("segoeui.ttf", 17)
F_FOOT_B = font("seguisb.ttf", 17)
F_CHECK = font("seguisym.ttf", 16)
F_TINY = font("segoeui.ttf", 12)


def text_w(d, s, f):
    return d.textlength(s, font=f)


def draw_runs(d, x, y, runs):
    """Draw a sequence of (text, font, color) left to right."""
    for s, f, c in runs:
        d.text((x, y), s, font=f, fill=c)
        x += text_w(d, s, f)


def centered_runs(d, y, runs):
    total = sum(text_w(d, s, f) for s, f, _ in runs)
    draw_runs(d, (W - total) / 2, y, runs)


def fmt_ms(ms):
    return f"{ms:6.1f} ms".lstrip()


def card(d, x, y, w, h, title, tag, cmd, elapsed_ms, total_ms, color, hot):
    d.rounded_rectangle((x, y, x + w, y + h), radius=14, fill=CARD, outline=BORDER_HOT if hot else BORDER, width=2 if hot else 1)
    d.text((x + 22, y + 18), title, font=F_HEAD, fill=TEXT)
    d.text((x + w - 22 - text_w(d, tag, F_SMALL), y + 23), tag, font=F_SMALL, fill=DIM)
    d.text((x + 22, y + 54), "$ " + cmd, font=F_MONO, fill=DIM)
    done = elapsed_ms >= total_ms
    shown = min(elapsed_ms, total_ms)
    d.text((x + 20, y + 76), fmt_ms(shown), font=F_BIG, fill=color if color != GRAY_BAR else TEXT)
    frac = shown / total_ms
    d.text((x + 22, y + 146), f"{round(CASES * frac)} / {CASES} cases", font=F_BODY, fill=DIM)
    bx0, by0, bx1 = x + 22, y + 176, x + w - 22
    d.rounded_rectangle((bx0, by0, bx1, by0 + 12), radius=6, fill=TRACK)
    if frac > 0:
        d.rounded_rectangle((bx0, by0, bx0 + max(12, (bx1 - bx0) * frac), by0 + 12), radius=6, fill=color)
    if done:
        d.text((x + 22, y + 198), "\u2713", font=F_CHECK, fill=GREEN)
        d.text((x + 42, y + 198), "done", font=F_BODY, fill=TEXT)


def frame(t_anim):
    """t_anim: seconds of animation time since the race started (may be < 0)."""
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((8, 8, W - 8, H - 8), radius=18, fill=PANEL, outline=BORDER)
    centered_runs(d, 26, [
        ("Levenshtein distance, ported from Python to Zig with ", F_TITLE, TEXT),
        ("zig-anything", F_TITLE, ORANGE),
    ])
    elapsed = max(0.0, t_anim) * 1000 / SLOWDOWN  # real milliseconds
    cw, ch, gap = 430, 236, 36
    x0 = (W - (2 * cw + gap)) / 2
    card(d, x0, 70, cw, ch, "Python", "Python 3.12", "python textdist.py", elapsed, ORIGINAL_MS, GRAY_BAR, False)
    card(d, x0 + cw + gap, 70, cw, ch, "Zig port", "one binary", "harness run cases.jsonl", elapsed, PORT_MS, ORANGE, True)
    if elapsed >= ORIGINAL_MS:
        centered_runs(d, 318, [
            (f"Same result on all {CASES} recorded cases:  ", F_FOOT, DIM),
            (f"{ORIGINAL_MS / PORT_MS:.1f}x faster", F_FOOT_B, ORANGE),
            (" end to end,  ", F_FOOT, DIM),
            (f"{PER_CALL_SPEEDUP}x", F_FOOT_B, ORANGE),
            (" per call", F_FOOT, DIM),
        ])
    note = f"animation slowed {SLOWDOWN}x  \u00b7  measured on Ryzen 7 5700X"
    d.text(((W - text_w(d, note, F_TINY)) / 2, H - 38), note, font=F_TINY, fill=(88, 96, 105))
    return img


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join("docs", "assets", "demo.gif")
    lead, run_s, hold = 0.6, ORIGINAL_MS * SLOWDOWN / 1000 + 0.1, 3.5
    frames, durations = [], []
    n = int((lead + run_s) * FPS)
    for i in range(n):
        frames.append(frame(i / FPS - lead))
        durations.append(round(1000 / FPS))
    frames.append(frame(run_s + 1))  # final frame, held
    durations.append(int(hold * 1000))
    # One shared palette keeps the file small and the colors stable.
    palette_src = frames[-1].quantize(colors=96, method=Image.Quantize.MEDIANCUT)
    pal = [f.quantize(palette=palette_src, dither=Image.Dither.NONE) for f in frames]
    pal[0].save(out, save_all=True, append_images=pal[1:], duration=durations, loop=0, optimize=True, disposal=1)
    print(f"wrote {out}: {len(frames)} frames, {os.path.getsize(out) // 1024} KB")


if __name__ == "__main__":
    main()
