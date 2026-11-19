"""菜单栏三态图标（第三轮：键帽上的猫）。

用法：uv run --with pillow --with numpy --with potracer python -I menubar_cat.py <输出目录>

在 36 单位网格上用基本形状画母版（超采样 16 倍），再分别缩到 36 px（@2x）和 18 px（@1x），
输出 template PNG（纯黑 + alpha）与 potrace 描出的 SVG 源文件。
"""
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

S = 16                     # 超采样倍数：36 网格 → 576 px 母版
GRID = 36


def p(*pts):
    return [(x * S, y * S) for x, y in pts]


# 所有水平边都落在偶数单位上，这样缩到 18 px（@1x）时正好压在整像素边界，不发虚。
CAT_BASE = 20      # 猫的底边
CAP_TOP = 22       # 键帽顶边（与猫之间留 2 单位 = @1x 的 1 px 缝）
CAP_BOTTOM = 32    # 键帽底边


def cat(draw, fill=255):
    """趴着的猫：半椭圆的背 + 圆头，中间自然形成脖子凹口；两只竖起的三角耳。"""
    # 背：中心 (14, 20)，半径 11×13 的椭圆，底边裁平后是半椭圆
    draw.ellipse([3 * S, 7 * S, 25 * S, 33 * S], fill=fill)
    # 头：圆心 (27, 15)，半径 5
    draw.ellipse([22 * S, 10 * S, 32 * S, 20 * S], fill=fill)
    # 耳朵
    draw.polygon(p((22.6, 13.2), (26.6, 10.4), (23.2, 4.6)), fill=fill)
    draw.polygon(p((27.4, 10.2), (31.8, 13.2), (31.4, 4.6)), fill=fill)


def keycap(draw, fill=255):
    """键帽：上窄下宽的圆角梯形，CAP_TOP..CAP_BOTTOM。圆角用描边的圆头实现。"""
    r = 1.0                           # 圆角半径，同时是描边半宽
    t, b = CAP_TOP + r, CAP_BOTTOM - r
    pts = p((7 + r, t), (29 - r, t), (33 - r, b), (3 + r, b))
    draw.polygon(pts, fill=fill)
    draw.line(pts + [pts[0]], fill=fill, width=int(2 * r * S), joint="curve")
    for x, y in pts:
        draw.ellipse([x - r * S, y - r * S, x + r * S, y + r * S], fill=fill)


def letter_a(draw, detail, fill=0):
    """键帽上挖出的 A（大写，几何笔画）。@1x 笔画加粗、字形放大，保证还能认。"""
    if detail:
        w, top, base, half, bar = 2.2, 23.6, 30.8, 3.6, 28.4
    else:
        # @1x 的键帽只有 5 px 高：A 收窄、去掉横杠，挖成一个倒 V，保证键帽不被切碎
        w, top, base, half, bar = 2.0, 24.4, 30.0, 2.6, None
    draw.line(p((18 - half, base), (18, top), (18 + half, base)), fill=fill, width=int(w * S), joint="curve")
    if bar is not None:
        inset = half * (base - bar) / (base - top)
        draw.line(p((18 - half + inset, bar), (18 + half - inset, bar)), fill=fill, width=int(w * 0.9 * S))


def master(state, detail=True):
    """detail=True 画 @2x 母版（带尾巴缝），False 画 @1x 母版（只留大形）。"""
    img = Image.new("L", (GRID * S, GRID * S), 0)
    d = ImageDraw.Draw(img)
    cat(d)
    d.rectangle([0, CAT_BASE * S, GRID * S, GRID * S], fill=0)        # 猫的底边裁平
    if detail and state != "disabled":
        # 卷在身前的尾巴：一道弧形细缝
        d.arc([6 * S, 11 * S, 23 * S, 27 * S], start=205, end=305, fill=0, width=int(1.6 * S))
    keycap(d)
    if state == "secure":
        letter_a(d, detail)
    if state == "disabled":
        # 空心：减去腐蚀后的内部，只留 2 单位（@1x 正好 1 px）粗的轮廓
        stroke = 2.0 if detail else 2.0
        k = int(stroke * S) * 2 + 1
        inner = img.filter(ImageFilter.MinFilter(k))
        arr = np.array(img).astype(np.int16) - np.array(inner).astype(np.int16)
        img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    return img


def to_template(mask, size):
    a = mask.resize((size, size), Image.LANCZOS)
    rgba = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    rgba.putalpha(a)
    return rgba


NAMES = {"locked": "MenuBarIconTemplate", "secure": "MenuBarIconSecureTemplate",
         "disabled": "MenuBarIconDisabledTemplate"}


def trace_svg(mask, size, title):
    import potrace
    arr = np.array(mask) > 127
    plist = potrace.Bitmap(arr).trace(turdsize=20, alphamax=1.0, opticurve=True, opttolerance=0.2)
    k = size / mask.size[0]
    parts = []
    for c in plist:
        s0 = c.start_point
        d = [f"M{s0.x * k:.2f} {s0.y * k:.2f}"]
        for seg in c.segments:
            if seg.is_corner:
                d.append(f"L{seg.c.x * k:.2f} {seg.c.y * k:.2f}L{seg.end_point.x * k:.2f} {seg.end_point.y * k:.2f}")
            else:
                d.append(f"C{seg.c1.x * k:.2f} {seg.c1.y * k:.2f} {seg.c2.x * k:.2f} {seg.c2.y * k:.2f} "
                         f"{seg.end_point.x * k:.2f} {seg.end_point.y * k:.2f}")
        parts.append("".join(d) + "Z")
    # potracer 描出的环包着背景区域（见 app-icon 的经验），用整幅矩形 + evenodd 反转
    body = f"M0 0H{size}V{size}H0Z" + "".join(parts)
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {size} {size}" width="{size}" height="{size}" '
            f'role="img" aria-labelledby="title">\n  <title id="title">{title}</title>\n'
            f'  <path fill="#000000" fill-rule="evenodd" d="{body}"/>\n</svg>\n')


def main(out):
    os.makedirs(out, exist_ok=True)
    for state, name in NAMES.items():
        hi, lo = master(state, detail=True), master(state, detail=False)
        to_template(hi, 36).save(os.path.join(out, f"{name}@2x.png"))
        to_template(lo, 18).save(os.path.join(out, f"{name}.png"))
        title = f"InputLock menu bar icon ({state})"
        with open(os.path.join(out, f"{name}@2x.svg"), "w") as fh:
            fh.write(trace_svg(hi, 36, title))
        with open(os.path.join(out, f"{name}.svg"), "w") as fh:
            fh.write(trace_svg(lo, 18, title))
    print("ok")


if __name__ == "__main__":
    main(sys.argv[1])
