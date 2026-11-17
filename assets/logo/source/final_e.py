"""Final kit for direction E — Keyboard Lock (键盘锁)."""
import os, sys
from geo import Pen, stroke, union, diff, rect, circle, translate, bounds, d, svg, squircle
from wordmark import wordmark
from concepts_r2 import letter_a

ROOT = sys.argv[1]
JADE = "#0E9F7E"
JADE_LIGHT = "#2BC9A2"
JADE_DEEP = "#08795F"
INK = "#13201D"


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


# ---------- master symbol, 256 grid, unit 4 ----------
# body 192×112 r32; shackle r48 stroke 24 (outer top y44); keys 4×(28×24) gap 12; space bar 148×24
def symbol():
    body = rect(32, 104, 192, 112, 32)
    sh = stroke(Pen().M(80, 116).L(80, 104).arc(128, 104, 48, 180, 360).L(176, 116), 24, "butt")
    keys = union(*[rect(54 + i * 40, 128, 28, 24, 6) for i in range(4)], rect(54, 166, 148, 24, 8))
    return translate(diff(union(body, sh), keys), 0, -2)        # ink 42..214


def symbol_small():
    """≤32 px cut: heavier shackle, 3 bigger keys, wider gaps."""
    body = rect(28, 100, 200, 120, 32)
    sh = stroke(Pen().M(82, 112).L(82, 100).arc(128, 100, 46, 180, 360).L(174, 112), 32, "butt")
    keys = union(*[rect(58 + i * 54, 124, 32, 32, 7) for i in range(3)], rect(58, 172, 140, 26, 9))
    return translate(diff(union(body, sh), keys), 0, 4)


def lockup(sym):
    wm = wordmark(); wb = bounds(wm); sb = bounds(sym)
    wm = translate(wm, sb[2] + 40 - wb[0], 128 - 110)
    wb = bounds(wm)
    return wm, (0, 0, round(wb[2] + 24), 256)


# ---------- menu bar, drawn on the pixel grid: s=18 (1x) or 36 (2x) ----------
def menubar(state, s):
    if s == 18:
        if state == "disabled":
            body = rect(1, 8, 16, 9, 2.5)
            sh = stroke(Pen().M(8, 5).L(8, 4).arc(11, 4, 3, 180, 360).L(14, 9), 2, "butt")
            inner = union(*[rect(4 + 4 * i, 10, 2, 2) for i in range(3)], rect(4, 13, 10, 2))
        else:
            body = rect(1, 7, 16, 10, 2.5)
            sh = stroke(Pen().M(5, 8).L(5, 6).arc(9, 6, 4, 180, 360).L(13, 8), 2, "butt")
            inner = union(*[rect(4 + 4 * i, 9, 2, 2) for i in range(3)], rect(4, 13, 10, 2))
            if state == "secure":
                inner = letter_a(9, 16, 8, 2)
    else:
        if state == "disabled":
            body = rect(2, 16, 32, 18, 5)
            sh = stroke(Pen().M(16, 10).L(16, 8).arc(22, 8, 6, 180, 360).L(28, 18), 4, "butt")
            inner = union(*[rect(7 + 6 * i, 19, 4, 4, 1) for i in range(4)], rect(7, 26, 22, 4, 1.5))
        else:
            body = rect(2, 14, 32, 20, 5)
            sh = stroke(Pen().M(10, 16).L(10, 12).arc(18, 12, 8, 180, 360).L(26, 16), 4, "butt")
            inner = union(*[rect(7 + 6 * i, 18, 4, 4, 1) for i in range(4)], rect(7, 26, 22, 4, 1.5))
            if state == "secure":
                inner = letter_a(18, 31, 15, 3)
    return diff(union(body, sh), inner)


DEFS = (f'  <defs>\n'
        f'    <linearGradient id="bg" x1="0" y1="100" x2="0" y2="924" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="{JADE_LIGHT}"/><stop offset="1" stop-color="{JADE_DEEP}"/></linearGradient>\n'
        f'    <linearGradient id="gloss" x1="0" y1="100" x2="0" y2="520" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.18"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>\n'
        f'    <linearGradient id="lockfill" x1="0" y1="250" x2="0" y2="780" gradientUnits="userSpaceOnUse">'
        f'<stop offset="0" stop-color="#FFFFFF"/><stop offset="1" stop-color="#E6F6F1"/></linearGradient>\n'
        f'    <filter id="shadow" x="-10%" y="-10%" width="120%" height="125%">'
        f'<feDropShadow dx="0" dy="10" stdDeviation="12" flood-color="#000" flood-opacity="0.28"/></filter>\n'
        f'    <filter id="markshadow" x="-10%" y="-10%" width="120%" height="125%">'
        f'<feDropShadow dx="0" dy="8" stdDeviation="10" flood-color="#04382B" flood-opacity="0.30"/></filter>\n'
        f'  </defs>\n')


def place(s, size=560):
    b = bounds(s)
    sc = size / max(b[2] - b[0], b[3] - b[1])
    cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    return translate(s, 512 - cx * sc, 512 - cy * sc + 6, sc)


def main():
    L = ROOT
    sym, small = symbol(), symbol_small()
    wm, vb = lockup(sym)
    T = "InputLock"
    w(f"{L}/inputlock-symbol.svg", svg([(d(sym), f'fill="{JADE}"')], (0, 0, 256, 256), f"{T} symbol"))
    w(f"{L}/inputlock-symbol-black.svg", svg([(d(sym), 'fill="#000000"')], (0, 0, 256, 256), f"{T} symbol (black)"))
    w(f"{L}/inputlock-symbol-white.svg", svg([(d(sym), 'fill="#FFFFFF"')], (0, 0, 256, 256), f"{T} symbol (white)"))
    w(f"{L}/inputlock-symbol-small.svg", svg([(d(small), f'fill="{JADE}"')], (0, 0, 256, 256), f"{T} symbol, small-size cut"))
    w(f"{L}/inputlock-horizontal.svg", svg([(d(sym), f'id="symbol" fill="{JADE}"'), (d(wm), f'id="wordmark" fill="{INK}"')], vb, f"{T} logo"))
    w(f"{L}/inputlock-horizontal-black.svg", svg([(d(union(sym, wm)), 'fill="#000000"')], vb, f"{T} logo (one colour)"))
    w(f"{L}/inputlock-horizontal-white.svg", svg([(d(union(sym, wm)), 'fill="#FFFFFF"')], vb, f"{T} logo (reversed)"))
    wm0 = wordmark(); b0 = bounds(wm0)
    w(f"{L}/inputlock-wordmark.svg", svg([(d(translate(wm0, 24 - b0[0], 0)), f'fill="{INK}"')], (0, 0, round(b0[2] - b0[0] + 48), 256), f"{T} wordmark"))
    # stacked: symbol over wordmark at 0.6
    sc = 0.6; ww = (b0[2] - b0[0]) * sc; W_ = max(256, ww + 48)
    st_sym = translate(sym, (W_ - 256) / 2, 0)
    st_wm = translate(wm0, (W_ - ww) / 2 - b0[0] * sc, 240 - 44 * sc, sc)
    sb = bounds(st_wm)
    for suf, fs, fw in (("", JADE, INK), ("-black", "#000000", "#000000"), ("-white", "#FFFFFF", "#FFFFFF")):
        w(f"{L}/inputlock-stacked{suf}.svg", svg([(d(st_sym), f'fill="{fs}"'), (d(st_wm), f'fill="{fw}"')],
                                                (0, 20, round(W_), round(sb[3] + 24 - 20)), f"{T} logo, stacked"))
    # app icon
    tile = squircle(100, 100, 824, n=5.0, steps=720)
    for name, s in (("app-icon-1024", sym), ("app-icon-small", small)):
        mark = place(s, 560 if s is sym else 600)
        w(f"{L}/app-icon/{name}.svg", svg([(d(tile), 'fill="url(#bg)" filter="url(#shadow)"'), (d(tile), 'fill="url(#gloss)"'),
                                           (d(mark), 'fill="url(#lockfill)" filter="url(#markshadow)"')],
                                          (0, 0, 1024, 1024), f"{T} app icon", DEFS))
    w(f"{L}/app-icon/app-icon-flat.svg", svg([(d(diff(tile, place(sym))), f'fill="{JADE}"')], (0, 0, 1024, 1024), f"{T} app icon (flat)"))
    # menu bar
    for state, suf in (("locked", ""), ("secure", "Secure"), ("disabled", "Disabled")):
        for s, tag in ((18, ""), (36, "@2x")):
            w(f"{L}/menubar/MenuBarIcon{suf}Template{tag}.svg",
              svg([(d(menubar(state, s)), 'fill="#000000"')], (0, 0, s, s), f"{T} menu bar icon ({state})"))
    print("ok")


if __name__ == "__main__":
    main()
