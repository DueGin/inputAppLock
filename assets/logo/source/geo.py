"""Tiny geometry kit: build outlines with skia-pathops, emit clean SVG path data."""
import math
import pathops

K = 0.5522847498


def _arc_pts(cx, cy, r, a0, a1):
    """Cubic segments approximating arc from angle a0 to a1 (degrees, SVG y-down, 0=east, 90=south)."""
    segs = []
    n = max(1, int(math.ceil(abs(a1 - a0) / 90.0 - 1e-9)))
    step = (a1 - a0) / n
    for i in range(n):
        t0 = math.radians(a0 + i * step)
        t1 = math.radians(a0 + (i + 1) * step)
        k = 4.0 / 3.0 * math.tan((t1 - t0) / 4.0)
        p0 = (cx + r * math.cos(t0), cy + r * math.sin(t0))
        p3 = (cx + r * math.cos(t1), cy + r * math.sin(t1))
        c1 = (p0[0] - k * r * math.sin(t0), p0[1] + k * r * math.cos(t0))
        c2 = (p3[0] + k * r * math.sin(t1), p3[1] - k * r * math.cos(t1))
        segs.append((p0, c1, c2, p3))
    return segs


class Pen:
    """Open/closed centreline builder."""

    def __init__(self):
        self.p = pathops.Path()

    def M(self, x, y):
        self.p.moveTo(x, y); return self

    def L(self, x, y):
        self.p.lineTo(x, y); return self

    def arc(self, cx, cy, r, a0, a1, move=False):
        segs = _arc_pts(cx, cy, r, a0, a1)
        if move:
            self.p.moveTo(*segs[0][0])
        else:
            self.p.lineTo(*segs[0][0])
        for _, c1, c2, p3 in segs:
            self.p.cubicTo(*c1, *c2, *p3)
        return self

    def Z(self):
        self.p.close(); return self


def stroke(pen, w, cap="round", join="round"):
    p = pathops.Path()
    p.addPath(pen.p)
    caps = {"round": pathops.LineCap.ROUND_CAP, "butt": pathops.LineCap.BUTT_CAP, "square": pathops.LineCap.SQUARE_CAP}
    joins = {"round": pathops.LineJoin.ROUND_JOIN, "miter": pathops.LineJoin.MITER_JOIN, "bevel": pathops.LineJoin.BEVEL_JOIN}
    p.stroke(w, caps[cap], joins[join], 4)
    p.convertConicsToQuads()
    return simplify(p)


def circle(cx, cy, r, reverse=False):
    pen = Pen().arc(cx, cy, r, 0, 360, move=True).Z()
    return pen.p


def rect(x, y, w, h, r=0):
    pen = Pen()
    if r <= 0:
        pen.M(x, y).L(x + w, y).L(x + w, y + h).L(x, y + h).Z()
        return pen.p
    r = min(r, w / 2, h / 2)
    pen.M(x + r, y).L(x + w - r, y)
    pen.arc(x + w - r, y + r, r, -90, 0)
    pen.L(x + w, y + h - r)
    pen.arc(x + w - r, y + h - r, r, 0, 90)
    pen.L(x + r, y + h)
    pen.arc(x + r, y + h - r, r, 90, 180)
    pen.L(x, y + r)
    pen.arc(x + r, y + r, r, 180, 270)
    pen.Z()
    return pen.p


def squircle(x, y, s, n=5.0, steps=256):
    """Superellipse |x|^n+|y|^n=1 (macOS-like continuous-corner tile), polygonal but dense."""
    cx, cy, a = x + s / 2, y + s / 2, s / 2
    p = pathops.Path()
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, sn = math.cos(t), math.sin(t)
        px = cx + a * math.copysign(abs(c) ** (2 / n), c)
        py = cy + a * math.copysign(abs(sn) ** (2 / n), sn)
        (p.moveTo if i == 0 else p.lineTo)(px, py)
    p.close()
    return p


def simplify(p):
    return pathops.simplify(p, fix_winding=True)


def union(*paths):
    out = pathops.Path()
    for p in paths:
        out.addPath(p)
    return pathops.simplify(out, fix_winding=True)


def _op(a, b, op):
    return pathops.op(a, b, op, fix_winding=True)


def diff(a, b):
    return _op(a, b, pathops.PathOp.DIFFERENCE)


def inter(a, b):
    return _op(a, b, pathops.PathOp.INTERSECTION)


def translate(p, dx, dy, sx=1.0, sy=None):
    sy = sx if sy is None else sy
    return p.transform(sx, 0, 0, sy, dx, dy)


def bounds(p):
    return p.bounds


def fmt(v):
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return "0" if s in ("-0", "") else s


def d(p):
    out = []
    for verb, pts in p.segments:
        if verb == "moveTo":
            out.append("M" + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in pts))
        elif verb == "lineTo":
            out.append("L" + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in pts))
        elif verb == "curveTo":
            out.append("C" + " ".join(f"{fmt(x)} {fmt(y)}" for x, y in pts))
        elif verb == "qCurveTo":
            pts = list(pts)
            if pts[-1] is None:  # closed all-off-curve contour
                offs = pts[:-1]
                start = ((offs[-1][0] + offs[0][0]) / 2, (offs[-1][1] + offs[0][1]) / 2)
                out.append(f"M{fmt(start[0])} {fmt(start[1])}")
                pts = offs + [start]
            offs, end = pts[:-1], pts[-1]
            for i, c in enumerate(offs):
                if i + 1 < len(offs):
                    nx = offs[i + 1]
                    e = ((c[0] + nx[0]) / 2, (c[1] + nx[1]) / 2)
                else:
                    e = end
                out.append(f"Q{fmt(c[0])} {fmt(c[1])} {fmt(e[0])} {fmt(e[1])}")
        elif verb == "closePath":
            out.append("Z")
        elif verb == "endPath":
            pass
    return "".join(out)


def svg(paths, vb, title, extra_defs=""):
    """paths: list of (d, attrs) ."""
    x, y, w, h = vb
    body = "\n".join(f'  <path {a} d="{dd}"/>' for dd, a in paths)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{fmt(x)} {fmt(y)} {fmt(w)} {fmt(h)}" '
            f'width="{fmt(w)}" height="{fmt(h)}" role="img" aria-labelledby="title">\n'
            f'  <title id="title">{title}</title>\n{extra_defs}{body}\n</svg>\n')
