"""The loader rules the kernel enforces, checked from the host.

One copy on purpose. Two class-B specs check a GUEST-BUILT ELF against exactly
these rules before a later boot is allowed to execute it:

  * ``go-hello.spec`` run 07 (the monitor-driven link, M70c-S1T / #1543), and
  * ``live-selfhost-go.spec`` run 01 (the guest-sequenced build loop, M70c-S2 /
    #1544).

A rule that drifts in one copy is worse than a rule that is missing: the host
would pass an image the kernel then refuses, and the failure would surface as a
boot-time refusal far from the check that lied. The constants below mirror
``kernel/src/exec.zig`` (``exec_image_max``/``load_max``, ``max_segments``, the
argv+envp block) and ``kernel/src/elf.zig`` (``load_max``, ``map_max``,
``gap_base_max``) -- KEEP IN SYNC with THOSE, not with a sibling spec.

M72a (#1579) SPLIT that rule: the loader bounds INITIALIZED bytes (``Σ filesz``)
by ``load_max`` and MAPPED bytes (``Σ memsz``, which it eagerly allocates and
zeroes) by ``map_max``. This copy charged ``Σ memsz`` against the 32 MiB file
bound, so it refused -- from the host, before any boot -- exactly the images
the kernel had just learned to accept, which is the drift this module exists to
prevent.

Usage from a spec's ``vgate_assert <tag> python`` body::

    import os, sys
    sys.path.insert(0, os.path.join("tools", "lib"))
    import elf_rules

    line, fails = elf_rules.check_file(elf_path)
    print("in-guest link: " + line)
    if fails:
        for f in fails:
            print("FAIL: " + f)
        sys.exit(1)
"""

import struct

# kernel/src/exec.zig exec_image_max / elf.load_max: 32 MiB, charged on the
# file (and on Σ filesz, which cannot exceed it).
MAX_IMAGE = 33554432
# kernel/src/elf.zig map_max: 64 MiB, charged on Σ memsz (M72a #1579).
MAP_MAX = 67108864
# kernel/src/elf.zig gap_base_max: no segment may reach into the kernel/hole.
GAP_BASE_MAX = 0x1000_0000
# Historical: the kernel once packed argv+envp into the data segment's
# tail slack and refused ELFs whose last segment left < 0x908 bytes.
# b1c0c953 (M71m, #1572) replaced that with sizing the last segment's
# pages to cover align8(mem_size)+argv+envp, so the image's own tail
# slack is no longer required — the figure below is reported, not gated.
NEED_SLACK = 0x908
# kernel/src/exec.zig max_segments.
MAX_SEGMENTS = 3
# AArch64 e_machine.
EM_AARCH64 = 183


def load(path):
    """Read an ELF whole. The guest's images are single-digit MiB; a build
    product larger than MAX_IMAGE is refused by the rule check anyway."""
    with open(path, "rb") as fh:
        return fh.read()


def header_fails(data):
    """The class/machine header rules, reported before any segment rule (an
    image that is not a 64-bit little-endian AArch64 ELF has no segments worth
    reading)."""
    fails = []
    if data[:4] != b"\x7fELF":
        return ["not an ELF (first bytes %r)" % data[:4]]
    if data[4] != 2 or data[5] != 1:
        fails.append("not a 64-bit little-endian ELF (class=%d data=%d)"
                     % (data[4], data[5]))
    if struct.unpack_from("<H", data, 0x12)[0] != EM_AARCH64:
        fails.append("not AArch64 (e_machine=%d)"
                     % struct.unpack_from("<H", data, 0x12)[0])
    return fails


def program_segments(data):
    """The PT_LOAD segments as (flags, vaddr, filesz, memsz), ascending by
    vaddr -- the order the W^X rules below are stated in."""
    entry = struct.unpack_from("<Q", data, 0x18)[0]
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phes = struct.unpack_from("<H", data, 0x36)[0]
    pnum = struct.unpack_from("<H", data, 0x38)[0]
    segs = []
    for i in range(pnum):
        t, fl, off, va, pa, fsz, msz, al = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + i * phes)
        if t == 1:
            segs.append((fl, va, fsz, msz))
    segs.sort(key=lambda s: s[1])
    return entry, segs


def check(data):
    """Every rule, as (entry, segs, total_memsz, slack, fails). Pure: the
    caller decides what to print and how to fail."""
    entry, segs = program_segments(data)
    fails = []
    if not segs:
        fails.append("no PT_LOAD segments")
    if len(segs) > MAX_SEGMENTS:
        fails.append("%d PT_LOAD > max_segments %d" % (len(segs), MAX_SEGMENTS))
    total_file = sum(s[2] for s in segs)
    if total_file > MAX_IMAGE:
        fails.append("sum filesz %d > load_max %d" % (total_file, MAX_IMAGE))
    total = sum(s[3] for s in segs)
    if total > MAP_MAX:
        fails.append("sum memsz %d > map_max %d" % (total, MAP_MAX))
    for fl, va, fsz, msz in segs:
        if va + msz > GAP_BASE_MAX:
            fails.append("segment at %#x crosses gap_base_max" % va)
        if va & 4095:
            fails.append("segment at %#x unaligned" % va)
    # W^X order: the read/execute segment leads, the writable one trails.
    if segs and segs[0][0] & 2:
        fails.append("segment 0 writable")
    if segs and not (segs[-1][0] & 2):
        fails.append("last segment not writable")
    if segs and not (segs[0][1] <= entry < segs[0][1] + segs[0][2]):
        fails.append("entry %#x not in segment 0 initialized bytes" % entry)
    # The slack figure is reported (not gated): the kernel sizes the last
    # segment's pages to cover align8(mem_size)+argv+envp, so the image's
    # own tail slack no longer decides exec-with-args.
    slack = (-segs[-1][3]) % 4096 if segs else 0
    if len(data) > MAX_IMAGE:
        fails.append("file %d > exec_image_max" % len(data))
    return entry, segs, total, slack, fails


def describe(name, data, segs, total, slack):
    """The one-line receipt both specs print: bytes, segment count, sum memsz
    (decimal and hex) and the writable-slack figure. ``memsz`` is the MAPPED
    total, the one ``map_max`` bounds; the file bound applies to the file and
    to Σ filesz (not printed here -- the file size is)."""
    return ("%s %d bytes, %d segments, memsz %d (%#x), slack %#x"
            % (name, len(data), len(segs), total, total, slack))


def check_file(path, name=None):
    """Read + check + describe in one call. Returns (receipt, fails); fails
    carries the caller's FAIL text, prefix-free."""
    data = load(path)
    fails = header_fails(data)
    if fails:
        return ("%s unreadable as an ELF" % (name or path.split("/")[-1])), fails
    _, segs, total, slack, rule_fails = check(data)
    return (describe(name or path.split("/")[-1], data, segs, total, slack),
            rule_fails)
