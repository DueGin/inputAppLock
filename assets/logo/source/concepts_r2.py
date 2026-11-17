"""Round 2 concepts: every mark = input-method element + lock element."""
import os, sys
from geo import Pen, stroke, union, diff, inter, rect, circle, translate, bounds, d, svg
from wordmark import wordmark

OUT = sys.argv[1]
os.makedirs(OUT, exist_ok=True)
INK = "#111111"


def save(name, paths, vb, title, fill=INK):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(svg([(d(p), f'fill="{fill}"') for p in paths], vb, title))


def zhong(cx, cy, bw, bh, sw, top, bot, vw=None, r=None):
    """中: open box (口) + vertical stroke. Box centred (cx,cy); vertical from y=top to y=bot."""
    vw = vw or sw
    outer = rect(cx - bw / 2, cy - bh / 2, bw, bh, sw * 0.35 if r is None else r)
    inner = rect(cx - bw / 2 + sw, cy - bh / 2 + sw, bw - 2 * sw, bh - 2 * sw, 0)
    box = diff(outer, inner)
    v = rect(cx - vw / 2, top, vw, bot - top)
    return union(box, v)


def letter_a(cx, base, h, sw):
    """Geometric A: flat apex, legs on a constant slope, crossbar; constant stroke sw."""
    half = h * 0.48           # half width at baseline
    apex = sw * 1.0           # flat apex width
    outer = Pen().M(cx - apex / 2, base - h).L(cx + apex / 2, base - h).L(cx + half, base).L(cx + half - sw * 1.15, base) \
        .L(cx, base - h + sw * 2.0).L(cx - half + sw * 1.15, base).L(cx - half, base).Z().p
    bar_y = base - h * 0.34
    bar = inter(rect(cx - half, bar_y - sw * 0.42, 2 * half, sw * 0.84),
                Pen().M(cx - apex / 2, base - h).L(cx + apex / 2, base - h).L(cx + half, base).L(cx - half, base).Z().p)
    return union(outer, bar)


# ---------- A 中锁: the shackle sits on 中; the 口 is the lock body ----------
def c_zhong_lock():
    sw = 24
    z = zhong(128, 158, 192, 100, sw, 74, 236)
    sh = stroke(Pen().M(78, 112).L(78, 102).arc(128, 102, 50, 180, 360).L(178, 112), sw, "butt")
    return union(z, sh)


# ---------- B 中/A 锁键: padlock body is a keycap labelled 中 / A ----------
def c_keycap_lock():
    body = rect(24, 104, 208, 124, 34)
    sh = stroke(Pen().M(82, 116).L(82, 100).arc(128, 100, 46, 180, 360).L(174, 116), 24, "butt")
    zh = zhong(80, 166, 80, 46, 13, 132, 200, r=2)
    a = letter_a(178, 200, 68, 15)
    return diff(union(body, sh), union(zh, a))


# ---------- C 钉住的中: the vertical stroke of 中 is a push-pin ----------
def c_pinned_zhong():
    sw = 24
    box = diff(rect(32, 108, 192, 96, 9), rect(32 + sw, 108 + sw, 192 - 2 * sw, 96 - 2 * sw))
    head = rect(90, 22, 76, 26, 13)
    collar = Pen().M(108, 48).L(148, 48).L(148, 74).L(168, 94).L(88, 94).L(108, 74).Z().p
    needle = Pen().M(116, 94).L(140, 94).L(140, 212).L(128, 240).L(116, 212).Z().p
    pin = union(head, collar, needle)
    gap = Pen().M(106, 94).L(150, 94).L(150, 214).L(128, 252).L(106, 214).Z().p
    return union(diff(box, gap), pin)


# ---------- D 中|A 锁定开关: segmented switch locked on 中 ----------
def c_switch():
    pill = rect(16, 112, 224, 112, 56)
    inner_r = union(rect(124, 126, 102, 84, 42), rect(124, 126, 44, 84))   # right half hollow D-slot
    left_zh = zhong(72, 168, 72, 42, 12, 136, 200, r=2)
    a = letter_a(178, 198, 56, 13)
    sh = stroke(Pen().M(42, 124).L(42, 104).arc(76, 104, 34, 180, 360).L(110, 124), 20, "butt")
    g = union(diff(union(pill, sh), union(inner_r, left_zh)), a)
    return g


# ---------- E 键盘锁: keyboard is the lock body, caret key glows ----------
def c_keyboard_lock():
    body = rect(28, 104, 200, 120, 30)
    sh = stroke(Pen().M(80, 116).L(80, 100).arc(128, 100, 48, 180, 360).L(176, 116), 24, "butt")
    keys = []
    for i in range(4):
        keys.append(rect(52 + i * 40, 128, 32, 28, 6))
    keys.append(rect(52, 168, 152, 28, 8))       # space bar
    caret = rect(120, 172, 16, 20, 0)
    return diff(union(body, sh), diff(union(*keys), caret))


CONCEPTS = [
    ("a", "中锁 Zhong Lock", c_zhong_lock),
    ("b", "中/A 锁键 Keycap Lock", c_keycap_lock),
    ("c", "钉住的中 Pinned 中", c_pinned_zhong),
    ("d", "中|A 锁定开关 Locked Switch", c_switch),
    ("e", "键盘锁 Keyboard Lock", c_keyboard_lock),
]


def fit(g, box=(24, 24, 232, 232)):
    """Centre the ink box in the canvas (slightly above centre)."""
    b = bounds(g)
    dx = (box[0] + box[2]) / 2 - (b[0] + b[2]) / 2
    dy = (box[1] + box[3]) / 2 - (b[1] + b[3]) / 2 - 2
    return translate(g, dx, dy)


def lockup(sym, name, title):
    wm = wordmark()
    wb = bounds(wm)
    sb = bounds(sym)
    wm = translate(wm, sb[2] + 40 - wb[0], 128 - 110)
    wb = bounds(wm)
    save(name, [union(sym, wm)], (0, 0, round(wb[2] + 24), 256), title)


if __name__ == "__main__":
    for key, title, fn in CONCEPTS:
        s = fit(fn())
        save(f"r2-{key}-symbol.svg", [s], (0, 0, 256, 256), f"InputLock R2 {title}")
        lockup(s, f"r2-{key}-lockup.svg", f"InputLock R2 {title} lockup")
    print("ok")
