# App icon "Chuyển dữ liệu" in the clay style: lavender-blue gradient, two soft white phones, swap arrows.
# Usage: python3 tool/make_icon.py   (needs Pillow). Writes assets/icon/*.png and a masked preview.
from PIL import Image, ImageDraw, ImageFilter
import os
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'icon')
S = 1024
SS = 4  # supersampling

def gradient(size):
    w = h = size
    img = Image.new('RGB', (w, h))
    a, b = (0x8A, 0xA3, 0xFF), (0x5E, 0x7C, 0xF2)
    px = img.load()
    for y in range(h):
        for x in range(w):
            t = (x + y) / (2 * (w - 1))
            px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    return img

def art(size, scale=1.0):
    """Transparent RGBA layer with the two phones + arrows, content centred, scaled by `scale`."""
    n = size * SS
    lay = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    c = n / 2
    u = n / 1024 * scale  # design unit
    # phone geometry (in 1024 units, centred)
    pw, ph, r = 250, 440, 58
    gap = 70
    phones = [(c - gap / 2 * u - pw * u, c - ph / 2 * u), (c + gap / 2 * u, c - ph / 2 * u)]
    # soft drop shadow
    sh = Image.new('RGBA', (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(sh)
    for (x, y) in phones:
        d.rounded_rectangle([x + 18 * u, y + 26 * u, x + pw * u + 18 * u, y + ph * u + 26 * u], radius=r * u, fill=(30, 40, 120, 90))
    sh = sh.filter(ImageFilter.GaussianBlur(28 * u))
    lay.alpha_composite(sh)
    d = ImageDraw.Draw(lay)
    for k, (x, y) in enumerate(phones):
        d.rounded_rectangle([x, y, x + pw * u, y + ph * u], radius=r * u, fill=(255, 255, 255, 255))
        # screen (pressed, very light lavender)
        m = 22 * u
        d.rounded_rectangle([x + m, y + m + 26 * u, x + pw * u - m, y + ph * u - m - 30 * u], radius=34 * u, fill=(0xE4, 0xEA, 0xFF, 255))
        # speaker slot
        d.rounded_rectangle([x + pw * u / 2 - 34 * u, y + 20 * u, x + pw * u / 2 + 34 * u, y + 30 * u], radius=5 * u, fill=(0xC9, 0xD2, 0xF2, 255))
    # arrows across the gap, drawn over the phones' screens
    col = (0x4E, 0x6B, 0xE6, 255)
    lw = 34 * u
    def arrow(y, left_to_right):
        x0, x1 = c - 150 * u, c + 150 * u
        if not left_to_right:
            x0, x1 = x1, x0
        d.line([(x0, y), (x1, y)], fill=col, width=int(lw))
        for xx in (x0,):
            d.ellipse([xx - lw / 2, y - lw / 2, xx + lw / 2, y + lw / 2], fill=col)
        sgn = 1 if left_to_right else -1
        tip = x1 + sgn * 34 * u
        d.polygon([(tip, y), (x1 - sgn * 40 * u, y - 62 * u), (x1 - sgn * 40 * u, y + 62 * u)], fill=col)
    arrow(c - 70 * u, True)
    arrow(c + 70 * u, False)
    return lay.resize((size, size), Image.LANCZOS)

bg = gradient(S)
full = bg.convert('RGBA')
full.alpha_composite(art(S, 1.25))
full.convert('RGB').save(os.path.join(OUT, 'icon.png'))            # iOS + legacy Android (no alpha)
art(S, 0.83).save(os.path.join(OUT, 'foreground.png'))             # adaptive foreground: inside the 61% circle-safe zone
bg.save(os.path.join(OUT, 'background.png'))                        # adaptive background
# preview: how launchers mask it
prev = Image.new('RGBA', (3 * 300 + 80, 380), (0xE9, 0xEE, 0xF6, 255))
ic = full.resize((300, 300), Image.LANCZOS)
def mask(shape):
    mk = Image.new('L', (300, 300), 0)
    md = ImageDraw.Draw(mk)
    if shape == 'circle':
        md.ellipse([0, 0, 299, 299], fill=255)
    else:
        md.rounded_rectangle([0, 0, 299, 299], radius=66 if shape == 'ios' else 90, fill=255)
    return mk
for i, shape in enumerate(['ios', 'circle', 'squircle']):
    prev.paste(ic, (20 + i * 320, 40), mask(shape))
prev.convert('RGB').save(os.path.join(OUT, 'preview.png'))
print('ok')
