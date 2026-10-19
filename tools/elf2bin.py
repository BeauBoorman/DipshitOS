#!/usr/bin/env python3
"""Convert a Zig aarch64-freestanding ELF executable into the VirelaiOS flat
kernel image (KERNEL.BIN). Pure Python 3 standard library only.

Format v1 (see docs/decisions/0002-kernel-handoff.md):

  offset 0:  u32 magic        = 0x314B5344 ("DSK1")
  offset 4:  u32 flags        = 0
  offset 8:  u64 entry_offset  (bytes from the START OF THE FILE -- i.e.
             including this 24-byte header -- to the entry point; the loader
             jumps to base + entry_offset)
  offset 16: u64 image_size    (total file size, including this 24-byte header)
  offset 24: loadable content  (PT_LOAD segments placed at their vaddr
             relative to the lowest segment vaddr, preserving the linker's
             exact relative layout so PC-relative addressing (adr/adrp)
             stays valid when the loader places the image at any 4K-aligned
             base; memsz > filesz regions are zero-filled for BSS)

Format v2 ("KRN2", the kernel only; issue #1042) adds a relocation table so
the loader can place the image at any base even when the compiler emitted
absolute (base-0) references that PC-relative addressing cannot fix — LLVM
jump tables and outlined-function pointer tables are the observed cases:

  offset 0:  u32 magic        = 0x324E524B ("KRN2")
  offset 4:  u32 flags        = 0
  offset 8:  u64 entry_offset  (file-relative; includes the 40-byte header)
  offset 16: u64 image_size    (total file size, header + content + relocs)
  offset 24: u64 reloc_offset  (file offset of the relocation table)
  offset 32: u64 reloc_count   (number of 24-byte entries)
  offset 40: loadable content
  after content: reloc_count × { u64 offset, u64 value, u32 width, u32 _ }
             the loader writes (value + kernel_base) at content offset
             `offset`, as `width` (8 or 4) bytes.

The relocation records come from an ELF linked with lld `--emit-relocs`; the
input must be a static ET_EXEC and keep its symbol/reloc sections (build.zig sets
`link_emit_relocs` and clears `strip`). Every absolute relocation
(R_AARCH64_ABS64/ABS32) whose target lies in a PT_LOAD segment is captured;
an unsupported relocation type in loadable content is a hard build failure, so
an unrelocated pointer table can never silently ship again.

The still-valid v1 contract: any reference the linker resolves PC-relatively
(adr/adrp) needs no relocation table entry — the loader places content at
base+0 preserving the linker's exact relative layout.

Usage:
  elf2bin.py INPUT.elf OUTPUT.bin     # build the flat kernel image
  elf2bin.py --relocs INPUT.elf OUT   # kernel image + absolute-reloc table
  elf2bin.py --info FILE.bin          # print the header fields
"""

import struct
import sys

PT_LOAD = 1
ET_EXEC = 2
EM_AARCH64 = 183
MAGIC = 0x314B5344  # "DSK1"
MAGIC_SEGMENTS = 0x334B5344  # "DSK3" — segmented user image (milestone 16 C1)
MAGIC_RELOC = 0x324E524B  # "KRN2" — kernel image with absolute-reloc table
HEADER_SIZE = 24
HEADER_SIZE_SEGMENTS = 48
HEADER_SIZE_RELOC = 40
RELOC_ENTRY_SIZE = 24
KERNEL_MAX_SIZE = 32 * 1024 * 1024  # boot/src/main.zig's loader ceiling (M129b #2611: 16→32 — the 64-slot process registry's fixed BSS)

SHT_SYMTAB = 2
SHT_RELA = 4
SHT_NOBITS = 8
SHT_REL = 9
SHT_RELR = 19
SHF_ALLOC = 0x2
R_AARCH64_ABS64 = 257
R_AARCH64_ABS32 = 258
R_AARCH64_ABS16 = 259
# Already-linked PC-relative data/instructions and position-independent
# ADRP+low12 / GOT pairs. Standalone absolute MOVW and TLS are not supported.
LINKED_POSITION_INDEPENDENT_RELOCS = {
    0, 260, 261, 262, 273, 274, 275, 276, 277, 278, 279, 280,
    282, 283, 284, 285, 286, 287, 288, 289, 290, 291, 292, 293, 299, 311, 312,
}

PF_X = 1
PF_W = 2


def read_header(data):
    magic, flags, entry_offset, image_size = struct.unpack_from("<IIQQ", data, 0)
    h = {"magic": magic, "flags": flags,
         "entry_offset": entry_offset, "image_size": image_size,
         "reloc_offset": None, "reloc_count": 0}
    if magic == MAGIC_RELOC and len(data) >= HEADER_SIZE_RELOC:
        h["reloc_offset"], h["reloc_count"] = struct.unpack_from("<QQ", data, 24)
    return h


def _check_range(data, offset, size, what):
    if offset > len(data) or size > len(data) - offset:
        raise ValueError("%s outside ELF file" % what)


def _parse_loads(data):
    """Return the list of (vaddr, p_offset, filesz, memsz, p_flags) PT_LOAD
    segments in the ELF, rejecting malformed or unsupported headers."""
    e_phoff = struct.unpack_from("<Q", data, 32)[0]
    e_phentsize = struct.unpack_from("<H", data, 54)[0]
    e_phnum = struct.unpack_from("<H", data, 56)[0]
    if e_phentsize != 56 or e_phnum == 0xFFFF:
        raise ValueError("unsupported ELF program-header layout")
    _check_range(data, e_phoff, e_phnum * e_phentsize, "program-header table")
    loads = []
    for i in range(e_phnum):
        off = e_phoff + i * e_phentsize
        typ = struct.unpack_from("<I", data, off)[0]
        if typ in (2, 3, 7):  # PT_DYNAMIC, PT_INTERP, PT_TLS
            raise ValueError("dynamic/interpreted/TLS ELF inputs are unsupported")
        if typ != PT_LOAD:
            continue
        p_flags = struct.unpack_from("<I", data, off + 4)[0]
        p_offset = struct.unpack_from("<Q", data, off + 8)[0]
        p_vaddr = struct.unpack_from("<Q", data, off + 16)[0]
        p_filesz, p_memsz = struct.unpack_from("<QQ", data, off + 32)
        if p_filesz > p_memsz or p_vaddr + p_memsz > 1 << 64:
            raise ValueError("invalid PT_LOAD file/memory size")
        _check_range(data, p_offset, p_filesz, "PT_LOAD content")
        loads.append((p_vaddr, p_offset, p_filesz, p_memsz, p_flags))
    previous_end = 0
    for vaddr, _, _, memsz, _ in sorted(loads):
        if vaddr < previous_end:
            raise ValueError("overlapping PT_LOAD segments are unsupported")
        previous_end = vaddr + memsz
    return loads


def _parse_sections(data):
    """Return the ELF section headers as dicts (empty list if stripped)."""
    e_shoff = struct.unpack_from("<Q", data, 40)[0]
    e_shentsize, e_shnum = struct.unpack_from("<HH", data, 58)
    if e_shoff == 0 and e_shnum == 0:
        return []
    if e_shentsize != 64 or e_shnum == 0:
        raise ValueError("unsupported ELF section-header layout")
    _check_range(data, e_shoff, e_shnum * e_shentsize, "section-header table")
    secs = []
    for i in range(e_shnum):
        off = e_shoff + i * e_shentsize
        (name, typ, flags, addr, soff, size, link, info,
         align, entsize) = struct.unpack_from("<IIQQQQIIQQ", data, off)
        if typ != SHT_NOBITS:
            _check_range(data, soff, size, "section %d content" % i)
        if flags & SHF_ALLOC and addr + size > 1 << 64:
            raise ValueError("section %d address range overflows" % i)
        secs.append({"name": name, "typ": typ, "flags": flags, "addr": addr,
                     "off": soff, "size": size, "link": link, "info": info,
                     "align": align, "entsize": entsize})
    return secs


def _collect_abs_relocs(data, base, loads):
    """Return [(blob_offset, value, width)] for every absolute relocation
    (R_AARCH64_ABS64/ABS32) in file-backed loadable content. In ET_EXEC,
    r_offset is the site's virtual address, NOT a section-relative offset.
    Read the already-linked symbol+addend value, then normalize it to the
    image's link base so the loader can add its actual content base."""
    if struct.unpack_from("<H", data, 16)[0] != ET_EXEC:
        raise ValueError("absolute relocation collection requires linked ET_EXEC")
    secs = _parse_sections(data)
    if not secs:
        raise ValueError("--relocs requires retained ELF section/relocation headers")
    out = []
    for s in secs:
        if s["typ"] in (SHT_REL, SHT_RELR):
            raise ValueError("SHT_REL/SHT_RELR relocations are unsupported; use SHT_RELA")
        if s["typ"] != SHT_RELA:
            continue
        if not 0 < s["info"] < len(secs):
            raise ValueError("invalid relocation target section index")
        if s["entsize"] != 24 or s["size"] % 24:
            raise ValueError("invalid SHT_RELA entry size or table length")
        if not 0 < s["link"] < len(secs):
            raise ValueError("invalid relocation symbol-table index")
        symtab = secs[s["link"]]
        if (symtab["typ"] != SHT_SYMTAB or symtab["entsize"] != 24
                or symtab["size"] % 24):
            raise ValueError("unsupported relocation symbol-table layout")
        tgt = secs[s["info"]]
        if not tgt["flags"] & SHF_ALLOC:
            continue
        for o in range(s["off"], s["off"] + s["size"], 24):
            r_offset, r_info, r_addend = struct.unpack_from("<QQq", data, o)
            r_type = r_info & 0xFFFFFFFF
            if r_type not in (R_AARCH64_ABS64, R_AARCH64_ABS32):
                # 260 is PREL64, not ABS8: it is already PC-relative.
                if r_type not in LINKED_POSITION_INDEPENDENT_RELOCS:
                    raise ValueError(
                        "unhandled relocation type %d in %s@0x%x "
                        "(no loader support)" % (r_type, "loaded section",
                                                 r_offset))
                if r_type and not tgt["addr"] <= r_offset < tgt["addr"] + tgt["size"]:
                    raise ValueError("relocation site outside target section")
                continue  # PC-relative / instruction fixup, already applied
            width = 8 if r_type == R_AARCH64_ABS64 else 4
            section_offset = r_offset - tgt["addr"]
            if (section_offset < 0 or section_offset + width > tgt["size"]
                    or tgt["typ"] == SHT_NOBITS):
                raise ValueError("absolute relocation site 0x%x outside "
                                 "file-backed target section" % r_offset)
            backing = [(v, poff) for v, poff, fsz, _, _ in loads
                       if v <= r_offset and r_offset + width <= v + fsz]
            if len(backing) != 1:
                raise ValueError("absolute relocation site 0x%x outside "
                                 "file-backed PT_LOAD content" % r_offset)
            loc = tgt["off"] + section_offset
            vaddr, poff = backing[0]
            if loc != poff + r_offset - vaddr:
                raise ValueError("relocation section/PT_LOAD file mapping disagrees")
            symbol = r_info >> 32
            if symbol >= symtab["size"] // 24:
                raise ValueError("absolute relocation symbol index out of range")
            symoff = symtab["off"] + symbol * 24
            shndx, symvalue = struct.unpack_from("<HQ", data, symoff + 6)
            if not 0 < shndx < len(secs) or not secs[shndx]["flags"] & SHF_ALLOC:
                raise ValueError("absolute relocation requires an image-relative "
                                 "defined symbol (undefined/absolute/common unsupported)")
            symsec = secs[shndx]
            if not symsec["addr"] <= symvalue <= symsec["addr"] + symsec["size"]:
                raise ValueError("absolute relocation symbol outside its section")
            if not any(v <= symvalue <= v + m for v, _, _, m, _ in loads):
                raise ValueError("absolute relocation symbol outside PT_LOAD content")
            value = struct.unpack_from("<Q" if width == 8 else "<I", data, loc)[0]
            mask = (1 << (width * 8)) - 1
            if value != ((symvalue + r_addend) & mask):
                raise ValueError("absolute relocation linked value disagrees "
                                 "with symbol+addend")
            # lld has already applied the signed RELA addend. Do not add it
            # again. Match the loader's width-truncated wrapping arithmetic.
            value = (value - base) & mask
            out.append((r_offset - base, value, width))
    out.sort()
    for previous, current in zip(out, out[1:]):
        if previous[0] + previous[2] > current[0]:
            raise ValueError("overlapping absolute relocation sites")
    return out


def _krn2_image_size(content_size, reloc_count):
    image_size = HEADER_SIZE_RELOC + content_size + reloc_count * RELOC_ENTRY_SIZE
    if image_size > KERNEL_MAX_SIZE:
        raise ValueError("KRN2 image exceeds %d-byte loader ceiling: "
                         "content=%d table=%d header=%d total=%d over=%d"
                         % (KERNEL_MAX_SIZE, content_size,
                            reloc_count * RELOC_ENTRY_SIZE, HEADER_SIZE_RELOC,
                            image_size, image_size - KERNEL_MAX_SIZE))
    return image_size


def _build_flat_reloc(input_path, output_path, e_entry, base, blob, loads, relocs):
    """Emit the "KRN2" kernel image: v1 flat content plus the absolute-reloc
    table the loader applies before the cache flush (issue #1042)."""
    entry_offset = HEADER_SIZE_RELOC + e_entry - base
    if entry_offset < HEADER_SIZE_RELOC or entry_offset >= HEADER_SIZE_RELOC + len(blob):
        print("elf2bin: entry offset %#x outside loadable content" % entry_offset,
              file=sys.stderr)
        return 1
    reloc_offset = HEADER_SIZE_RELOC + len(blob)
    image_size = _krn2_image_size(len(blob), len(relocs))
    header = struct.pack("<IIQQQQ", MAGIC_RELOC, 0, entry_offset, image_size,
                         reloc_offset, len(relocs))
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(bytes(blob))
        for off, value, width in relocs:
            f.write(struct.pack("<QQII", off, value, width, 0))
    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "(%d PT_LOAD segment(s), %d absolute reloc(s))"
          % (input_path, output_path, entry_offset, image_size,
             len(loads), len(relocs)))
    return 0


def build(input_path, output_path, segments=False, allow_writable=False,
          relocs=False):
    try:
        return _build(input_path, output_path, segments, allow_writable, relocs)
    except ValueError as error:
        print("elf2bin: %s" % error, file=sys.stderr)
        return 1


def _build(input_path, output_path, segments, allow_writable, relocs):
    with open(input_path, "rb") as f:
        data = f.read()

    if data[:4] != b"\x7fELF":
        print("elf2bin: %s is not an ELF file" % input_path, file=sys.stderr)
        return 1
    if len(data) < 64:
        raise ValueError("truncated ELF64 header")
    if data[4] != 2 or data[5] != 1:
        print("elf2bin: only ELF64 little-endian is supported", file=sys.stderr)
        return 1
    if data[6] != 1 or struct.unpack_from("<I", data, 20)[0] != 1:
        raise ValueError("unsupported ELF version")
    if struct.unpack_from("<H", data, 16)[0] != ET_EXEC:
        raise ValueError("only linked ET_EXEC ELF inputs are supported")
    if struct.unpack_from("<H", data, 52)[0] != 64:
        raise ValueError("unsupported ELF header size")
    e_machine = struct.unpack_from("<H", data, 18)[0]
    if e_machine != EM_AARCH64:
        print("elf2bin: %s is not AArch64 (machine %d)" % (input_path, e_machine),
              file=sys.stderr)
        return 1

    e_entry = struct.unpack_from("<Q", data, 24)[0]
    loads = _parse_loads(data)
    if not loads:
        print("elf2bin: %s has no PT_LOAD segments" % input_path, file=sys.stderr)
        return 1
    if not any(v <= e_entry < v + fsz and flags & PF_X
               for v, _, fsz, _, flags in loads):
        raise ValueError("entry point outside executable PT_LOAD content")

    # Lay the segments out relative to the lowest vaddr, preserving the
    # linker's relative layout exactly (gaps stay zero-filled).
    base = min(v for v, _, _, _, _ in loads)
    end = max(v + m for v, _, _, m, _ in loads)
    if relocs and segments:
        print("elf2bin: --relocs and --segments are mutually exclusive",
              file=sys.stderr)
        return 2
    if relocs and base % 4096:
        raise ValueError("KRN2 link base must be 4K-aligned for ADRP addressing")
    abs_relocs = _collect_abs_relocs(data, base, loads) if relocs else []
    if relocs:
        # Check the entire encoded size before allocating even the content.
        _krn2_image_size(end - base, len(abs_relocs))
    blob = bytearray(end - base)
    for vaddr, poff, fsz, memsz, _pflags in loads:
        rel = vaddr - base
        blob[rel:rel + fsz] = data[poff:poff + fsz]
        # (memsz > fsz tail stays zero: BSS)

    if relocs:
        return _build_flat_reloc(input_path, output_path, e_entry, base, blob,
                                 loads, abs_relocs)
    if segments:
        return _build_segmented(input_path, output_path, data, e_entry,
                                loads, base, blob)
    # A flat (DSK1) image is mapped read-only by the kernel `exec` path, so
    # any writable .data/.bss content would fault on the FIRST store — the
    # exact failure VICTIM.BIN hit (data abort at 0x400a50, its .bss tail
    # inside the read-only text region) and NOTEPAD before its DSK3
    # conversion. Refuse unless the caller exempts the image with
    # --allow-writable (ONLY for a flat image whose loader maps RW itself,
    # i.e. the kernel — never for an exec'd user program).
    if not allow_writable:
        writable = [load for load in loads if load[4] & PF_W and load[3] > 0]
        if writable:
            print(
                "elf2bin: %s: writable PT_LOAD segment(s) in a flat image "
                "(no --segments). DSK1 maps the whole file read-only under "
                "kernel `exec`, so the first store to .data/.bss would fault. "
                "Build it segmented instead: user/linker-segmented.ld + "
                "elf2bin.py --segments." % input_path,
                file=sys.stderr,
            )
            for vaddr, _poff, fsz, memsz, fl in writable:
                print("  writable PT_LOAD: vaddr=0x%x filesz=%d memsz=%d "
                      "flags=0x%x" % (vaddr, fsz, memsz, fl), file=sys.stderr)
            return 2
    return _build_flat(input_path, output_path, e_entry, base, blob, loads)


def _build_flat(input_path, output_path, e_entry, base, blob, loads):
    # entry_offset is file-relative (the loader jumps to base + entry_offset,
    # and the loadable content starts after the 24-byte header).
    entry_offset = HEADER_SIZE + e_entry - base
    if entry_offset < HEADER_SIZE or entry_offset >= HEADER_SIZE + len(blob):
        print("elf2bin: entry offset %#x outside loadable content" % entry_offset,
              file=sys.stderr)
        return 1

    header = struct.pack("<IIQQ", MAGIC, 0, entry_offset, HEADER_SIZE + len(blob))
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(bytes(blob))

    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "(content %d bytes from %d PT_LOAD segment(s))"
          % (input_path, output_path, entry_offset, HEADER_SIZE + len(blob),
             len(blob), len(loads)))
    return 0


def _build_segmented(input_path, output_path, data, e_entry, loads, base, blob):
    """Emit the segmented DSK3 user image (milestone 16 C1): a 48-byte header
    carrying the RX text size, the initialized RW data size, and the total RW
    (data + zeroed BSS) size, followed by [text+rodata][data] (the BSS tail is
    implicit zero-fill, never stored). The loader maps text EL0-RO+PXN and the
    data region EL0-RW+UXN+PXN."""
    # The first writable segment's vaddr is the text/data boundary (the
    # linker script page-aligns .data, so `text_size` is page-aligned).
    data_start = end_of = base
    for v, _, _, m, _ in loads:
        end_of = max(end_of, v + m)
    writable_starts = [v for v, _, _, _, fl in loads if fl & PF_W]
    if writable_starts:
        data_start = min(writable_starts)
    else:
        data_start = end_of

    text_size = data_start - base
    data_file_size = 0
    data_mem_size = 0
    for vaddr, poff, fsz, memsz, fl in loads:
        if not (fl & PF_W):
            continue
        rel = vaddr - base
        # data content is stored in the blob right after the text region.
        if rel < text_size:
            print("elf2bin: %s writable segment overlaps the RX region"
                  % input_path, file=sys.stderr)
            return 1
        data_file_size += fsz
        data_mem_size += memsz

    if text_size == 0 or text_size % 4096 != 0:
        print("elf2bin: %s text_size %#x is not page-aligned "
              "(align .data to 4096 in the linker script)"
              % (input_path, text_size), file=sys.stderr)
        return 1

    entry_offset = HEADER_SIZE_SEGMENTS + e_entry - base
    if entry_offset < HEADER_SIZE_SEGMENTS or entry_offset >= HEADER_SIZE_SEGMENTS + text_size:
        print("elf2bin: entry offset %#x outside the RX region" % entry_offset,
              file=sys.stderr)
        return 1

    image_size = HEADER_SIZE_SEGMENTS + text_size + data_file_size
    header = struct.pack("<IIQQQQQ", MAGIC_SEGMENTS, 0, entry_offset, image_size,
                         text_size, data_file_size, data_mem_size)
    content = bytes(blob[:text_size + data_file_size])
    with open(output_path, "wb") as f:
        f.write(header)
        f.write(content)

    print("elf2bin: %s -> %s: entry_offset=0x%x image_size=%d "
          "text=%d data=%d (bss tail %d) from %d PT_LOAD segment(s)"
          % (input_path, output_path, entry_offset, image_size,
             text_size, data_file_size, data_mem_size - data_file_size,
             len(loads)))
    return 0


def main(argv):
    # argv is sys.argv[1:] (script name already removed).
    if len(argv) == 2 and argv[0] == "--info":
        with open(argv[1], "rb") as f:
            data = f.read()
        if len(data) < HEADER_SIZE:
            print("elf2bin: %s too small to be a kernel image" % argv[1],
                  file=sys.stderr)
            return 1
        h = read_header(data)
        extra = ""
        if h["reloc_offset"] is not None:
            extra = " reloc_offset=0x%x reloc_count=%d" % (
                h["reloc_offset"], h["reloc_count"])
        print("kernel image %s: magic=0x%08x flags=%d entry_offset=0x%x "
              "image_size=%d%s" % (argv[1], h["magic"], h["flags"],
                                   h["entry_offset"], h["image_size"], extra))
        if h["magic"] not in (MAGIC, MAGIC_SEGMENTS, MAGIC_RELOC):
            print("elf2bin: WARNING: magic mismatch (not a VirelaiOS kernel "
                  "image?)", file=sys.stderr)
            return 1
        return 0

    segments = False
    allow_writable = False
    relocs = False
    while argv and argv[0] in ("--segments", "--allow-writable", "--relocs"):
        if argv[0] == "--segments":
            segments = True
        elif argv[0] == "--allow-writable":
            allow_writable = True
        else:
            relocs = True
        argv = argv[1:]
    if len(argv) != 2:
        print("usage: elf2bin.py [--segments] [--allow-writable] [--relocs] "
              "INPUT.elf OUTPUT.bin | elf2bin.py --info FILE.bin",
              file=sys.stderr)
        return 2
    return build(argv[0], argv[1], segments=segments,
                 allow_writable=allow_writable, relocs=relocs)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
