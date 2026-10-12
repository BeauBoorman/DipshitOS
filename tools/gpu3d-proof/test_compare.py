#!/usr/bin/env python3
"""Tests for tools/gpu3d-proof/compare.py (M102f1, issue #2170).

The synthetic images here are produced by an independent scanline
rasterizer (edge-intersection fill), NOT by reusing the comparator's
point-in-triangle math — so a wrong comparator cannot pass a wrong image
through a shared bug. Every rejection is exact: a flipped, channel-swapped,
strided-wrong, stale or occlusion-wrong image is refused, and only the
pinned <=2px edge band is excluded.
"""
import json
import struct
import sys
import tempfile
import unittest
import zlib
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import compare as C  # noqa: E402

FIXTURES = Path(__file__).resolve().parents[2] / "test/fixtures/gpu3d/pixels.json"


def load_scene(name):
    fx = json.loads(FIXTURES.read_text())
    return fx, fx["scenes"][name]


def fill_triangle_rows(img, w, verts, color):
    """Classic scanline fill: intersect each edge with the row's centre
    line, sort crossings, fill pairs. Different rasterizer from the
    comparator's — edge pixels may legitimately differ inside the band."""
    h = len(img) // (w * 4)
    b, g, r = color[2], color[1], color[0]
    for y in range(h):
        scan = y + 0.5
        xs = []
        for i in range(3):
            x0, y0 = verts[i]
            x1, y1 = verts[(i + 1) % 3]
            if y0 == y1:
                continue
            if min(y0, y1) <= scan < max(y0, y1):
                xs.append(x0 + (scan - y0) * (x1 - x0) / (y1 - y0))
        xs.sort()
        for i in range(0, len(xs) - 1, 2):
            x0 = int(xs[i] + 0.5)
            x1 = int(xs[i + 1] + 0.5)
            for x in range(max(0, x0), min(w, x1)):
                o = (y * w + x) * 4
                img[o], img[o + 1], img[o + 2], img[o + 3] = b, g, r, 255


def synth(name, scene=None, tri=None, margin_color=None, extra=None):
    """Build a scene-conformant BGRA image with the test's own rasterizer."""
    fx, sc = load_scene(name)
    scene = scene or sc
    w, h = scene["width"], scene["height"]
    img = bytearray(w * h * 4)
    render = scene.get("render", [0, 0, w, h])
    margin = margin_color if margin_color is not None else scene.get("margin")
    clear = scene["clear"]
    for y in range(h):
        for x in range(w):
            inside = render[0] <= x < render[0] + render[2] and \
                render[1] <= y < render[1] + render[3]
            c = clear if inside else (margin or clear)
            o = (y * w + x) * 4
            img[o], img[o + 1], img[o + 2], img[o + 3] = c[2], c[1], c[0], 255
    t = tri or scene["triangle"]
    fill_triangle_rows(img, w, t["vertices"], t["color"])
    for g in scene.get("guards", []):
        gx, gy, gw, gh = g["rect"]
        for y in range(gy, gy + gh):
            for x in range(gx, gx + gw):
                o = (y * w + x) * 4
                c = g["color"]
                img[o], img[o + 1], img[o + 2], img[o + 3] = c[2], c[1], c[0], 255
    if extra:
        extra(img, w, h)
    return bytes(img)


def encode_png_rgb(rgb, w, h):
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body +
                struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff))
    rows = b"".join(b"\0" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def encode_png_rgba(rgba, w, h):
    def chunk(kind, body):
        return (struct.pack(">I", len(body)) + kind + body +
                struct.pack(">I", zlib.crc32(kind + body) & 0xffffffff))
    rows = b"".join(b"\0" + rgba[y * w * 4:(y + 1) * w * 4] for y in range(h))
    return (b"\x89PNG\r\n\x1a\n" +
            chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)) +
            chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def bgra_to_rgb(bgra):
    out = bytearray()
    for i in range(0, len(bgra), 4):
        out.extend((bgra[i + 2], bgra[i + 1], bgra[i]))
    return bytes(out)


def bgra_to_rgba(bgra):
    out = bytearray()
    for i in range(0, len(bgra), 4):
        out.extend((bgra[i + 2], bgra[i + 1], bgra[i], bgra[i + 3]))
    return bytes(out)


class CompareTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        path = self.dir / name
        path.write_bytes(data)
        return str(path)

    def ok(self, image, scene, **kw):
        return C.compare(image, scene, fixtures_path=FIXTURES, **kw)

    def bad(self, image, scene, **kw):
        with self.assertRaises(C.CompareError):
            C.compare(image, scene, fixtures_path=FIXTURES, **kw)

    # --- accepts ------------------------------------------------------------

    def test_good_triangle_raw(self):
        img = synth("triangle")
        r = self.ok(self.write("t.bgra", img), "triangle")
        self.assertGreater(r["interior"], 0)

    def test_good_mixed_raw(self):
        img = synth("mixed")
        self.ok(self.write("m.bgra", img), "mixed")

    def test_good_resized_raw(self):
        img = synth("resized")
        self.ok(self.write("r.bgra", img), "resized")

    def test_good_triangle_png_rgb(self):
        img = synth("triangle")
        _, sc = load_scene("triangle")
        png = encode_png_rgb(bgra_to_rgb(img), sc["width"], sc["height"])
        self.ok(self.write("t.png", png), "triangle")

    def test_good_triangle_png_rgba(self):
        img = synth("triangle")
        _, sc = load_scene("triangle")
        png = encode_png_rgba(bgra_to_rgba(img), sc["width"], sc["height"])
        self.ok(self.write("t.png", png), "triangle")

    # --- rejects ------------------------------------------------------------

    def test_blank_frame_rejected(self):
        _, sc = load_scene("triangle")
        self.bad(self.write("b.bgra", bytes(sc["width"] * sc["height"] * 4)),
                 "triangle")

    def test_clear_only_rejected(self):
        """The revert-fails named test: with the interior check disabled a
        clear-only frame passes wrongly; with it on, this must reject."""
        fx, sc = load_scene("triangle")
        img = bytearray(sc["width"] * sc["height"] * 4)
        c = sc["clear"]
        for o in range(0, len(img), 4):
            img[o:o + 4] = bytes((c[2], c[1], c[0], 255))
        self.bad(self.write("c.bgra", bytes(img)), "triangle")

    def test_flipped_rejected(self):
        _, sc = load_scene("triangle")
        w, h = sc["width"], sc["height"]
        img = bytearray(synth("triangle"))
        flipped = bytearray(len(img))
        for y in range(h):
            src = img[y * w * 4:(y + 1) * w * 4]
            flipped[(h - 1 - y) * w * 4:(h - y) * w * 4] = src
        self.bad(self.write("f.bgra", bytes(flipped)), "triangle")

    def test_channel_swapped_rejected(self):
        img = bytearray(synth("triangle"))
        for o in range(0, len(img), 4):
            img[o], img[o + 2] = img[o + 2], img[o]
        self.bad(self.write("s.bgra", bytes(img)), "triangle")

    def test_wrong_stride_rejected(self):
        _, sc = load_scene("triangle")
        w, h = sc["width"], sc["height"]
        # A padded-stride file: same pixels, wrong byte layout — the
        # length contract refuses it before any pixel is read.
        padded = bytearray()
        good = synth("triangle")
        for y in range(h):
            padded.extend(good[y * w * 4:(y + 1) * w * 4])
            padded.extend(b"\x00" * 16)
        self.bad(self.write("p.bgra", bytes(padded)), "triangle")
        # And a declared stride that does not match the file refuses too.
        with self.assertRaises(C.CompareError):
            C.compare(self.write("q.bgra", good), "triangle",
                      fixtures_path=FIXTURES, geometry="64x48:80")

    def test_stale_rejected(self):
        """Pixels from an older generation (the triangle somewhere else)
        are not the current scene."""
        _, sc = load_scene("triangle")
        stale_verts = [[v[0] + 24, v[1] + 12] for v in sc["triangle"]["vertices"]]
        img = synth("triangle", tri={"color": sc["triangle"]["color"],
                                     "vertices": stale_verts})
        self.bad(self.write("old.bgra", img), "triangle")

    def test_wrong_occlusion_rejected(self):
        """Guard pixels outside the render destination: margin pixels that
        carry render content, or guards that lost their colour."""
        # margin region polluted with the clear colour (a stray render write)
        def pollute(img, w, h):
            for y in range(60, 68):
                for x in range(8, 16):
                    o = (y * w + x) * 4
                    img[o:o + 4] = bytes((48, 32, 16, 255))  # BGR of clear
        self.bad(self.write("o.bgra", synth("mixed", extra=pollute)), "mixed")

    def test_guard_expectation_wrong_colour_rejected(self):
        """A fixture-side wrong expectation is also refused: honest guards
        cannot be re-blessed to whatever the image shows."""
        fx = json.loads(FIXTURES.read_text())
        fx["scenes"]["triangle"]["guards"][0]["color"] = [255, 0, 0]
        alt = self.write("alt.json", json.dumps(fx).encode())
        img = synth("triangle")
        with self.assertRaises(C.CompareError):
            C.compare(self.write("g.bgra", img), "triangle",
                      fixtures_path=alt)

    def test_nonopaque_alpha_rejected(self):
        def transparent(img, w, h):
            img[3] = 128
        self.bad(self.write("a.bgra", synth("triangle", extra=transparent)),
                 "triangle")

    def test_outside_pixel_pollution_rejected(self):
        """One triangle-coloured pixel far outside the shape is a
        clear/outside violation, not noise."""
        def speck(img, w, h):
            o = (h - 2) * w * 4 + (w - 2) * 4
            img[o:o + 4] = bytes((0, 0, 255, 255))
        self.bad(self.write("x.bgra", synth("triangle", extra=speck)),
                 "triangle")

    def test_geometry_mismatch_rejected(self):
        _, sc = load_scene("triangle")
        img = synth("triangle")
        short = img[: len(img) - 4]
        self.bad(self.write("short.bgra", short), "triangle")
        png = encode_png_rgb(bgra_to_rgb(img[: (sc["height"] - 8) * sc["width"] * 4]),
                             sc["width"], sc["height"] - 8)
        self.bad(self.write("dim.png", png), "triangle")

    def test_missing_fixture_scene_rejected(self):
        img = synth("triangle")
        with self.assertRaises(C.CompareError):
            C.compare(self.write("n.bgra", img), "nosuchscene",
                      fixtures_path=FIXTURES)

    def test_corrupt_png_rejected(self):
        img = synth("triangle")
        _, sc = load_scene("triangle")
        png = bytearray(encode_png_rgb(bgra_to_rgb(img), sc["width"], sc["height"]))
        png[30] ^= 0xFF  # corrupt an IDAT/CRC region
        self.bad(self.write("bad.png", bytes(png)), "triangle")


if __name__ == "__main__":
    unittest.main()
