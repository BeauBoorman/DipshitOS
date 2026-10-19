"""Pinned bitmap glyph masks in a real 1280x720 guest scanout."""

from pathlib import Path
import struct
import zlib


def check(path, out):
    raw = Path(path).read_bytes()
    width, height = 1280, 720
    assert len(raw) == width * height * 4, "missing full guest scanout"
    # The launcher is the #2054 left-edge strip: emblem + prompt + filter
    # field, then manifest rows at y=140+24*i, labels at x=14 (a dimmed row
    # paints its label at +3 and its reason at +13). Glyph masks are the
    # shared 8x8 bitmap face (the gate share stages no FONTS.TXT, so the
    # seat's degrade path paints them), first-lit-pixel ink vs cell bg.
    glyphs = [
        ("prompt", 8, 88, [99, 99, 99, 107, 127, 119, 99, 0]),
        ("Code Editor", 14, 194, [60, 102, 3, 3, 3, 102, 60, 0]),
        ("Files (dimmed)", 14, 215, [127, 70, 22, 30, 22, 6, 15, 0]),
        ("Binary not staged", 14, 225, [63, 102, 102, 62, 102, 102, 63, 0]),
        ("Terminal", 14, 242, [63, 45, 12, 12, 12, 12, 30, 0]),
    ]
    for name, x, y, rows in glyphs:
        def pixel(dx, dy):
            at = ((y + dy) * width + x + dx) * 4
            return raw[at:at+3]
        bg = pixel(7, 7)
        dx, dy = next((dx, dy) for dy, bits in enumerate(rows)
                      for dx in range(8) if bits & (1 << dx))
        ink = pixel(dx, dy)
        assert min(abs(a-b) for a, b in zip(ink, bg)) >= 32, name + " unreadable"
        for dy, bits in enumerate(rows):
            for dx in range(8):
                assert pixel(dx, dy) == (ink if bits & (1 << dx) else bg), name + " glyph mismatch"
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    rgb = bytearray()
    for y in range(height):
        rgb.append(0)
        for x in range(width):
            at = (y * width + x) * 4
            rgb.extend((raw[at+2], raw[at+1], raw[at]))
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(rgb)) + chunk(b"IEND", b"")
    Path(out).write_bytes(png)
    print("readable available labels and missing-binary reason in guest pixels")
