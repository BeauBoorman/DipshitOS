import tempfile
import unittest
from pathlib import Path

from warm_parity import compare, evidence_lines, main, normalize


COLD_SERIAL = """\
VirelaiOS kernel has seized control.
kern: scheduler online
tasks user-el0 reaped
\x1b[32mvirelai> \x1b[0mpages\r
pages: armed=1 total=0x0000000000000480 free=0x0000000000000410 excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80
\x1b[32mvirelai> \x1b[0mexec QJS.BIN /host/FILE.js --receipt=/host/FILE.R\r
qjs: file-ready
tasks user-exec reaped
procs QJS.BIN exited status=0
\x1b[32mvirelai> \x1b[0mpages\r
pages: armed=1 total=0x0000000000000480 free=0x0000000000000410 excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80
\x1b[32mvirelai> \x1b[0mprocs receipt QJS.BIN\r
runtime-receipt: pid=7 name=QJS.BIN peak_pages=42 page_cap=4096 peak_regions=1 region_cap=16 static_pages=9 page_tracking=extensible page_saturated=0 total_pages=1152 record_failures=0 unrecorded_pages=0 reaped=1
qjs-gate-done
"""

# The same leg warm: no boot bytes in the epoch (D6), a different pid and a
# different allocator map — both legitimately volatile.
WARM_SERIAL = """\
\x1b[32mvirelai> \x1b[0mpages\r
pages: armed=1 total=0x0000000000000480 free=0x000000000000040a excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80
\x1b[32mvirelai> \x1b[0mexec QJS.BIN /host/FILE.js --receipt=/host/FILE.R\r
qjs: file-ready
tasks user-exec reaped
procs QJS.BIN exited status=0
\x1b[32mvirelai> \x1b[0mpages\r
pages: armed=1 total=0x0000000000000480 free=0x000000000000040a excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80
\x1b[32mvirelai> \x1b[0mprocs receipt QJS.BIN\r
runtime-receipt: pid=11 name=QJS.BIN peak_pages=42 page_cap=4096 peak_regions=1 region_cap=16 static_pages=9 page_tracking=extensible page_saturated=0 total_pages=1152 record_failures=0 unrecorded_pages=0 reaped=1
qjs-gate-done
"""


class NormalizeTests(unittest.TestCase):
    def test_volatile_fields_collapse(self):
        self.assertEqual(
            normalize("runtime-receipt: pid=7 name=QJS.BIN peak_pages=42"),
            "runtime-receipt: pid=? name=QJS.BIN peak_pages=42")
        self.assertEqual(
            normalize("qjs-cold: sample=3 child=91 frequency=24000000 launch=123456789"),
            "qjs-cold: sample=3 child=? frequency=24000000 launch=?")
        self.assertEqual(
            normalize("qjs-bounds: cycle=140735 cycle2=1 stubs=5"),
            "qjs-bounds: cycle=? cycle2=1 stubs=5")

    def test_pages_map_stripped_but_armed_and_total_pinned(self):
        line = ("pages: armed=1 total=0x0000000000000480 free=0x000000000000040a "
                "excluded=0x0000000000000000 regions=0x0000000000000003 span=0x0000000000007f80")
        self.assertEqual(
            normalize(line),
            "pages: armed=1 total=0x0000000000000480 free=? excluded=? regions=? span=?")

    def test_ansi_and_cr_removed(self):
        self.assertEqual(normalize("\x1b[32mvirelai> \x1b[0mpages\r"), "virelai> pages")


class EvidenceTests(unittest.TestCase):
    def test_only_compared_families(self):
        lines = evidence_lines(COLD_SERIAL)
        self.assertIn("qjs: file-ready", lines)
        self.assertIn("procs QJS.BIN exited status=0", lines)
        self.assertIn("qjs-gate-done", lines)
        self.assertIn(
            "pages: armed=1 total=0x0000000000000480 free=? excluded=? regions=? span=?",
            lines)
        self.assertTrue(any(l.startswith("runtime-receipt: pid=?") for l in lines))
        # Boot-era and non-evidence lines never enter the set.
        for rejected in ("VirelaiOS kernel has seized control.", "kern: scheduler online",
                         "tasks user-el0 reaped", "tasks user-exec reaped",
                         "virelai> pages", "virelai> exec QJS.BIN /host/FILE.js --receipt=/host/FILE.R"):
            self.assertNotIn(rejected, lines)


class CompareTests(unittest.TestCase):
    def test_warm_epoch_equals_cold_after_volatile_strip(self):
        cold_only, warm_only = compare(COLD_SERIAL, WARM_SERIAL)
        self.assertEqual(cold_only, set())
        self.assertEqual(warm_only, set())

    def test_real_difference_is_not_masked(self):
        cold_only, warm_only = compare(COLD_SERIAL, WARM_SERIAL.replace("status=0", "status=70"))
        self.assertEqual(cold_only, {"procs QJS.BIN exited status=0"})
        self.assertEqual(warm_only, {"procs QJS.BIN exited status=70"})

    def test_unlisted_count_difference_fails(self):
        # peak_pages is pinned: a real memory-footprint divergence must fail.
        cold_only, warm_only = compare(COLD_SERIAL, WARM_SERIAL.replace("peak_pages=42", "peak_pages=43"))
        self.assertTrue(any("peak_pages=42" in l for l in cold_only))
        self.assertTrue(any("peak_pages=43" in l for l in warm_only))


class MainTests(unittest.TestCase):
    def _run(self, legs=("file",)):
        with tempfile.TemporaryDirectory() as td:
            art = Path(td)
            for suffix, text in (("-cold", COLD_SERIAL), ("-warm", WARM_SERIAL)):
                (art / f"live-quickjs-serial-file.log{suffix}").write_text(text)
            return main(["--artifacts", td, *legs])

    def test_parity_pass(self):
        self.assertEqual(self._run(), 0)

    def test_missing_serial_fails(self):
        with tempfile.TemporaryDirectory() as td:
            self.assertEqual(main(["--artifacts", td, "file"]), 1)


if __name__ == "__main__":
    unittest.main()
