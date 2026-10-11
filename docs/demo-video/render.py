"""Renders the Ebb demo video scenes (1920x1080 PNG frames) from real app data.

Run from docs/demo-video/: python3 render.py  -> build/scenes/<n>/*.png
Then make.sh turns them into the MP4 with the voiceover in build/vo/.
"""
import json, math, os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont, ImageSequence

W, H = 1920, 1080
OUT = "build/scenes"
APPUI = sys.argv[1] if len(sys.argv) > 1 else "appui"

CREAM, CARD, BORDER = (239, 242, 229), (250, 250, 242), (201, 207, 185)
INK, SOFT = (43, 58, 44), (107, 115, 102)
TEAL, TEAL_T, TEAL_B = (33, 101, 122), (82, 160, 179), (25, 76, 96)
H_TOP, H_BOT = (240, 246, 221), (171, 191, 141)
CHIP, CHIPT, PREV = (225, 240, 242), (36, 89, 107), (220, 235, 241)
GREEN, AMBER, RED = (102, 180, 92), (232, 176, 60), (214, 92, 72)

SF = "/System/Library/Fonts/SFNS.ttf"
SFR = "/System/Library/Fonts/SFNSRounded.ttf"


def font(size, rounded=False, weight=None):
    f = ImageFont.truetype(SFR if rounded else SF, size)
    if weight:
        try:
            f.set_variation_by_name(weight)
        except Exception:
            pass
    return f


def vgrad(w, h, top, bot):
    g = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        g.putpixel((0, y), tuple(int(top[i] + (bot[i] - top[i]) * t) for i in range(3)))
    return g.resize((w, h))


def rounded(img, r):
    m = Image.new("L", img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], r, fill=255)
    out = Image.new("RGBA", img.size)
    out.paste(img, (0, 0), m)
    return out


def shadow_paste(base, img, xy, r=40, blur=30, alpha=70):
    sh = Image.new("RGBA", (img.size[0] + blur * 4, img.size[1] + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(sh).rounded_rectangle([blur * 2, blur * 2 + 12, blur * 2 + img.size[0], blur * 2 + img.size[1] + 12], r,
                                         fill=(0, 0, 0, alpha))
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(sh, (xy[0] - blur * 2, xy[1] - blur * 2))
    base.alpha_composite(img, xy)


def wrap(d, text, f, width):
    lines, cur = [], ""
    for word in text.split():
        t = (cur + " " + word).strip()
        if d.textlength(t, font=f) <= width:
            cur = t
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def text_block(d, x, y, text, f, fill, width, gap=10):
    for para in text.split("\n"):
        for line in wrap(d, para, f, width):
            d.text((x, y), line, font=f, fill=fill)
            y += f.size + gap
    return y


def background():
    bg = Image.new("RGBA", (W, H), CREAM + (255,))
    return bg


def side_caption(bg, kicker, title, body):
    d = ImageDraw.Draw(bg)
    x, y = 140, 250
    d.text((x, y), kicker.upper(), font=font(30, weight="Semibold"), fill=TEAL)
    y += 60
    y = text_block(d, x, y, title, font(68, weight="Semibold"), INK, 820, 12) + 24
    text_block(d, x, y, body, font(36), SOFT, 780, 14)


# ---------------------------------------------------------------- watch
WATCH = 560


def watch_frame(screen):
    """screen: RGBA 440x440 -> watch with bezel and strap, RGBA."""
    w = Image.new("RGBA", (WATCH, WATCH + 360), (0, 0, 0, 0))
    d = ImageDraw.Draw(w)
    d.rounded_rectangle([110, 0, WATCH - 110, 230], 40, fill=(58, 66, 60))
    d.rounded_rectangle([110, WATCH + 130, WATCH - 110, WATCH + 360], 40, fill=(58, 66, 60))
    d.rounded_rectangle([0, 180, WATCH, 180 + WATCH], 110, fill=(30, 32, 34))
    d.rounded_rectangle([14, 194, WATCH - 14, 166 + WATCH], 100, fill=(12, 12, 14))
    d.rounded_rectangle([WATCH - 6, 380, WATCH + 10, 470], 6, fill=(70, 74, 72))
    w.alpha_composite(rounded(screen.convert("RGBA"), 70), (60, 240))
    return w


def scene_watch(bg, screen, x=1120, y=40):
    shadow_paste(bg, watch_frame(screen), (x, y), r=110)


def home_screen(level):
    s = Image.new("RGBA", (440, 440), (0, 0, 0, 255))
    d = ImageDraw.Draw(s)
    d.text((220, 70), "10:42", font=font(56, rounded=True, weight="Semibold"), fill=(235, 240, 235), anchor="mm")
    d.rounded_rectangle([90, 160, 350, 260], 50, fill=TEAL)
    d.text((220, 210), "Start calm", font=font(36, rounded=True, weight="Semibold"), fill="white", anchor="mm")
    col = GREEN if level < 0.6 else AMBER if level < 1.0 else RED
    d.rounded_rectangle([60, 380, 380, 396], 8, fill=(40, 44, 42))
    d.rounded_rectangle([60, 380, 60 + max(16, int(320 * min(level, 1.5) / 1.5)), 396], 8, fill=col)
    label = "settled" if level < 0.6 else "rising" if level < 1.0 else "calm mode"
    d.text((220, 340), f"agitation {level:.2f} · {label}", font=font(24, rounded=True), fill=(170, 180, 170), anchor="mm")
    return s


def buzz_screen():
    s = Image.new("RGBA", (440, 440), (8, 22, 30, 255))
    d = ImageDraw.Draw(s)
    for r, a in [(170, 40), (130, 80), (90, 160)]:
        d.ellipse([220 - r, 190 - r, 220 + r, 190 + r], outline=TEAL_T + (a,), width=6)
    d.ellipse([175, 145, 265, 235], fill=TEAL_T)
    d.text((220, 360), "Breathe with me", font=font(34, rounded=True, weight="Semibold"), fill=(220, 235, 240), anchor="mm")
    d.text((220, 400), "gentle buzz on the wrist", font=font(22, rounded=True), fill=(140, 170, 180), anchor="mm")
    return s


def faces_screen(pick=None):
    s = Image.new("RGBA", (440, 440), (0, 0, 0, 255))
    d = ImageDraw.Draw(s)
    d.text((220, 70), "How do you feel?", font=font(32, rounded=True, weight="Semibold"), fill="white", anchor="mm")
    cols = [(110, 190, 100), (230, 196, 70), (160, 130, 200)]
    labels = ["Better", "Same", "Worse"]
    for i, (c, lab) in enumerate(zip(cols, labels)):
        cx, cy, r = 80 + i * 140, 210, 58
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=c, outline="white" if pick == i else None, width=6)
        d.ellipse([cx - 22, cy - 18, cx - 10, cy - 6], fill=(30, 30, 30))
        d.ellipse([cx + 10, cy - 18, cx + 22, cy - 6], fill=(30, 30, 30))
        if i == 0:
            d.arc([cx - 26, cy - 8, cx + 26, cy + 30], 20, 160, fill=(30, 30, 30), width=5)
        elif i == 1:
            d.line([cx - 22, cy + 18, cx + 22, cy + 18], fill=(30, 30, 30), width=5)
        else:
            d.arc([cx - 26, cy + 14, cx + 26, cy + 50], 200, 340, fill=(30, 30, 30), width=5)
        d.text((cx, cy + 90), lab, font=font(24, rounded=True), fill=(220, 220, 220), anchor="mm")
    d.rounded_rectangle([60, 400, 380, 410], 5, fill=(50, 50, 50))
    d.rounded_rectangle([60, 400, 260, 410], 5, fill=(150, 150, 150))
    return s


def calm_frames():
    gif = Image.open("../../media/out/video/ocean.gif")
    frames = [f.convert("RGBA").resize((440, 440)) for f in ImageSequence.Iterator(gif)]
    out = []
    for i in range(min(len(frames), 120)):
        f = frames[i % len(frames)].copy()
        d = ImageDraw.Draw(f)
        t = (math.sin(i / 120 * 2 * math.pi * 2 - math.pi / 2) + 1) / 2
        r = int(60 + 70 * t)
        ov = Image.new("RGBA", f.size, (0, 0, 0, 0))
        ImageDraw.Draw(ov).ellipse([220 - r, 200 - r, 220 + r, 200 + r], fill=(220, 240, 245, 90), outline=(255, 255, 255, 200), width=4)
        f.alpha_composite(ov)
        d = ImageDraw.Draw(f)
        d.text((220, 380), "Breathe in" if t > 0.5 else "Breathe out", font=font(30, rounded=True, weight="Semibold"),
               fill="white", anchor="mm", stroke_width=2, stroke_fill=(0, 0, 0))
        out.append(f)
    return out


# ---------------------------------------------------------------- phone
PW, PH = 470, 960


def phone(title, draw_body):
    p = Image.new("RGBA", (PW, PH), CREAM + (255,))
    p.paste(vgrad(PW, 130, H_TOP, H_BOT), (0, 0))
    d = ImageDraw.Draw(p)
    d.text((PW // 2, 92), title, font=font(26, weight="Bold"), fill=INK, anchor="mm")
    draw_body(p, d)
    frame = Image.new("RGBA", (PW + 28, PH + 28), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, PW + 27, PH + 27], 70, fill=(28, 30, 30))
    frame.alpha_composite(rounded(p, 58), (14, 14))
    ImageDraw.Draw(frame).rounded_rectangle([PW // 2 - 50, 26, PW // 2 + 78, 60], 17, fill=(10, 10, 10))
    return frame


def card(p, y, h, title, x=22, w=None):
    w = w or PW - 44
    d = ImageDraw.Draw(p)
    d.rounded_rectangle([x, y, x + w, y + h], 18, fill=CARD, outline=BORDER, width=2)
    if title:
        hdr = rounded(vgrad(w, 46, H_TOP, H_BOT), 0)
        m = Image.new("L", (w, 46), 0)
        ImageDraw.Draw(m).rounded_rectangle([0, 0, w - 1, 70], 18, fill=255)
        p.paste(hdr, (x, y), m)
        d.text((x + 18, y + 23), title, font=font(20), fill=INK, anchor="lm")
        return y + 60
    return y + 16


def chip(d, x, y, text):
    f = font(18, weight="Semibold")
    w = d.textlength(text, font=f) + 40
    d.rounded_rectangle([x, y, x + w, y + 34], 17, fill=CHIP)
    d.ellipse([x + 12, y + 14, x + 18, y + 20], fill=CHIPT)
    d.text((x + 26, y + 17), text, font=f, fill=CHIPT, anchor="lm")
    return x + w


def live_body(samples):
    def body(p, d):
        d.text((26, 150), "Live agitation", font=font(36), fill=INK)
        chip(d, 26, 204, "Calm mode · started on its own")
        y = card(p, 260, 420, "Sam · last 10 minutes")
        cx0, cx1, cy0, cy1 = 50, PW - 40, y + 20, y + 320
        ymax = 2.2
        def Y(a): return cy1 - (cy1 - cy0) * min(a, ymax) / ymax
        for lvl, lab, col in [(1.0, "auto-start", RED), (0.6, "rising", AMBER)]:
            yy = Y(lvl)
            for xx in range(cx0, cx1, 16):
                d.line([xx, yy, xx + 8, yy], fill=col, width=2)
            d.text((cx1, yy - 8), lab, font=font(15), fill=col, anchor="rb")
        t0, t1 = samples[0][0], samples[-1][0]
        pts = [(cx0 + (cx1 - cx0) * (t - t0) / (t1 - t0), Y(a)) for t, a in samples]
        poly = [(cx0, cy1)] + pts + [(cx1, cy1)]
        ov = Image.new("RGBA", p.size, (0, 0, 0, 0))
        ImageDraw.Draw(ov).polygon(poly, fill=TEAL_T + (70,))
        p.alpha_composite(ov)
        d = ImageDraw.Draw(p)
        d.line(pts, fill=TEAL, width=4, joint="curve")
        d.text((cx0, cy1 + 16), "10 min ago", font=font(15), fill=SOFT)
        d.text((cx1, cy1 + 16), "now", font=font(15), fill=SOFT, anchor="ra")
        y = card(p, 700, 230, "Auto-start")
        for i, (lab, on) in enumerate([("Movement", True), ("Loud room", False)]):
            yy = y + 10 + i * 64
            d.text((44, yy + 16), lab, font=font(22), fill=INK, anchor="lm")
            col = TEAL if on else (220, 224, 214)
            d.rounded_rectangle([PW - 120, yy, PW - 50, yy + 36], 18, fill=col)
            kx = PW - 86 if on else PW - 120
            d.ellipse([kx + 3, yy + 3, kx + 33, yy + 33], fill="white")
        d.text((44, y + 140), "Sensitivity: balanced (k = 2.5)", font=font(18), fill=SOFT)
    return body


def learn_body(p, d):
    d.text((26, 150), "Calm moments today", font=font(36), fill=INK)
    y = card(p, 210, 330, "2:10 PM · started on its own")
    d.text((44, y + 4), "Movement · Ocean in the rain · 1 min", font=font(20), fill=INK)
    d.rounded_rectangle([40, y + 44, PW - 40, y + 140], 12, fill=(235, 238, 226))
    d.text((60, y + 62), "Agitation 1.99 → 0.12", font=font(24, weight="Semibold"), fill=TEAL)
    d.text((60, y + 100), "settled in 20 s · Sam felt better 🙂", font=font(19), fill=SOFT)
    d.text((44, y + 166), "Did it help?", font=font(20), fill=INK)
    for i, lab in enumerate(["Helped", "Didn't", "False alarm"]):
        x = 44 + i * 132
        sel = i == 0
        d.rounded_rectangle([x, y + 200, x + 122, y + 244], 12, fill=TEAL if sel else CARD, outline=BORDER, width=2)
        d.text((x + 61, y + 222), lab, font=font(18, weight="Semibold"), fill="white" if sel else TEAL, anchor="mm")
    y = card(p, 570, 300, "What Ebb learned")
    rows = [("False alarm · Tue 9:12", "movement less sensitive 2.5 → 2.8"),
            ("Helped · Wed 10:40", "movement a bit more sensitive 2.8 → 2.7"),
            ("Helped · today 2:10", "movement a bit more sensitive 2.7 → 2.6")]
    for i, (a, b) in enumerate(rows):
        yy = y + 8 + i * 72
        d.text((44, yy), a, font=font(20, weight="Semibold"), fill=INK)
        d.text((44, yy + 30), b, font=font(18), fill=SOFT)


def insights_body(heat):
    def body(p, d):
        d.text((26, 150), "Patterns & insights", font=font(34), fill=INK)
        y = card(p, 205, 260, "When hard moments happen")
        days = ["M", "T", "W", "T", "F", "S", "S"]
        hours = list(range(8, 20))
        cw, ch = (PW - 120) / len(hours), 24
        mx = max([c for (_, _, c) in heat] + [1])
        for di in range(7):
            d.text((44, y + di * (ch + 4) + 12), days[di], font=font(15), fill=SOFT, anchor="lm")
            for hi, hr in enumerate(hours):
                c = next((n for (dw, h, n) in heat if dw == di + 1 and h == hr), 0)
                t = c / mx
                col = tuple(int(CARD[k] + (TEAL[k] - CARD[k]) * t) for k in range(3))
                x = 66 + hi * cw
                d.rounded_rectangle([x, y + di * (ch + 4), x + cw - 3, y + di * (ch + 4) + ch], 4, fill=col)
        y = card(p, 490, 230, "What helps Sam (90% band)")
        scenes = [("Ocean in the rain", 0.55, 0.92), ("Space + brown noise", 0.42, 0.85), ("Leaves and rain", 0.2, 0.7),
                  ("Shapes in the rain", 0.1, 0.6)]
        for i, (n, lo, hi) in enumerate(scenes):
            yy = y + 6 + i * 40
            d.text((44, yy + 10), n, font=font(17), fill=INK, anchor="lm")
            x0, x1 = 260, PW - 44
            d.rounded_rectangle([x0, yy + 4, x1, yy + 16], 6, fill=(232, 235, 224))
            d.rounded_rectangle([x0 + (x1 - x0) * lo, yy + 4, x0 + (x1 - x0) * hi, yy + 16], 6, fill=TEAL_T)
            m = x0 + (x1 - x0) * (lo + hi) / 2
            d.ellipse([m - 7, yy + 3, m + 7, yy + 17], fill=TEAL_B)
        y = card(p, 745, 190, "Next 8 hours")
        risks = [0.15, 0.22, 0.58, 0.41, 0.2, 0.12, 0.08, 0.06]
        for i, r in enumerate(risks):
            col = RED if r >= 0.5 else AMBER if r >= 0.2 else GREEN
            x = 50 + i * 50
            d.rounded_rectangle([x, y + 90 - 100 * r, x + 34, y + 90], 6, fill=col)
            d.text((x + 17, y + 104), f"{(9 + i) % 12 or 12}", font=font(15), fill=SOFT, anchor="mm")
        d.text((44, y + 124), "Next risky hour: 11 AM (after transitions)", font=font(17, weight="Semibold"), fill=INK)
    return body


def report_body(p, d):
    d.text((26, 150), "Weekly report", font=font(36), fill=INK)
    y = card(p, 210, 700, "AI summary · this week")
    text_block(d, 44, y + 4, "Calmer week: 9 calm moments, down from 14.", font(24, weight="Semibold"), INK, PW - 90)
    yy = y + 90
    for head, items in [("Patterns", ["Hard moments cluster Tue/Thu 10–11 AM, right after transitions."]),
                        ("What helps", ["Ocean scenes with rain sounds helped 4 of 5 times.",
                                        "Breathing with help works better than alone."]),
                        ("Try this", ["Give a 2-minute warning before transitions.",
                                      "Start calm early on Tuesdays at 10 AM."])]:
        d.text((44, yy), head.upper(), font=font(16, weight="Semibold"), fill=TEAL)
        yy += 30
        for it in items:
            yy = text_block(d, 60, yy, "• " + it, font(19), INK, PW - 110, 6) + 6
        yy += 14
    d.rounded_rectangle([40, 830, PW - 40, 884], 12, fill=TEAL)
    d.text((PW // 2, 857), "Write this week's report", font=font(20, weight="Semibold"), fill="white", anchor="mm")


def imessage():
    p = Image.new("RGBA", (PW, PH), (255, 255, 255, 255))
    d = ImageDraw.Draw(p)
    d.rectangle([0, 0, PW, 150], fill=(246, 246, 246))
    d.ellipse([PW // 2 - 32, 64, PW // 2 + 32, 128], fill=TEAL)
    d.text((PW // 2, 96), "E", font=font(32, weight="Semibold"), fill="white", anchor="mm")
    d.text((PW // 2, 140), "Ebb", font=font(16), fill=SOFT, anchor="mm")
    msgs = [(True, "How was Sam today?"),
            (False, "Sam had 3 calm moments today. The one at 2:10 PM started on its own when movement rose, and Sam settled in about 20 seconds. Ocean scenes have helped most this week."),
            (True, "He slept badly last night, heads up for tomorrow morning"),
            (False, "Added to Sam's journal and shared with Sam's team.")]
    y = 180
    for me, t in msgs:
        f = font(19)
        lines = wrap(d, t, f, 300)
        h = len(lines) * 26 + 22
        w = max(d.textlength(l, font=f) for l in lines) + 32
        x = PW - 20 - w if me else 20
        d.rounded_rectangle([x, y, x + w, y + h], 20, fill=(10, 132, 255) if me else (233, 233, 235))
        for i, l in enumerate(lines):
            d.text((x + 16, y + 11 + i * 26), l, font=f, fill="white" if me else (20, 20, 20))
        y += h + 16
    frame = Image.new("RGBA", (PW + 28, PH + 28), (0, 0, 0, 0))
    ImageDraw.Draw(frame).rounded_rectangle([0, 0, PW + 27, PH + 27], 70, fill=(28, 30, 30))
    frame.alpha_composite(rounded(p, 58), (14, 14))
    ImageDraw.Draw(frame).rounded_rectangle([PW // 2 - 50, 26, PW // 2 + 78, 60], 17, fill=(10, 10, 10))
    return frame


def save(n, frames):
    d = f"{OUT}/{n:02d}"
    os.makedirs(d, exist_ok=True)
    for i, f in enumerate(frames):
        f.convert("RGB").save(f"{d}/{i:04d}.png")


def main():
    data = json.load(open("build/data.json"))
    samples = [(s["t"], s["a"] or 0) for s in data["samples"]]
    heat = [(c["dow"], c["hour"], c["count"]) for c in data["heatmap"]]
    logo = Image.open("../../app/Ebb/Assets.xcassets/EbbLogo.imageset/ebb-logo.png").convert("RGBA")

    # 1 title
    bg = Image.new("RGBA", (W, H))
    bg.paste(vgrad(W, H, (31, 95, 196), (156, 198, 240)), (0, 0))
    d = ImageDraw.Draw(bg)
    d.ellipse([-300, 760, 1300, 1500], fill=(70, 150, 50))
    d.ellipse([700, 820, 2300, 1500], fill=(52, 120, 40))
    big = logo.resize((logo.width * 3, logo.height * 3), Image.LANCZOS)
    shadow_paste(bg, rounded(big, 24), ((W - big.width) // 2, 260), r=24)
    d = ImageDraw.Draw(bg)
    d.text((W // 2, 720), "A calm corner on the wrist", font=font(64, weight="Semibold"), fill="white", anchor="mm",
           stroke_width=2, stroke_fill=(20, 60, 120))
    save(1, [bg])

    # 2 sensing: bar rises
    frames = []
    for i in range(24):
        lvl = 0.05 + 0.9 * (i / 23) ** 1.6
        bg = background()
        side_caption(bg, "Notices first", "Learns each child's own normal",
                     "Movement like rocking or hand-flapping, and how loud the room is.\nLoudness levels only. Never audio.")
        scene_watch(bg, home_screen(lvl))
        frames.append(bg)
    save(2, frames)

    # 3 tiers: buzz then calm scene
    frames = []
    base = background()
    side_caption(base, "Responds in steps", "Breathing buzz, then calm mode",
                 "1  A gentle breathing buzz on the wrist\n2  Calm mode starts on its own: a favourite scene and a familiar voice\n3  Still rising? Ebb alerts the nearest adult")
    for _ in range(12):
        f = base.copy(); scene_watch(f, buzz_screen()); frames.append(f)
    for cf in calm_frames():
        f = base.copy(); scene_watch(f, cf); frames.append(f)
    save(3, frames)

    # 4 check-in
    bg = background()
    side_caption(bg, "The child's voice", "How do you feel?", "After calm mode, the child taps a face. Better, same or worse.")
    f1 = bg.copy(); scene_watch(f1, faces_screen())
    f2 = bg.copy(); scene_watch(f2, faces_screen(0))
    save(4, [f1, f2])

    # 5 live
    bg = background()
    side_caption(bg, "Live for adults", "See it as it happens",
                 "Teachers and parents watch agitation live. If a child isn't settling, Ebb alerts the nearest adult.\n\nReal data from our watch tonight.")
    shadow_paste(bg, phone("Ebb", live_body(samples)), (1180, 50), r=70)
    save(5, [bg])

    # 6 learning
    bg = background()
    side_caption(bg, "Every moment teaches it", "Measured outcomes, self-tuning",
                 "Ebb measures how much agitation dropped. A teacher's rating tunes its sensitivity, so false alarms fade.")
    shadow_paste(bg, phone("Ebb", learn_body), (1180, 50), r=70)
    save(6, [bg])

    # 7 insights + report
    bg = background()
    side_caption(bg, "It learns what works", "Insights and a weekly report",
                 "Which scene helps most at each time of day (Thompson sampling), the riskiest hours ahead, and AI ideas to try.")
    shadow_paste(bg, phone("Ebb", insights_body(heat)), (1060, 50), r=70)
    f1 = bg.copy()
    bg2 = background()
    side_caption(bg2, "It learns what works", "Insights and a weekly report",
                 "Which scene helps most at each time of day (Thompson sampling), the riskiest hours ahead, and AI ideas to try.")
    shadow_paste(bg2, phone("Ebb", insights_body(heat)), (1060, 50), r=70)
    shadow_paste(bg2, phone("Ebb", report_body), (1380, 80), r=70)
    save(7, [f1, bg2])

    # 8 texting
    bg = background()
    side_caption(bg, "Just text Ebb", "Home and school, in one thread",
                 "Parents and teachers text Ebb by iMessage. Questions get answers from the child's data; notes are shared with the team.")
    shadow_paste(bg, imessage(), (1180, 50), r=70)
    save(8, [bg])

    # 9 setup: team mockups
    bg = background()
    d = ImageDraw.Draw(bg)
    d.text((W // 2, 90), "Setup takes minutes", font=font(60, weight="Semibold"), fill=INK, anchor="mm")
    shots = ["Pair watch scanner.png", "Draft calm profile.png", "Voice choice.png", "Add child with consent.png"]
    caps = ["Scan the watch", "Approve a calm profile", "Choose a voice", "Consent, nickname only"]
    for i, (s, c) in enumerate(zip(shots, caps)):
        im = Image.open(os.path.join(APPUI, s)).convert("RGBA")
        hgt = 780
        im = im.crop((0, 0, im.width, min(im.height, int(im.width * 2.0))))
        im = im.resize((int(im.width * hgt / im.height), hgt), Image.LANCZOS)
        x = 120 + i * 440
        shadow_paste(bg, rounded(im, 30), (x, 170), r=30)
        ImageDraw.Draw(bg).text((x + im.width // 2, 990), c, font=font(30), fill=INK, anchor="mm")
    save(9, [bg])

    # 10 close
    bg = Image.new("RGBA", (W, H))
    bg.paste(vgrad(W, H, (31, 95, 196), (156, 198, 240)), (0, 0))
    d = ImageDraw.Draw(bg)
    d.ellipse([-300, 760, 1300, 1500], fill=(70, 150, 50))
    d.ellipse([700, 820, 2300, 1500], fill=(52, 120, 40))
    big = logo.resize((logo.width * 2, logo.height * 2), Image.LANCZOS)
    shadow_paste(bg, rounded(big, 20), ((W - big.width) // 2, 220), r=20)
    d = ImageDraw.Draw(bg)
    d.text((W // 2, 560), "Nicknames only  ·  No audio  ·  Location only if parents opt in", font=font(44, weight="Semibold"),
           fill="white", anchor="mm", stroke_width=2, stroke_fill=(20, 60, 120))
    d.text((W // 2, 650), "Helping adults get there sooner.", font=font(40), fill="white", anchor="mm",
           stroke_width=2, stroke_fill=(20, 60, 120))
    d.text((W // 2, 760), "useebb.tech", font=font(46, weight="Bold"), fill="white", anchor="mm",
           stroke_width=2, stroke_fill=(20, 60, 120))
    save(10, [bg])


main()
