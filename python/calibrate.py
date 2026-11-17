"""Generate a calibration target to measure how much the QX20 crops at each edge.

Usage:
    python calibrate.py [card|square] [out.png]

Print it with:  python qx20.py out.png --paper card --mode stretch
Then look at each edge: the first fully visible numbered band tells you
how many mm are lost on that side.
"""
import sys
from PIL import Image, ImageDraw, ImageFont

from qx20 import PAPERS, QX20_DPI

COLORS = [(230, 30, 30), (255, 150, 0), (240, 210, 0), (40, 170, 60),
          (30, 120, 230), (130, 60, 200), (0, 0, 0)]


def px(mm: float) -> int:
    return round(mm / 25.4 * QX20_DPI)


def font(size):
    for f in ("/System/Library/Fonts/Supplemental/Arial Bold.ttf",
              "/System/Library/Fonts/Helvetica.ttc"):
        try:
            return ImageFont.truetype(f, size)
        except OSError:
            pass
    return ImageFont.load_default()


def make(paper: str) -> Image.Image:
    prof = PAPERS[paper]
    w, h = prof["width"], prof["height"]
    im = Image.new("RGB", (w, h), "white")
    d = ImageDraw.Draw(im)
    small = font(px(0.95))
    label = font(px(1.6))

    # Bands: 0-1mm, 1-2mm, ... 6-7mm from every edge, each its own color.
    for i, c in enumerate(COLORS):
        a, b = px(i), px(i + 1)
        d.rectangle([a, a, w - 1 - a, h - 1 - a], outline=c, width=b - a)
    # Labels inside each band (mm already lost if this number is missing)
    for i in range(len(COLORS)):
        mid = (px(i) + px(i + 1)) // 2
        t = str(i + 1)
        for x, y in ((w // 2, mid), (w // 2, h - 1 - mid), (mid, h // 2), (w - 1 - mid, h // 2)):
            d.text((x, y), t, fill="white", font=small, anchor="mm")

    # 1 mm ruler, 30 mm long, horizontal and vertical, to verify the DPI
    cx, cy = w // 2, h // 2
    big = font(px(2.5))
    x0 = cx - px(15)
    d.line([x0, cy, x0 + px(30), cy], fill="black", width=2)
    for m in range(31):
        x = x0 + px(m)
        L = px(2 if m % 10 == 0 else 1.2 if m % 5 == 0 else 0.7)
        d.line([x, cy - L, x, cy], fill="black", width=1)
    y0 = cy + px(4)
    d.line([cx, y0, cx, y0 + px(20)], fill="black", width=2)
    for m in range(21):
        y = y0 + px(m)
        L = px(2 if m % 10 == 0 else 1.2 if m % 5 == 0 else 0.7)
        d.line([cx, y, cx + L, y], fill="black", width=1)

    d.text((cx, cy - px(8)), f"QX20 {paper.upper()} {w}x{h}", fill="black", font=big, anchor="mm")
    d.text((cx, cy - px(4.5)), "ruler: 30 mm / 20 mm", fill="black", font=label, anchor="mm")
    d.text((cx, px(10)), "TOP", fill="black", font=big, anchor="mm")
    return im


if __name__ == "__main__":
    paper = sys.argv[1] if len(sys.argv) > 1 else "card"
    out = sys.argv[2] if len(sys.argv) > 2 else f"calibration_{paper}.png"
    make(paper).save(out)
    print(f"saved {out}")
