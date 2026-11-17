"""Generate the three concept symbols + lockups (black, greyscale exploration)."""
import os, sys
from geo import Pen, stroke, union, diff, rect, circle, translate, bounds, d, svg
from wordmark import wordmark

OUT = sys.argv[1] if len(sys.argv) > 1 else "."
os.makedirs(OUT, exist_ok=True)
INK = "#111111"


def save(name, paths, vb, title):
    with open(os.path.join(OUT, name), "w") as f:
        f.write(svg([(d(p), f'fill="{INK}"') for p in paths], vb, title))


# ---------- A: Keyhole-i keycap ----------
def concept_a():
    tile = rect(24, 24, 208, 208, 56)
    dot = circle(128, 92, 26)
    stemr = rect(110, 130, 36, 58, 18)
    return diff(tile, union(dot, stemr))


# ---------- B: Caret Lock (padlock whose keyhole is a text cursor) ----------
def caret_slot(cx=128, top=128, bot=188, stem=20, serif=48, sh=16):
    st = rect(cx - stem / 2, top, stem, bot - top, 0)
    s1 = rect(cx - serif / 2, top, serif, sh, sh / 2)
    s2 = rect(cx - serif / 2, bot - sh, serif, sh, sh / 2)
    return union(st, s1, s2)


def lock_body(x=48, y=104, w=160, h=112, r=32):
    return rect(x, y, w, h, r)


def shackle(cx=128, y=104, r=44, w=24, open_=False):
    lift = 26 if open_ else 0
    pen = Pen().M(cx - r, y + 12 - (0 if not open_ else 30)).L(cx - r, y - lift).arc(cx, y - lift, r, 180, 360).L(cx + r, y + 12 - lift)
    if open_:
        pen = Pen().M(cx - r, y - 4 - lift).L(cx - r, y - lift).arc(cx, y - lift, r, 180, 360).L(cx + r, y + 12)
    return stroke(pen, w, "butt")


def concept_b():
    g = diff(union(lock_body(), shackle()), caret_slot(top=130, bot=190))
    return translate(g, 0, -4)


# ---------- C: Locked toggle ----------
def concept_c():
    pill = rect(24, 120, 208, 96, 48)
    knob = circle(180, 168, 28)
    sh = Pen().M(156, 136).L(156, 116).arc(180, 116, 24, 180, 360).L(204, 136)
    g = union(diff(pill, knob), stroke(sh, 20, "butt"))
    return translate(g, 0, -12)


def lockup(sym, name, title):
    wm = wordmark()
    wb = bounds(wm)
    # centre cap-height band (44..176 -> 110) on symbol centre 128
    wm = translate(wm, 256 + 28 - wb[0], 128 - 110)
    wb = bounds(wm)
    width = wb[2] + 8
    save(name, [sym, wm], (0, 0, round(width), 256), title)


if __name__ == "__main__":
    for key, fn, title in (("a", concept_a, "InputLock concept A — Keyhole i"),
                           ("b", concept_b, "InputLock concept B — Locked I-beam"),
                           ("c", concept_c, "InputLock concept C — Locked toggle")):
        s = fn()
        save(f"concept-{key}-symbol.svg", [s], (0, 0, 256, 256), title)
        lockup(s, f"concept-{key}-lockup.svg", title + " lockup")
    save("wordmark.svg", [wordmark()], (0, 0, 640, 256), "InputLock wordmark")
    print("ok")
