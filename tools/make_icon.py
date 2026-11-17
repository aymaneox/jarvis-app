import math
import os

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
BG = (6, 18, 28)
CYAN = (0, 220, 255)
CORE = (190, 250, 255)


def reactor(scale):
    """Draws the Jarvis arc-reactor symbol on a transparent layer."""
    layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    c = SIZE // 2
    r = int(SIZE * 0.5 * scale)

    # outer ring
    d.ellipse([c - r, c - r, c + r, c + r], outline=CYAN + (255,), width=max(6, int(r * 0.06)))

    # ring of 12 segments
    r2 = int(r * 0.78)
    for i in range(12):
        a0 = i * 30 + 4
        a1 = i * 30 + 26
        d.arc([c - r2, c - r2, c + r2, c + r2], a0, a1, fill=CYAN + (255,), width=max(6, int(r * 0.09)))

    # middle thin ring
    r3 = int(r * 0.58)
    d.ellipse([c - r3, c - r3, c + r3, c + r3], outline=CYAN + (200,), width=max(4, int(r * 0.03)))

    # triangle
    r4 = int(r * 0.46)
    pts = [(c + r4 * math.cos(math.radians(a)), c + r4 * math.sin(math.radians(a)))
           for a in (-90, 30, 150)]
    d.polygon(pts, outline=CYAN + (255,), width=max(5, int(r * 0.045)))

    # glowing core
    r5 = int(r * 0.14)
    d.ellipse([c - r5, c - r5, c + r5, c + r5], fill=CORE + (255,))

    glow = layer.filter(ImageFilter.GaussianBlur(int(r * 0.07)))
    out = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
    out = Image.alpha_composite(out, glow)
    out = Image.alpha_composite(out, layer)
    return out


def main():
    os.makedirs("assets", exist_ok=True)

    # full icon: dark background + symbol
    bg = Image.new("RGBA", (SIZE, SIZE), BG + (255,))
    full = Image.alpha_composite(bg, reactor(0.78))
    full.convert("RGB").save("assets/icon.png")

    # adaptive foreground: transparent, symbol inside the safe zone
    reactor(0.56).save("assets/icon_fg.png")
    print("icons created")


if __name__ == "__main__":
    main()
