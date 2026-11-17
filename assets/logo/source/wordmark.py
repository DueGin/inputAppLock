"""Custom geometric wordmark 'InputLock' constructed from strokes (no font dependency)."""
import math
from geo import Pen, stroke, union, inter, rect, translate, bounds

W = 20          # stem weight
H = W / 2
BASE = 176      # baseline
XT = 80         # x-height top (x-height 96)
CT = 44         # cap top (cap height 132)
DESC = 220      # descender bottom
OV = 1.5        # overshoot for rounds


def _clip(p, x0=-50, y0=XT, x1=400, y1=BASE):
    return inter(p, rect(x0, y0, x1 - x0, y1 - y0))


def I():
    return stroke(Pen().M(H, CT).L(H, BASE), W, "butt"), W


def n():
    r = 28
    cy = XT + H + r
    arch = Pen().M(H, BASE).L(H, cy).arc(H + r, cy, r, 180, 360).L(H + 2 * r, BASE)
    stem = Pen().M(H, XT).L(H, BASE)
    return union(stroke(arch, W, "butt"), stroke(stem, W, "butt")), 2 * r + W


def u():
    r = 28
    cy = BASE - H - r
    bowl = Pen().M(H, XT).L(H, cy).arc(H + r, cy, r, 180, 0).L(H + 2 * r, XT)
    stem = Pen().M(H + 2 * r, XT).L(H + 2 * r, BASE)
    return union(stroke(bowl, W, "butt"), stroke(stem, W, "butt")), 2 * r + W


def p():
    r = (BASE - XT) / 2 - H + OV
    cy = (XT + BASE) / 2
    stem = Pen().M(H, XT).L(H, DESC)
    bowl = Pen().arc(H + r, cy, r, 0, 360, move=True).Z()
    return union(stroke(stem, W, "butt"), stroke(bowl, W)), 2 * r + W


def t():
    sx = 22
    stem = Pen().M(sx, 52).L(sx, BASE)
    bar = Pen().M(0, XT + H).L(54, XT + H)
    return union(stroke(stem, W, "butt"), stroke(bar, W, "butt")), 54


def L():
    stem = Pen().M(H, CT).L(H, BASE)
    foot = Pen().M(H, BASE - H).L(72, BASE - H)
    return union(stroke(stem, W, "butt"), stroke(foot, W, "butt")), 72


def o():
    r = (BASE - XT) / 2 - H + OV
    cy = (XT + BASE) / 2
    ring = Pen().arc(H + r, cy, r, 0, 360, move=True).Z()
    return stroke(ring, W), 2 * r + W


def c():
    r = (BASE - XT) / 2 - H + OV
    cy = (XT + BASE) / 2
    arc = Pen().arc(H + r, cy, r, 315, 45, move=True)
    pth = stroke(arc, W, "butt")
    b = bounds(pth)
    return pth, b[2]


def k():
    stem = Pen().M(H, CT).L(H, BASE)
    up = Pen().M(H - 4, 150 + 4).L(H - 4 + 80, 154 - 80)        # 45 deg
    lo_x0, lo_y0 = 34, 126
    lo = Pen().M(lo_x0, lo_y0).L(lo_x0 + 60 / math.tan(math.radians(60)) * 1.0, lo_y0 + 60)
    arms = union(stroke(up, W, "butt"), stroke(lo, W, "butt"))
    arms = _clip(arms, 0, XT, 400, BASE)
    g = union(stroke(stem, W, "butt"), arms)
    b = bounds(g)
    return g, b[2]


GLYPHS = {"I": I, "n": n, "p": p, "u": u, "t": t, "L": L, "o": o, "c": c, "k": k}
# right-side gap after each glyph (optical spacing, units)
GAP = {"I": 22, "n": 18, "p": 16, "u": 14, "t": 14, "L": 6, "o": 14, "c": 12, "k": 0}


def wordmark(text="InputLock"):
    x = 0.0
    parts = []
    for ch in text:
        g, adv = GLYPHS[ch]()
        parts.append(translate(g, x, 0))
        x += adv + GAP[ch]
    wm = union(*parts)
    return wm
