#!/usr/bin/env python3
"""Draw the README wordmark from the bundled Fraunces variable font.

The interface sets the wordmark in Fraunces at weight 600 with a small optical
size. Running this script keeps the SVG letterforms identical to the app
instead of relying on whatever serif the reader's browser has. Write the pair
from a checkout root:

    python3 docs/figures/wordmark.py

Needs fontTools with brotli support (the system tooling in the project shell
has both). The two SVGs are committed next to the other figures; the README
loads them with a prefers-color-scheme picture.
"""
from pathlib import Path

from fontTools.pens.boundsPen import BoundsPen
from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "static/fonts/fraunces-300-900.woff2"
OUT = ROOT / "docs/figures"
TEXT = "eza"
TRACKING = -0.02  # em, matches the app wordmark letter-spacing
INK_LIGHT = "#1A2340"
INK_DARK = "#E9E3D6"
ACCENT_LIGHT = "#8A2B20"
ACCENT_DARK = "#C98A3E"


def load_glyphs():
    font = TTFont(SRC)
    inst = instantiateVariableFont(font, {"wght": 600, "opsz": 144}, inplace=False)
    upm = inst["head"].unitsPerEm
    glyphset = inst.getGlyphSet()
    cmap = inst.getBestCmap()
    hmtx = inst["hmtx"]
    return inst, upm, glyphset, cmap, hmtx


def main():
    _inst, upm, glyphset, cmap, hmtx = load_glyphs()

    drawn = []
    pen_x = 0.0
    for i, ch in enumerate(TEXT):
        gname = cmap[ord(ch)]
        glyph = glyphset[gname]
        pen = SVGPathPen(glyphset)
        glyph.draw(pen)
        drawn.append((pen_x, pen.getCommands(), gname))
        pen_x += hmtx[gname][0] + (TRACKING * upm if i != len(TEXT) - 1 else 0)

    # Ink bounds in font units, baseline at y=0, y up.
    xmin = ymin = 1e9
    xmax = ymax = -1e9
    for x, _d, gname in drawn:
        bp = BoundsPen(glyphset)
        glyphset[gname].draw(bp)
        if bp.bounds is None:
            continue
        bx0, by0, bx1, by1 = bp.bounds
        xmin, xmax = min(xmin, bx0 + x), max(xmax, bx1 + x)
        ymin, ymax = min(ymin, by0), max(ymax, by1)

    ink_w = xmax - xmin
    ink_h = ymax - ymin
    pad = upm * 0.05
    rule_h = upm * 0.016
    rule_gap = upm * 0.10
    vb_x = xmin - pad
    vb_w = ink_w + 2 * pad
    rule_y = pad + ink_h + rule_gap * 0.55
    vb_h = rule_y + rule_h + pad * 0.6

    def path_group(x, d):
        return (
            f'<g transform="translate({x - vb_x:.2f} {-(-ymax - pad):.2f}) scale(1 -1)">'
            f'<path d="{d}"/></g>'
        )

    def build(fill, accent):
        body = "".join(path_group(x, d) for x, d, _g in drawn)
        rule_w = ink_w * 0.30
        rule_x = vb_x + (vb_w - rule_w) / 2
        return (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {vb_w:.2f} {vb_h:.2f}"'
            f' width="{vb_w / 20:.0f}" height="{vb_h / 20:.0f}">\n'
            f'  <g fill="{fill}">\n    {body}\n  </g>\n'
            f'  <rect x="{rule_x:.2f}" y="{rule_y:.2f}" width="{rule_w:.2f}"'
            f' height="{rule_h:.2f}" fill="{accent}"/>\n'
            "</svg>\n"
        )

    (OUT / "wordmark-light.svg").write_text(build(INK_LIGHT, ACCENT_LIGHT))
    (OUT / "wordmark-dark.svg").write_text(build(INK_DARK, ACCENT_DARK))
    print(f"wrote {OUT / 'wordmark-light.svg'} and {OUT / 'wordmark-dark.svg'}")


if __name__ == "__main__":
    main()
