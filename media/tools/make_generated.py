"""Draws the two scenes that need no download: a slow starfield (space) and
soft floating shapes (shapes). Both loop seamlessly: every motion completes a
whole number of cycles in the loop length."""
import math
import random
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

SIZE = 240
FPS = 10
SECONDS = 5
FRAMES = FPS * SECONDS
OUT = Path(sys.argv[1] if len(sys.argv) > 1 else "out/video")


def save_gif(frames, name):
    # One shared adaptive palette keeps colours steady from frame to frame.
    pal = frames[0].convert("P", palette=Image.ADAPTIVE, colors=64)
    paletted = [f.quantize(palette=pal, dither=Image.Dither.NONE) for f in frames]
    path = OUT / f"{name}.gif"
    paletted[0].save(path, save_all=True, append_images=paletted[1:], duration=1000 // FPS, loop=0, optimize=True)
    print(f"video {name}: {path.stat().st_size // 1024}K")


def starfield():
    rng = random.Random(3)
    # Stars drift down and wrap around; each moves an exact number of screen
    # heights per loop, so frame N matches frame 0.
    stars = [
        dict(x=rng.uniform(0, SIZE), y=rng.uniform(0, SIZE),
             speed=rng.choice([1, 1, 1, 2]), r=rng.choice([0.8, 1, 1.2, 1.6]),
             tw=rng.uniform(0, math.tau), bright=rng.uniform(0.5, 1.0))
        for _ in range(110)
    ]
    frames = []
    for i in range(FRAMES):
        t = i / FRAMES
        img = Image.new("RGB", (SIZE, SIZE))
        d = ImageDraw.Draw(img)
        for y in range(SIZE):  # deep night gradient
            c = int(8 + 22 * y / SIZE)
            d.line([(0, y), (SIZE, y)], fill=(c // 3, c // 3, c))
        glow = Image.new("RGB", (SIZE, SIZE))
        gd = ImageDraw.Draw(glow)
        for s in stars:
            y = (s["y"] + s["speed"] * SIZE * t) % SIZE
            b = s["bright"] * (0.75 + 0.25 * math.sin(math.tau * t * 2 + s["tw"]))
            col = (int(200 * b), int(210 * b), int(255 * b))
            r = s["r"]
            gd.ellipse([s["x"] - r * 2, y - r * 2, s["x"] + r * 2, y + r * 2], fill=tuple(v // 3 for v in col))
            d.ellipse([s["x"] - r, y - r, s["x"] + r, y + r], fill=col)
        img = Image.blend(img, Image.composite(glow.filter(ImageFilter.GaussianBlur(2)), img, glow.convert("L")), 0.6)
        frames.append(img)
    save_gif(frames, "space")


def shapes():
    rng = random.Random(11)
    palette = [(86, 156, 214), (78, 201, 176), (197, 134, 192), (240, 200, 120), (120, 180, 120)]
    blobs = []
    for _ in range(9):
        blobs.append(dict(
            cx=rng.uniform(30, SIZE - 30), cy=rng.uniform(30, SIZE - 30),
            ax=rng.uniform(10, 30), ay=rng.uniform(10, 30),
            kx=rng.choice([1, 1, 2]), ky=rng.choice([1, 2]),  # whole cycles per loop
            ph=rng.uniform(0, math.tau), r=rng.uniform(16, 34),
            col=rng.choice(palette), kind=rng.choice(["circle", "circle", "rounded"]),
        ))
    frames = []
    for i in range(FRAMES):
        t = i / FRAMES
        img = Image.new("RGB", (SIZE, SIZE), (18, 22, 40))
        layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        d = ImageDraw.Draw(layer)
        for b in blobs:
            x = b["cx"] + b["ax"] * math.sin(math.tau * b["kx"] * t + b["ph"])
            y = b["cy"] + b["ay"] * math.cos(math.tau * b["ky"] * t + b["ph"])
            r = b["r"] * (0.92 + 0.08 * math.sin(math.tau * t + b["ph"]))
            box = [x - r, y - r, x + r, y + r]
            fill = b["col"] + (150,)
            if b["kind"] == "circle":
                d.ellipse(box, fill=fill)
            else:
                d.rounded_rectangle(box, radius=r * 0.4, fill=fill)
        layer = layer.filter(ImageFilter.GaussianBlur(1.5))
        img.paste(layer, (0, 0), layer)
        frames.append(img)
    save_gif(frames, "shapes")


OUT.mkdir(parents=True, exist_ok=True)
starfield()
shapes()
