"""R2 extras: 18px menu-bar sketches (pixel grid, drawn at @2x = 36 units) + 1024 app-icon colour drafts."""
import os, sys, re
from geo import Pen, stroke, union, diff, rect, circle, translate, bounds, d, svg, squircle
import concepts_r2 as R

OUT = sys.argv[1]
MB = os.path.join(OUT, "menubar-sketch")
AI = os.path.join(OUT, "app-icon")
os.makedirs(MB, exist_ok=True); os.makedirs(AI, exist_ok=True)


def wsvg(path, paths, vb, title, extra=""):
    with open(path, "w") as f:
        f.write(svg(paths, vb, title, extra))


# ---- 18 pt menu bar sketches, coordinates on the 18 grid ×2 (so every edge lands on a pixel at 1x and 2x)
def U(v):
    return v * 2


def mb_a():   # 中锁
    box = diff(rect(U(2), U(8), U(14), U(7)), rect(U(4), U(10), U(10), U(3)))
    v = rect(U(8), U(4), U(2), U(13))
    sh = stroke(Pen().M(U(5), U(8)).L(U(5), U(7)).arc(U(9), U(7), U(4), 180, 360).L(U(13), U(8)), U(2), "butt")
    return union(box, v, sh)


def mb_b():   # 中 keycap lock (simplified: A dropped at 18 px)
    body = rect(U(2), U(7), U(14), U(10), U(2.5))
    sh = stroke(Pen().M(U(6), U(8)).L(U(6), U(6)).arc(U(9), U(6), U(3), 180, 360).L(U(12), U(8)), U(2), "butt")
    zh = union(diff(rect(U(5), U(10), U(8), U(4)), rect(U(6), U(11), U(6), U(2))), rect(U(8.5), U(9), U(1), U(7)))
    return diff(union(body, sh), zh)


def mb_c():   # pinned 中
    box = diff(rect(U(1), U(9), U(16), U(6)), rect(U(3), U(11), U(12), U(2)))
    box = diff(box, rect(U(7), U(8), U(4), U(10)))
    pin = union(rect(U(6), U(1), U(6), U(2), U(1)), rect(U(7), U(3), U(4), U(3)), rect(U(5), U(6), U(8), U(2)),
                Pen().M(U(8), U(8)).L(U(10), U(8)).L(U(10), U(15)).L(U(9), U(17)).L(U(8), U(15)).Z().p)
    return union(box, pin)


def mb_d():   # 中|A switch (simplified: knob-lock + track, no letters fit)
    track = diff(rect(U(1), U(7), U(16), U(9), U(4.5)), rect(U(9), U(9), U(6), U(5), U(2.5)))
    zh = union(diff(rect(U(3), U(9.5), U(5), U(4)), rect(U(4), U(10.5), U(3), U(2))), rect(U(5), U(8.5), U(1), U(6)))
    sh = stroke(Pen().M(U(3), U(8)).L(U(3), U(5)).arc(U(5.5), U(5), U(2.5), 180, 360).L(U(8), U(8)), U(1.5), "butt")
    return union(diff(track, zh), sh)


def mb_e():   # keyboard lock
    body = rect(U(1), U(7), U(16), U(10), U(2.5))
    sh = stroke(Pen().M(U(5), U(8)).L(U(5), U(6)).arc(U(9), U(6), U(4), 180, 360).L(U(13), U(8)), U(2), "butt")
    keys = union(*[rect(U(3 + 3 * i), U(9), U( 2), U(2)) for i in range(4)], rect(U(4), U(13), U(10), U(2)))
    return diff(union(body, sh), keys)


MBS = {"a": mb_a, "b": mb_b, "c": mb_c, "d": mb_d, "e": mb_e}

# ---- app icon drafts
JADE_LIGHT, JADE_DEEP = "#2BC9A2", "#08795F"
DEFS = (f'  <defs>\n'
        f'    <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{JADE_LIGHT}"/><stop offset="1" stop-color="{JADE_DEEP}"/></linearGradient>\n'
        f'    <linearGradient id="gloss" x1="0" y1="100" x2="0" y2="520" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.18"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>\n'
        f'    <linearGradient id="lockfill" x1="0" y1="220" x2="0" y2="800" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6F6F1"/></linearGradient>\n'
        f'    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">'
        f'<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.28"/></filter>\n'
        f'    <filter id="markshadow" x="-10%" y="-10%" width="120%" height="125%">'
        f'<feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#04382B" flood-opacity="0.30"/></filter>\n'
        f'  </defs>\n')


def app_icon(key, sym):
    tile = squircle(100, 100, 824, n=5.0, steps=720)
    b = bounds(sym)
    w, h = b[2] - b[0], b[3] - b[1]
    sc = min(560 / w, 560 / h)
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    mark = translate(sym, 512 - cx * sc, 512 - cy * sc, sc)
    wsvg(os.path.join(AI, f"r2-{key}-app-icon.svg"),
         [(d(tile), 'fill="url(#bg)" filter="url(#shadow)"'), (d(tile), 'fill="url(#gloss)"'),
          (d(mark), 'fill="url(#lockfill)" filter="url(#markshadow)"')],
         (0, 0, 1024, 1024), f"InputLock R2 {key} app icon draft", DEFS)


if __name__ == "__main__":
    for key, title, fn in R.CONCEPTS:
        g = MBS[key]()
        wsvg(os.path.join(MB, f"r2-{key}-menubar@2x.svg"), [(d(g), 'fill="#000000"')], (0, 0, 36, 36), f"R2 {key} menu bar sketch")
        app_icon(key, R.fit(fn()))
    print("ok")
