"""Class A: linked ELF byte fixtures, KRN2 loader simulation and refusals."""
import contextlib
import importlib.util
import io
from pathlib import Path
import struct
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("elf2bin", ROOT / "tools/elf2bin.py")
elf2bin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(elf2bin)


def linked_elf(base=0x4000):
    """Small ET_EXEC with distinct virtual/file offsets and retained RELA.

    The .rodata vector models compiler-generated pointer constants; .data
    holds a callback. Linked site bytes already contain S + signed A.
    Non-ALLOC debug ABS64 and loaded PREL64/ADR_PREL records are not patches.
    """
    data = bytearray(0xA00)
    ident = b"\x7fELF\x02\x01\x01" + bytes(9)
    struct.pack_into("<16sHHIQQQIHHHHHH", data, 0, ident, 2, 183, 1,
                     base, 64, 0x700, 0, 64, 56, 3, 64, 10, 0)
    for i, (vaddr, offset, filesz, memsz, flags) in enumerate((
            (base, 0x200, 0x20, 0x20, 5),
            (base + 0x2000, 0x300, 0x40, 0x40, 4),
            (base + 0x5000, 0x400, 0x40, 0x80, 6))):
        struct.pack_into("<IIQQQQQQ", data, 64 + i * 56, 1, flags,
                         offset, vaddr, vaddr, filesz, memsz, 16)
    data[0x200:0x204] = b"\xc0\x03\x5f\xd6"  # ret
    struct.pack_into("<Q", data, 0x308, base + 0x5014 + 12)
    struct.pack_into("<Q", data, 0x318, base + 4 - 4)
    struct.pack_into("<I", data, 0x320, base + 0x5014 - 4)
    struct.pack_into("<Q", data, 0x328, 0x1234)  # already-linked PREL64
    struct.pack_into("<Q", data, 0x410, base + 4 + 8)
    struct.pack_into("<Q", data, 0x480, base + 4)
    strings = b"\0callback\0object\0"
    data[0x540:0x540 + len(strings)] = strings
    # Elf64_Sym: null, text callback, data object.
    struct.pack_into("<IBBHQQ", data, 0x500 + 24, 1, 0x12, 0, 1, base + 4, 4)
    struct.pack_into("<IBBHQQ", data, 0x500 + 48, 10, 0x11, 0, 3, base + 0x5014, 8)
    ro_relocs = [(base + 0x2008, 2, 257, 12),
                 (base + 0x2018, 1, 257, -4),
                 (base + 0x2020, 2, 258, -4),
                 (base + 0x2028, 1, 260, 0)]
    for i, (site, symbol, typ, addend) in enumerate(ro_relocs):
        struct.pack_into("<QQq", data, 0x580 + i * 24, site,
                         symbol << 32 | typ, addend)
    struct.pack_into("<QQq", data, 0x600, base + 0x5010, 1 << 32 | 257, 8)
    struct.pack_into("<QQq", data, 0x618, 0, 1 << 32 | 257, 0)
    sections = [
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        (0, 1, 6, base, 0x200, 0x20, 0, 0, 16, 0),
        (0, 1, 2, base + 0x2000, 0x300, 0x40, 0, 0, 16, 0),
        (0, 1, 3, base + 0x5000, 0x400, 0x40, 0, 0, 16, 0),
        (0, 1, 0, 0, 0x480, 8, 0, 0, 1, 0),
        (0, 2, 0, 0, 0x500, 72, 6, 1, 8, 24),
        (0, 3, 0, 0, 0x540, len(strings), 0, 0, 1, 0),
        (0, 4, 0, 0, 0x580, 96, 5, 2, 8, 24),
        (0, 4, 0, 0, 0x600, 24, 5, 3, 8, 24),
        (0, 4, 0, 0, 0x618, 24, 5, 4, 8, 24),
    ]
    for i, section in enumerate(sections):
        struct.pack_into("<IIQQQQIIQQ", data, 0x700 + i * 64, *section)
    return data


def section_field(data, index, offset, fmt, value):
    struct.pack_into(fmt, data, 0x700 + index * 64 + offset, value)


class Elf2BinTests(unittest.TestCase):
    def convert(self, data, **options):
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / "in.elf", Path(directory) / "out.bin"
            source.write_bytes(data)
            # A refused conversion must leave an existing output untouched.
            output.write_bytes(b"previous-good-image")
            log = io.StringIO()
            with contextlib.redirect_stdout(log), contextlib.redirect_stderr(log):
                rc = elf2bin.build(source, output, **options)
            return rc, output.read_bytes(), log.getvalue()

    def refuse(self, data, message, **options):
        rc, output, log = self.convert(data, relocs=True, **options)
        self.assertEqual(rc, 1, log)
        self.assertEqual(output, b"previous-good-image")
        self.assertIn(message, log)

    def test_linked_sites_values_and_nonzero_load_base(self):
        for link_base in (0, 0x4000, 0x7FFF0000):
            with self.subTest(link_base=link_base):
                data = linked_elf(link_base)
                rc, image, log = self.convert(data, relocs=True)
                self.assertEqual(rc, 0, log)
                header = elf2bin.read_header(image)
                self.assertEqual(header, {
                    "magic": elf2bin.MAGIC_RELOC, "flags": 0,
                    "entry_offset": 40, "image_size": 40 + 0x5080 + 4 * 24,
                    "reloc_offset": 40 + 0x5080, "reloc_count": 4})
                records = [struct.unpack_from("<QQII", image, header["reloc_offset"] + i * 24)
                           for i in range(4)]
                self.assertEqual(records, [(0x2008, 0x5020, 8, 0),
                                           (0x2018, 0, 8, 0),
                                           (0x2020, 0x5010, 4, 0),
                                           (0x5010, 12, 8, 0)])
                before = image[40:header["reloc_offset"]]
                content = bytearray(before)
                load_base = 0x7DD25000
                changed = set()
                for offset, value, width, _ in records:
                    self.assertLessEqual(offset + width, len(content))
                    fmt = "<Q" if width == 8 else "<I"
                    mask = (1 << (width * 8)) - 1
                    linked = struct.unpack_from(fmt, before, offset)[0]
                    self.assertEqual(value, (linked - link_base) & mask)
                    struct.pack_into(fmt, content, offset, (load_base + value) & mask)
                    changed.update(range(offset, offset + width))
                self.assertEqual(struct.unpack_from("<Q", content, 0x2008)[0], load_base + 0x5020)
                self.assertEqual(struct.unpack_from("<Q", content, 0x2018)[0], load_base)
                self.assertEqual(struct.unpack_from("<I", content, 0x2020)[0], load_base + 0x5010)
                self.assertEqual(struct.unpack_from("<Q", content, 0x5010)[0], load_base + 12)
                self.assertEqual(content[0x2028:0x2030], before[0x2028:0x2030])
                self.assertTrue(all(a == b for i, (a, b) in enumerate(zip(before, content))
                                    if i not in changed))
                self.assertEqual(content[0x5040:], bytes(0x40))  # BSS
                # ABS32 uses the loader's low 32 bits even at a >4 GiB base.
                high_base = 0x100004000
                for offset, value, width, _ in records:
                    fmt = "<Q" if width == 8 else "<I"
                    mask = (1 << (width * 8)) - 1
                    struct.pack_into(fmt, content, offset, (high_base + value) & mask)
                self.assertEqual(struct.unpack_from("<I", content, 0x2020)[0], 0x9010)
                self.assertEqual(struct.unpack_from("<Q", content, 0x2008)[0], high_base + 0x5020)

    def test_pc_relative_records_are_not_relocations(self):
        data = linked_elf()
        struct.pack_into("<Q", data, 0x588, 1 << 32 | 275)  # ADR_PREL_PG_HI21
        rc, image, log = self.convert(data, relocs=True)
        self.assertEqual(rc, 0, log)
        self.assertEqual(elf2bin.read_header(image)["reloc_count"], 3)

    def test_unsorted_records_are_emitted_in_site_order(self):
        data = linked_elf()
        first, second = bytes(data[0x580:0x598]), bytes(data[0x598:0x5B0])
        data[0x580:0x598], data[0x598:0x5B0] = second, first
        loads = elf2bin._parse_loads(data)
        self.assertEqual(elf2bin._collect_abs_relocs(data, 0x4000, loads)[0],
                         (0x2008, 0x5020, 8))

    def test_section_and_segment_full_width_boundaries(self):
        for site in (0x6000 - 1, 0x6039, 0x6040, 0x9000):
            with self.subTest(site=site):
                data = linked_elf()
                struct.pack_into("<Q", data, 0x580, site)
                self.refuse(data, "outside file-backed target section")
        data = linked_elf()
        struct.pack_into("<Q", data, 64 + 56 + 32, 0xC)  # site starts in filesz, ends out
        self.refuse(data, "outside file-backed PT_LOAD")
        data = linked_elf()
        struct.pack_into("<Q", data, 0x580, 0x6038)  # last valid ABS64 site
        struct.pack_into("<Q", data, 0x338, 0x9020)
        rc, _, log = self.convert(data, relocs=True)
        self.assertEqual(rc, 0, log)

    def test_bss_or_inconsistent_mapping_refused(self):
        data = linked_elf()
        section_field(data, 3, 4, "<I", 8)
        self.refuse(data, "outside file-backed target section")
        data = linked_elf()
        section_field(data, 2, 24, "<Q", 0x308)
        self.refuse(data, "file mapping disagrees")

    def test_malformed_relocation_tables_refused(self):
        for field, fmt, value, message in (
                (44, "<I", 10, "target section index"),
                (44, "<I", 0, "target section index"),
                (40, "<I", 10, "symbol-table index"),
                (40, "<I", 6, "symbol-table layout"),
                (56, "<Q", 0, "entry size"),
                (56, "<Q", 8, "entry size"),
                (32, "<Q", 95, "table length"),
                (24, "<Q", 0x9F0, "outside ELF file")):
            with self.subTest(field=field, value=value):
                data = linked_elf()
                section_field(data, 7, field, fmt, value)
                self.refuse(data, message)

    def test_unsupported_relocation_types_refused(self):
        for typ in (259, 263, 272, 512, 573, 999, 1025, 1026, 1027, 1032):
            with self.subTest(typ=typ):
                data = linked_elf()
                struct.pack_into("<Q", data, 0x588, 2 << 32 | typ)
                self.refuse(data, "unhandled relocation type %d" % typ)
        for typ in (9, 19):
            data = linked_elf()
            section_field(data, 7, 4, "<I", typ)
            self.refuse(data, "SHT_REL/SHT_RELR relocations are unsupported")

    def test_unsupported_symbols_refused(self):
        data = linked_elf()
        struct.pack_into("<Q", data, 0x588, 3 << 32 | 257)
        self.refuse(data, "symbol index out of range")
        for shndx in (0, 0xFFF1, 0xFFF2, 10, 4):
            with self.subTest(shndx=shndx):
                data = linked_elf()
                struct.pack_into("<H", data, 0x500 + 48 + 6, shndx)
                self.refuse(data, "image-relative defined symbol")
        data = linked_elf()
        struct.pack_into("<Q", data, 0x500 + 48 + 8, 0xFFFFFFFF)
        self.refuse(data, "symbol outside its section")

    def test_overlapping_or_duplicate_sites_refused(self):
        for site in (0x6008, 0x600C):
            with self.subTest(site=site):
                data = linked_elf()
                struct.pack_into("<Q", data, 0x598, site)
                # Keep the linked bytes consistent even for overlapping sites.
                struct.pack_into("<q", data, 0x598 + 16,
                                 int.from_bytes(data[0x300 + site - 0x6000:
                                                     0x300 + site - 0x6000 + 8],
                                                "little") - 0x4004)
                self.refuse(data, "overlapping absolute relocation sites")

    def test_unlinked_or_corrupt_symbol_addend_values_refused(self):
        data = linked_elf()
        struct.pack_into("<Q", data, 0x308, 0)
        self.refuse(data, "linked value disagrees with symbol+addend")
        data = linked_elf()
        struct.pack_into("<q", data, 0x590, 13)
        self.refuse(data, "linked value disagrees with symbol+addend")

    def test_invalid_elf_headers_and_loads_refused(self):
        for offset, fmt, value, message in (
                (16, "<H", 1, "only linked ET_EXEC"),
                (16, "<H", 3, "only linked ET_EXEC"),
                (4, "<B", 1, "only ELF64 little-endian"),
                (5, "<B", 2, "only ELF64 little-endian"),
                (6, "<B", 2, "unsupported ELF version"),
                (18, "<H", 62, "not AArch64"),
                (52, "<H", 0, "ELF header size"),
                (54, "<H", 8, "program-header layout"),
                (32, "<Q", 0x9FF, "program-header table"),
                (40, "<Q", 0x9FF, "section-header table"),
                (58, "<H", 0, "section-header layout"),
                (60, "<H", 0, "section-header layout"),
                (24, "<Q", 0x5000, "entry point outside executable"),
                (64, "<I", 2, "dynamic/interpreted/TLS"),
                (64, "<I", 3, "dynamic/interpreted/TLS"),
                (64, "<I", 7, "dynamic/interpreted/TLS"),
                (64 + 32, "<Q", 0x21, "invalid PT_LOAD"),
                (64 + 8, "<Q", 0x9FF, "PT_LOAD content"),
                (64 + 16, "<Q", (1 << 64) - 1, "invalid PT_LOAD"),
                (64 + 56 + 16, "<Q", 0x4000, "overlapping PT_LOAD")):
            with self.subTest(offset=offset, value=value):
                data = linked_elf()
                struct.pack_into(fmt, data, offset, value)
                self.refuse(data, message)
        self.refuse(b"\x7fELF", "truncated ELF64 header")
        self.refuse(b"not an ELF", "not an ELF")
        self.refuse(linked_elf(0x4001), "link base must be 4K-aligned")

    def test_stripped_krn2_refused_but_flat_supported(self):
        data = linked_elf()
        struct.pack_into("<Q", data, 40, 0)
        struct.pack_into("<H", data, 60, 0)
        self.refuse(data, "requires retained ELF")
        rc, image, log = self.convert(data, allow_writable=True)
        self.assertEqual(rc, 0, log)
        self.assertEqual(elf2bin.read_header(image)["magic"], elf2bin.MAGIC)

    def test_legacy_flat_and_segmented_formats_unchanged(self):
        data = linked_elf()
        rc, _, log = self.convert(data)
        self.assertEqual(rc, 2)
        self.assertIn("writable PT_LOAD", log)
        rc, image, log = self.convert(data, allow_writable=True)
        self.assertEqual(rc, 0, log)
        self.assertEqual(image[:24], struct.pack("<IIQQ", elf2bin.MAGIC, 0, 24, 24 + 0x5080))
        self.assertEqual(image[24 + 0x2000:24 + 0x2040], data[0x300:0x340])
        rc, image, log = self.convert(data, segments=True)
        self.assertEqual(rc, 0, log)
        self.assertEqual(image[:48], struct.pack("<IIQQQQQ", elf2bin.MAGIC_SEGMENTS,
                                               0, 48, 48 + 0x5000 + 0x40,
                                               0x5000, 0x40, 0x80))
        self.assertEqual(image[48 + 0x5000:], data[0x400:0x440])
        rc, _, log = self.convert(data, relocs=True, segments=True)
        self.assertEqual(rc, 2)
        self.assertIn("mutually exclusive", log)

    def test_loader_ceiling_includes_header_and_table(self):
        self.assertEqual(elf2bin.KERNEL_MAX_SIZE, 33554432)  # M129b #2611: 16→32 MiB
        for excess in (0, 1):
            with self.subTest(excess=excess), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "out.bin"
                output.write_bytes(b"previous-good-image")
                size = elf2bin.KERNEL_MAX_SIZE - 40 - 24 + excess
                if excess:
                    with self.assertRaisesRegex(ValueError, "total=33554433 over=1"):
                        elf2bin._build_flat_reloc("fixture", output, 0, 0,
                                                 bytearray(size), [], [(0, 8, 8)])
                    self.assertEqual(output.read_bytes(), b"previous-good-image")
                else:
                    with contextlib.redirect_stdout(io.StringIO()):
                        rc = elf2bin._build_flat_reloc("fixture", output, 0, 0,
                                                      bytearray(size), [], [(0, 8, 8)])
                    self.assertEqual(rc, 0)
                    self.assertEqual(output.stat().st_size, 33554432)
        data = linked_elf()
        struct.pack_into("<Q", data, 64 + 2 * 56 + 40, 1 << 40)
        self.refuse(data, "loader ceiling: content=1099511648256 table=96")


if __name__ == "__main__":
    unittest.main()
