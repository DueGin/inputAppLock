"""Final InputLock kit: masters, app icon sources, menu-bar template icons."""
import os, sys
from geo import Pen, stroke, union, diff, rect, circle, translate, bounds, d, svg, squircle
from wordmark import wordmark
from concepts import caret_slot, lock_body, shackle

ROOT = sys.argv[1]
JADE = "#0E9F7E"
JADE_LIGHT = "#2BC9A2"
JADE_DEEP = "#08795F"
INK = "#13201D"


def w(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def symbol():
    g = diff(union(lock_body(), shackle()), caret_slot(top=130, bot=190))
    return translate(g, 0, -4)          # ink 40..212, optically centred


def symbol_small():
    """Small-size cut (<=32 px): heavier shackle, bolder cursor slot."""
    sh = shackle(w=30, r=42)
    slot = caret_slot(top=128, bot=192, stem=28, serif=64, sh=22)
    g = diff(union(lock_body(x=44, w=168, h=116, y=102), sh), slot)
    return translate(g, 0, -2)


def lockup_paths(sym):
    wm = wordmark()
    wb = bounds(wm)
    wm = translate(wm, 256 - 48 + 40 - wb[0], 128 - 110)   # gap 40 after the lock body
    wb = bounds(wm)
    return wm, (0, 0, round(wb[2] + 48), 256)


def main():
    L = ROOT
    sym = symbol()
    small = symbol_small()
    wm, vb = lockup_paths(sym)
    # symbol masters
    w(f"{L}/inputlock-symbol.svg", svg([(d(sym), f'fill="{JADE}"')], (0, 0, 256, 256), "InputLock symbol"))
    w(f"{L}/inputlock-symbol-black.svg", svg([(d(sym), 'fill="#000000"')], (0, 0, 256, 256), "InputLock symbol (black)"))
    w(f"{L}/inputlock-symbol-small.svg", svg([(d(small), f'fill="{JADE}"')], (0, 0, 256, 256), "InputLock symbol, small-size cut"))
    # lockups
    w(f"{L}/inputlock-horizontal.svg", svg([(d(sym), f'id="symbol" fill="{JADE}"'), (d(wm), f'id="wordmark" fill="{INK}"')], vb, "InputLock logo"))
    w(f"{L}/inputlock-horizontal-black.svg", svg([(d(union(sym, wm)), 'fill="#000000"')], vb, "InputLock logo (one colour)"))
    w(f"{L}/inputlock-horizontal-white.svg", svg([(d(sym), 'fill="#FFFFFF"'), (d(wm), 'fill="#FFFFFF"')], vb, "InputLock logo (reversed)"))
    wb = bounds(wordmark())
    w(f"{L}/inputlock-wordmark.svg", svg([(d(translate(wordmark(), 24 - wb[0], 0)), f'fill="{INK}"')], (0, 0, round(wb[2] - wb[0] + 48), 256), "InputLock wordmark"))
    # stacked
    wm2 = wordmark(); b2 = bounds(wm2)
    sc = 0.6
    ww = (b2[2] - b2[0]) * sc
    W_ = max(256, ww + 48)
    st_sym = translate(sym, (W_ - 256) / 2, 0)
    st_wm = translate(translate(wm2, -b2[0], 0), (W_ - ww) / 2, 236 - 44 * sc + 0, sc)
    st_wm = translate(wm2, (W_ - ww) / 2 - b2[0] * sc, 236 - 44 * sc, sc)
    sb = bounds(st_wm)
    w(f"{L}/inputlock-stacked.svg", svg([(d(st_sym), f'fill="{JADE}"'), (d(st_wm), f'fill="{INK}"')], (0, 16, round(W_), round(sb[3] + 24 - 16)), "InputLock logo, stacked"))

    # ---------- macOS app icon (Big Sur grid: 824 tile on 1024 canvas) ----------
    for name, s, scale in (("app-icon-1024", sym, 2.9), ("app-icon-small", small, 3.05)):
        tile = squircle(100, 100, 824, n=5.0, steps=720)
        b = bounds(s)
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        mark = translate(s, 512 - cx * scale, 512 - cy * scale + 4, scale)
        defs = (f'  <defs>\n'
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
        paths = [(d(tile), 'fill="url(#bg)" filter="url(#shadow)"'),
                 (d(tile), 'fill="url(#gloss)"'),
                 (d(mark), 'fill="url(#lockfill)" filter="url(#markshadow)"')]
        w(f"{L}/app-icon/{name}.svg", svg(paths, (0, 0, 1024, 1024), "InputLock app icon", defs))
    # flat (no filter / gradient) version for print & audits
    tile = squircle(100, 100, 824, n=5.0, steps=720)
    b = bounds(sym); cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
    mark = translate(sym, 512 - cx * 2.9, 512 - cy * 2.9 + 4, 2.9)
    w(f"{L}/app-icon/app-icon-flat.svg", svg([(d(diff(tile, mark)), f'fill="{JADE}"')], (0, 0, 1024, 1024), "InputLock app icon (flat)"))

    # ---------- menu-bar template icons (pixel-grid drawn per size) ----------
    def mb(size, state):
        if size == 18:
            if state == "disabled":
                body = rect(3, 8, 12, 9, 2)
                sh = stroke(Pen().M(6, 6).L(6, 5).arc(9, 5, 3, 180, 360).L(12, 9), 2, "butt")
                slot = union(rect(8, 10, 2, 5), rect(6, 10, 6, 1), rect(6, 14, 6, 1))
            else:
                body = rect(3, 7, 12, 10, 2)
                sh = stroke(Pen().M(6, 8).L(6, 6).arc(9, 6, 3, 180, 360).L(12, 8), 2, "butt")
                slot = union(rect(8, 9, 2, 6), rect(6, 9, 6, 1), rect(6, 14, 6, 1))
            if state == "secure":
                slot = union(rect(5, 11, 2, 2), rect(8, 11, 2, 2), rect(11, 11, 2, 2))
        else:
            if state == "disabled":
                body = rect(6, 16, 24, 18, 4)
                sh = stroke(Pen().M(12, 12).L(12, 10).arc(18, 10, 6, 180, 360).L(24, 18), 4, "butt")
                slot = union(rect(16, 20, 4, 10), rect(12, 20, 12, 2, 1), rect(12, 28, 12, 2, 1))
            else:
                body = rect(6, 14, 24, 20, 4)
                sh = stroke(Pen().M(12, 16).L(12, 12).arc(18, 12, 6, 180, 360).L(24, 16), 4, "butt")
                slot = union(rect(16, 18, 4, 12), rect(12, 18, 12, 2, 1), rect(12, 28, 12, 2, 1))
            if state == "secure":
                slot = union(circle(11, 24, 2.5), circle(18, 24, 2.5), circle(25, 24, 2.5))
        return diff(union(body, sh), slot)

    for state, suffix in (("locked", ""), ("secure", "Secure"), ("disabled", "Disabled")):
        for size, tag in ((18, ""), (36, "@2x")):
            g = mb(size, state)
            w(f"{L}/menubar/MenuBarIcon{suffix}Template{tag}.svg",
              svg([(d(g), 'fill="#000000"')], (0, 0, size, size), f"InputLock menu bar icon ({state})"))
    print("ok")


if __name__ == "__main__":
    main()
