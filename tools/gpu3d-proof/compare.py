#!/usr/bin/env python3
"""M102f1 (issue #2170) independent GPU3D pixel comparator.

Decodes a receipt image — the demo's raw packed-BGRA surface export, or a
PNG capture in the repo's existing 8-bit RGB/RGBA non-interlaced shape —
and checks it against the ORIGINAL geometry fixture in
test/fixtures/gpu3d/pixels.json. The expected image is described as
geometry (triangle vertices, clear colour, margin colour, guard rects); this
script rasterizes the expectation itself. It imports no production
renderer/encoder and stores no golden pixels.

Checks, all exact (the only slack is the fixture's pinned <=2px raster edge
band; there is no image-wide tolerance):

  - decode/format: PNG or raw BGRA at the declared geometry; wrong length,
    stride or dimensions reject
  - alpha: every pixel opaque, exactly
  - channel order: colours are compared per channel in the fixture's BGRA
    order, so a swapped image cannot pass
  - orientation: the asymmetric triangle's inside/outside map catches
    flips/mirrors/rotations
  - triangle interior: pixels inside the triangle farther than the edge
    band from every edge equal the triangle colour exactly, and at least
    `min_interior` such pixels exist (a blank or clear-only frame cannot
    pass)
  - clear/outside: pixels outside the triangle farther than the edge band
    equal the clear colour exactly
  - margin: when the scene declares a render sub-rect, every pixel outside
    it equals the margin colour — a write outside the render destination
    is a rejection, not a guard sample
  - guards: every declared guard rect's pixels equal its colour (chrome /
    occlusion / corner probes)

Usage: compare.py IMAGE SCENE [--fixtures PATH] [--geometry WxH[:STRIDE]]
  IMAGE  .bgra/.raw packed receipt or .png capture
  SCENE  key in the fixture's scenes map (triangle|mixed|resized)
  --geometry  raw-receipt pixel geometry; stride defaults to width. Without
              it a raw image must be exactly scene stride*height*4 bytes.

CHECK_INTERIOR below is the interior check the card's revert-fails proof
disables: with it off, a clear-only frame wrongly passes.
"""
import json
import math
import struct
import sys
import zlib
from pathlib import Path

FIXTURES = Path("test/fixtures/gpu3d/pixels.json")

CHECK_INTERIOR = True


class CompareError(Exception):
    pass


def _u32be(b, off):
    return struct.unpack_from(">I", b, off)[0]


def decode_png_bgra(path):
    """Decode an 8-bit RGB/RGBA non-interlaced PNG to (bgra_bytes, w, h).

    Same contract as the repo's existing first-party readers (the
    web-proof comparator's decoder): signature, chunk CRCs, the five row
    filters and exact inflate length are all verified; anything else is a
    refusal, never a best-effort read.
    """
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise CompareError("bad PNG signature: %s" % path)
    at, compressed, width, height, channels = 8, bytearray(), 0, 0, 0
    while at < len(data):
        size = _u32be(data, at)
        kind, body = data[at + 4:at + 8], data[at + 8:at + 8 + size]
        if len(body) != size or at + 12 + size > len(data):
            raise CompareError("truncated PNG: %s" % path)
        crc = _u32be(data, at + 8 + size)
        if zlib.crc32(kind + body) & 0xffffffff != crc:
            raise CompareError("PNG CRC mismatch: %s" % path)
        if kind == b"IHDR":
            width, height, depth, color, comp, filt, interlace = \
                struct.unpack(">IIBBBBB", body)
            if depth != 8 or color not in (2, 6) or comp or filt or interlace:
                raise CompareError("unsupported PNG shape: %s" % path)
            channels = 3 if color == 2 else 4
        elif kind == b"IDAT":
            compressed.extend(body)
        at += 12 + size
    if not width or not height:
        raise CompareError("PNG missing IHDR: %s" % path)
    stride = width * channels
    stream = zlib.decompressobj()
    raw = stream.decompress(bytes(compressed), (stride + 1) * height + 1)
    if len(raw) != (stride + 1) * height or not stream.eof or stream.unused_data:
        raise CompareError("PNG inflate mismatch: %s" % path)
    previous = bytearray(stride)
    bgra = bytearray()
    for y in range(height):
        start = y * (stride + 1)
        mode, row = raw[start], bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - channels] if x >= channels else 0
            up = previous[x]
            corner = previous[x - channels] if x >= channels else 0
            if mode == 0:
                add = 0
            elif mode == 1:
                add = left
            elif mode == 2:
                add = up
            elif mode == 3:
                add = (left + up) // 2
            elif mode == 4:
                p = left + up - corner
                dist = (abs(p - left), abs(p - up), abs(p - corner))
                add = (left, up, corner)[dist.index(min(dist))]
            else:
                raise CompareError("bad PNG filter %d: %s" % (mode, path))
            row[x] = (row[x] + add) & 255
        for x in range(width):
            px = row[x * channels:x * channels + channels]
            bgra.extend((px[2], px[1], px[0], px[3] if channels == 4 else 255))
        previous = row
    return bytes(bgra), width, height


def decode_raw_bgra(path, width, height, stride):
    """Read a raw strided-BGRA receipt at the declared geometry."""
    data = Path(path).read_bytes()
    if width <= 0 or height <= 0 or stride < width:
        raise CompareError("raw geometry %dx%d stride=%d is not plausible"
                           % (width, height, stride))
    want = stride * height * 4
    if len(data) != want:
        raise CompareError("raw receipt length %d, want %d (%dx%d stride=%d)"
                           % (len(data), want, width, height, stride))
    if stride == width:
        return bytes(data)
    packed = bytearray()
    for y in range(height):
        packed.extend(data[y * stride * 4:(y * stride + width) * 4])
    return bytes(packed)


def load_scene(fixtures_path, name):
    fx = json.loads(Path(fixtures_path).read_text())
    if fx.get("version") != 1 or fx.get("channel_order") != "BGRA":
        raise CompareError("fixture is not version-1 BGRA")
    scenes = fx.get("scenes", {})
    if name not in scenes:
        raise CompareError("no scene %r in fixtures (have %s)"
                           % (name, ",".join(sorted(scenes))))
    scene = scenes[name]
    for key in ("width", "height", "clear", "triangle", "min_interior"):
        if key not in scene:
            raise CompareError("scene %r missing %s" % (name, key))
    tri = scene["triangle"]
    if len(tri.get("vertices", [])) != 3 or len(tri.get("color", [])) != 3:
        raise CompareError("scene %r malformed triangle" % name)
    scene["_edge_band"] = fx.get("edge_band_px", 0)
    scene["_alpha"] = fx.get("alpha", 255)
    if not (0 <= scene["_edge_band"] <= 2):
        raise CompareError("edge band %r exceeds the pinned <=2px"
                           % scene["_edge_band"])
    return scene


def parse_geometry(text):
    parts = text.split(":")
    wh = parts[0].lower().split("x")
    if len(wh) != 2:
        raise CompareError("--geometry must be WxH[:STRIDE]")
    w, h = int(wh[0]), int(wh[1])
    stride = int(parts[1]) if len(parts) > 1 else w
    return w, h, stride


def _edge_sign(px, py, a, b):
    return (b[0] - a[0]) * (py - a[1]) - (b[1] - a[1]) * (px - a[0])


def _seg_dist(px, py, a, b):
    vx, vy = b[0] - a[0], b[1] - a[1]
    wx, wy = px - a[0], py - a[1]
    n = vx * vx + vy * vy
    t = 0.0 if n == 0 else max(0.0, min(1.0, (wx * vx + wy * vy) / n))
    return math.hypot(px - (a[0] + t * vx), py - (a[1] + t * vy))


class _Triangle:
    """The independent expected rasterizer: pixel-centre inside test plus
    distance-to-edge, no renderer anywhere."""

    def __init__(self, verts):
        self.v = verts
        # Signed area; sign decides which edge direction means "inside".
        a, b, c = verts
        self.sign = 1 if _edge_sign(c[0], c[1], a, b) >= 0 else -1

    def inside(self, x, y):
        px, py = x + 0.5, y + 0.5
        a, b, c = self.v
        s1 = _edge_sign(px, py, a, b) * self.sign
        s2 = _edge_sign(px, py, b, c) * self.sign
        s3 = _edge_sign(px, py, c, a) * self.sign
        return s1 >= 0 and s2 >= 0 and s3 >= 0

    def edge_dist(self, x, y):
        px, py = x + 0.5, y + 0.5
        a, b, c = self.v
        return min(_seg_dist(px, py, a, b), _seg_dist(px, py, b, c),
                   _seg_dist(px, py, c, a))


def _in_guard(guards, x, y):
    for g in guards:
        gx, gy, gw, gh = g["rect"]
        if gx <= x < gx + gw and gy <= y < gy + gh:
            return g
    return None


def compare(image_path, scene_name, fixtures_path=FIXTURES, geometry=None):
    scene = load_scene(fixtures_path, scene_name)
    sw, sh = scene["width"], scene["height"]
    band = scene["_edge_band"]
    alpha = scene["_alpha"]

    suffix = Path(image_path).suffix.lower()
    if suffix == ".png":
        bgra, w, h = decode_png_bgra(image_path)
        if (w, h) != (sw, sh):
            raise CompareError("PNG is %dx%d, scene %r wants %dx%d"
                               % (w, h, scene_name, sw, sh))
    else:
        if geometry is not None:
            w, h, stride = parse_geometry(geometry)
        else:
            w, h, stride = sw, sh, scene.get("stride", sw)
        if (w, h) != (sw, sh):
            raise CompareError("geometry %dx%d does not match scene %r %dx%d"
                               % (w, h, scene_name, sw, sh))
        bgra = decode_raw_bgra(image_path, w, h, stride)

    clear = tuple(scene["clear"])
    tri = scene["triangle"]
    trgb = tuple(tri["color"])
    verts = [tuple(map(int, v)) for v in tri["vertices"]]
    triangle = _Triangle(verts)
    guards = scene.get("guards", [])
    render = scene.get("render")
    margin = tuple(scene["margin"]) if "margin" in scene else None

    def px(x, y):
        o = (y * sw + x) * 4
        return bgra[o], bgra[o + 1], bgra[o + 2], bgra[o + 3]

    interior = interior_ok = clear_ok = guarded = 0
    for y in range(sh):
        for x in range(sw):
            b, g, r, a = px(x, y)
            if a != alpha:
                raise CompareError("nonopaque alpha %d at %d,%d" % (a, x, y))
            guard = _in_guard(guards, x, y)
            if guard is not None:
                guarded += 1
                if (r, g, b) != tuple(guard["color"]):
                    raise CompareError(
                        "guard pixel %d,%d is %s, want %s (%s)"
                        % (x, y, (r, g, b), tuple(guard["color"]),
                           guard.get("why", "guard")))
                continue
            # A declared render destination bounds where GPU pixels may
            # live: outside it, the margin colour is the ONLY legal pixel.
            if render is not None:
                rx, ry, rw, rh = render
                if not (rx <= x < rx + rw and ry <= y < ry + rh):
                    if margin is None or (r, g, b) != margin:
                        raise CompareError(
                            "pixel %d,%d outside render destination is %s, "
                            "want margin %s" % (x, y, (r, g, b), margin))
                    continue
            dist = triangle.edge_dist(x, y)
            if dist <= band:
                continue  # the pinned raster edge band — no opinion
            if triangle.inside(x, y):
                interior += 1
                if (r, g, b) == trgb:
                    interior_ok += 1
                elif CHECK_INTERIOR:
                    raise CompareError(
                        "interior pixel %d,%d is %s, want triangle %s"
                        % (x, y, (r, g, b), trgb))
            else:
                clear_ok += 1
                if (r, g, b) != clear:
                    raise CompareError(
                        "outside pixel %d,%d is %s, want clear %s"
                        % (x, y, (r, g, b), clear))
    if CHECK_INTERIOR:
        # The named interior check: enough inside pixels carry the triangle
        # colour — a blank or clear-only frame can never reach this count.
        if interior_ok < scene["min_interior"]:
            raise CompareError(
                "interior pixels matching triangle colour: %d, want >= %d "
                "(blank/clear-only frame)" % (interior_ok, scene["min_interior"]))
    return {
        "scene": scene_name, "width": sw, "height": sh,
        "interior": interior_ok, "outside": clear_ok,
        "guarded": guarded, "band": band,
    }


def main(argv):
    args = list(argv)
    fixtures, geometry = FIXTURES, None
    i = 0
    rest = []
    while i < len(args):
        if args[i] == "--fixtures":
            fixtures, i = args[i + 1], i + 2
        elif args[i] == "--geometry":
            geometry, i = args[i + 1], i + 2
        else:
            rest.append(args[i])
            i += 1
    if len(rest) != 2:
        raise SystemExit(
            "usage: compare.py IMAGE SCENE [--fixtures PATH] [--geometry WxH[:STRIDE]]")
    try:
        result = compare(rest[0], rest[1], fixtures_path=fixtures, geometry=geometry)
    except CompareError as exc:
        raise SystemExit("compare: " + str(exc))
    print("compare: %(scene)s %(width)sx%(height)s OK "
          "(interior=%(interior)d outside=%(outside)d guards=%(guarded)d band=%(band)d)"
          % result)


if __name__ == "__main__":
    main(sys.argv[1:])
