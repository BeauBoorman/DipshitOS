#!/usr/bin/env python3
"""Build the M86b companion TTF with Virelai Sans v0.10.2's pen and metrics.

Host-only tool. It never modifies the external pipeline. Example:
  /opt/homebrew/bin/python3 user/go/icons/generate.py \
    --pipeline /path/to/virelai-sans \
    --out image/fonts/VirelaiChrome-Regular.ttf

The base Virelai Sans cannot carry this inventory: its U+E001 is the
sexiburger mark. This font contains only the thirty contract glyphs.
"""
import argparse
import math
import sys
from pathlib import Path


def polygon(points, OutContour):
    c = OutContour(points[0])
    for point in points[1:]:
        c.line_to(point)
    return c


def draw(p, geom, design):
    """The thirty silhouettes, all on the pipeline's 1000 UPM grid."""
    pt, Arc, OutContour = geom.pt, geom.Arc, geom.OutContour

    def line(a, b):
        return p.line(pt(*a), pt(*b), cap=("round",))

    def poly(points, closed=False):
        return p.poly([pt(*v) for v in points], closed=closed,
                      join="round", cap=("round",))

    def ring(x=500, y=300, r=310):
        return p.ring(pt(x, y), r)

    def disk(x, y, r):
        return OutContour(pt(x + r, y)).arc_to(Arc(pt(x, y), r, 0, 360))

    def box(x0, y0, x1, y1):
        return design.rect_contour(x0, y0, x1, y1)

    shapes = {}
    shapes[0xE000] = line((250, 50), (750, 550)) + line((250, 550), (750, 50))
    shapes[0xE001] = [box(200, 60, 800, 180)]
    shapes[0xE002] = poly([(210, 40), (790, 40), (790, 620), (210, 620)], True)
    shapes[0xE003] = (
        poly([(340, 150), (340, 660), (830, 660), (830, 150)], False)
        + poly([(170, 30), (650, 30), (650, 510), (170, 510)], True)
    )
    # Pin head on = filled; off = open. Both share the same stem and tip.
    pin_stem = line((500, 100), (500, 290)) + [
        polygon([pt(400, 115), pt(600, 115), pt(500, -40)], OutContour)
    ]
    shapes[0xE004] = [disk(500, 480, 180)] + pin_stem
    shapes[0xE005] = ring(500, 480, 125) + pin_stem
    shapes[0xE006] = poly([(650, 620), (330, 330), (650, 40)])
    shapes[0xE007] = poly([(350, 620), (670, 330), (350, 40)])
    shapes[0xE008] = poly([(180, 160), (500, 490), (820, 160)])
    shapes[0xE009] = poly([(180, 500), (500, 170), (820, 500)])
    shapes[0xE00A] = poly([(190, 290), (400, 80), (810, 580)])
    shapes[0xE00B] = line((500, 30), (500, 630)) + line((200, 330), (800, 330))
    shapes[0xE00C] = ring(440, 400, 230) + line((610, 230), (820, 20))
    # One toothed outer silhouette with a separate counter, no boolean seams.
    teeth = []
    for i in range(32):
        angle = math.pi * 2 * i / 32
        radius = 350 if i % 4 in (0, 1) else 275
        teeth.append(pt(500 + radius * math.cos(angle),
                        320 + radius * math.sin(angle)))
    shapes[0xE00D] = [polygon(teeth, OutContour), disk(500, 320, 140).reverse()]
    shapes[0xE00E] = [polygon([
        pt(140, 30), pt(860, 30), pt(860, 490),
        pt(485, 490), pt(390, 610), pt(140, 610),
    ], OutContour)]
    shapes[0xE00F] = (
        poly([(220, 0), (220, 650), (590, 650), (780, 460), (780, 0)], True)
        + poly([(590, 650), (590, 460), (780, 460)])
    )
    shapes[0xE010] = (
        poly([(500, 660), (130, 10), (870, 10)], True)
        + line((500, 240), (500, 440)) + [disk(500, 130, 60)]
    )
    shapes[0xE011] = (
        ring() + line((365, 165), (635, 435))
        + line((365, 435), (635, 165))
    )
    shapes[0xE012] = ring() + line((500, 150), (500, 355)) + [disk(500, 475, 62)]
    shapes[0xE013] = (
        p.arc(pt(500, 360), 230, 0, 180)
        + [box(190, 0, 810, 385)]
    )
    # Batch 2 (contract v2, M104g): the controls/seat shapes, same pen.
    shapes[0xE014] = (
        line((250, 520), (750, 520))
        + line((250, 330), (750, 330))
        + line((250, 140), (750, 140))
    )
    shapes[0xE015] = [disk(500, 120, 75), disk(500, 330, 75), disk(500, 540, 75)]
    shapes[0xE016] = [polygon([pt(310, 100), pt(310, 560), pt(700, 330)],
                             OutContour)]
    shapes[0xE017] = line((380, 90), (380, 570)) + line((620, 90), (620, 570))
    shapes[0xE018] = [box(260, 90, 740, 570)]
    # Dome, flared sides, rim and clapper; the dnd variant adds a slash.
    bell = (
        p.arc(pt(500, 390), 195, 0, 180)
        + line((305, 390), (250, 170))
        + line((695, 390), (750, 170))
        + line((225, 170), (775, 170))
        + [disk(500, 50, 62)]
    )
    shapes[0xE019] = bell
    shapes[0xE01A] = bell + line((250, 610), (750, 50))
    # Speaker box and cone; volume adds two waves, mute a slash instead.
    speaker = [polygon([
        pt(180, 250), pt(180, 410), pt(340, 410),
        pt(560, 580), pt(560, 80), pt(340, 250),
    ], OutContour)]
    shapes[0xE01B] = (
        speaker
        + p.arc(pt(550, 330), 135, -50, 100, cap=("round",))
        + p.arc(pt(550, 330), 295, -50, 100, cap=("round",))
    )
    shapes[0xE01C] = speaker + line((240, 580), (720, 60))
    # Grip stripes nest toward the bottom-right corner; the innermost is
    # a short mark, matching the long/medium/nub silhouette of a SE grip.
    shapes[0xE01D] = (
        line((330, 70), (790, 530))
        + line((560, 70), (790, 300))
        + line((780, 70), (800, 90))
    )
    assert len(shapes) == 30 and sorted(shapes) == list(range(0xE000, 0xE01E))
    return shapes


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--pipeline", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    args = ap.parse_args()
    sys.path.insert(0, str(args.pipeline.resolve()))

    import fontforge
    from fontTools.ttLib import TTFont
    from fontTools.ttLib.tables._c_m_a_p import CmapSubtable
    from tools import build_font as base
    from tools.virelai import design, geom

    if base.VERSION != "0.10.2":
        raise SystemExit(f"need Virelai Sans v0.10.2, got {base.VERSION}")
    p = design.Pen("Medium")
    f = base.make_skeleton("Medium")
    f.familyname = "Virelai Chrome"
    f.fontname = "VirelaiChrome-Regular"
    f.fullname = "Virelai Chrome Regular"
    f.copyright = ("Copyright 2026 draw me an elephant. Virelai Chrome "
                   "shipped under the VirelaiOS license.")
    for cp, contours in sorted(draw(p, geom, design).items()):
        g = f.createChar(cp, f"uni{cp:04X}")
        base.emit(g, contours)
        if len(contours) > 1 and cp != 0xE00D:
            g.removeOverlap()
        g.width = 1000
        g.correctDirection()
    args.out.parent.mkdir(parents=True, exist_ok=True)
    f.generate(str(args.out))
    f.close()
    # Fix the SFNT build clock so the checked-in asset is reproducible.
    font = TTFont(str(args.out), recalcTimestamp=False)
    # OpenType dates count seconds since 1904; the Unix epoch is a stable,
    # valid value in both FontForge's extra table and the SFNT header.
    epoch = 2082844800
    font["head"].created = font["head"].modified = epoch
    font["FFTM"].sourceCreated = font["FFTM"].sourceModified = epoch
    # FontForge encodes this PUA-only cmap as format 4 with a glyphIdArray.
    # The existing user/go/ttf reader handles format 12 directly; provide
    # that Unicode map too rather than changing the text parser for this card.
    full = CmapSubtable.newSubtable(12)
    full.platformID, full.platEncID, full.language = 3, 10, 0
    full.cmap = dict(font.getBestCmap())
    font["cmap"].tables.append(full)
    font.save(str(args.out))
    font.close()
    check = TTFont(str(args.out))
    cmap = check.getBestCmap()
    assert set(cmap) == set(range(0xE000, 0xE01E)), sorted(cmap)
    assert check["head"].unitsPerEm == 1000
    check.close()
    print(f"wrote {args.out}: thirty chrome glyphs at 1000 UPM")


if __name__ == "__main__":
    main()
