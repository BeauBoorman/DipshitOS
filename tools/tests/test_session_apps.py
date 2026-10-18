"""Human-session staging with fake per-app builders and no VM."""
import json
import os
import plistlib
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
APPS = {
    "GOTABWM": "gotabwm", "GOSH": "gosh", "GOCALC": "gocalc",
    "GOTERM": "goterm", "NOTE": "note", "GOEDIT": "goedit",
    "GOFILES": "files", "WEB": "web", "PULSE": "pulse", "GOHELP": "help",
    "GOTOP": "gotop", "GOSET": "goset", "GOVIEW": "goview",
}
# M120a (#2558): the non-manifest persistence tools session.sh stages for
# the os-update/agent-hmac credentials.
PERSIST_TOOLS = {"GOUPD": "goupd", "AGENTD": "agentd"}

# The fake runner emulates --profile-init: an absent path is minted as a
# minimal virelaivm/1 bundle (manifest + config — the members session.sh
# reads), an existing dir loads.
RUNNER_HEAD = """#!/bin/sh
if [ "$1" = "--profile" ] && [ "$3" = "--profile-init" ]; then
    prof="$2"
    if [ ! -d "$prof" ]; then
        mkdir -p "$prof/share" "$prof/saved-state"
        printf '%s' '{"format":"virelaivm/1","identity":"org.virelaios.vm.fake","name":"fake","members":{"config":"config.json","efiVars":"efi-vars.bin","overlay":"overlay.asif","vlfs":"vlfs.img","machineIdentifier":"machine-id.bin","savedState":"saved-state","share":"share"}}' > "$prof/manifest.json"
        printf '%s' '{"baseImage":"artifacts/disk.img","cpus":2,"devices":{"dataDisk":true,"share":true},"memoryMiB":256}' > "$prof/config.json"
        printf 'profile: created %s\\n' "$prof"
    else
        printf 'profile: loaded %s\\n' "$prof"
    fi
    exit 0
fi
"""

# The fake mkfs.vlfs: --check is clean iff the image carries the magic
# word a format writes; format writes that magic and logs the call so a
# test can prove "no reformat on later boots".
FAKE_MKFS = """#!/bin/sh
if [ "$1" = "--check" ]; then
    if [ -f "$2" ] && grep -q VLFSMAGIC "$2" 2>/dev/null; then
        echo "check: clean"
        exit 0
    fi
    echo "not_vlfs: no VLFS magic in either superblock"
    exit 1
fi
printf 'VLFSMAGIC' > "$1"
echo "fmt $1" >> "${VIRELAI_SESSION_SHARE:-/tmp}/mkfs-calls.txt"
echo "formatted $1"
"""


class SessionAppsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for d in ("tools/go", "tools/agentctl", "artifacts", "image", ".build/go",
                  "zig-out/bin", "host/vm-runner/.build/release",
                  "host/vm-runner/Resources", "fake-bin", "run-temp"):
            (self.root / d).mkdir(parents=True, exist_ok=True)
        shutil.copy(ROOT / "tools/session.sh", self.root / "tools/session.sh")
        shutil.copy(ROOT / "image/apps.txt", self.root / "image/apps.txt")
        shutil.copy(ROOT / "tools/agentctl/agentctl.py",
                    self.root / "tools/agentctl/agentctl.py")
        shutil.copy(ROOT / "host/vm-runner/Resources/Session-Info.plist",
                    self.root / "host/vm-runner/Resources/Session-Info.plist")
        (self.root / "host/vm-runner/entitlements.plist").write_text("fixture entitlements")
        # No host signing/service changes during unit tests.
        signer = self.root / "fake-bin/codesign"
        signer.write_text("#!/bin/sh\nprintf 'fixture codesign\\n'\n")
        signer.chmod(0o755)
        (self.root / "artifacts/disk.img").write_bytes(b"fake image")
        mkfs = self.root / ".build/go/mkfs.vlfs"
        mkfs.write_text(FAKE_MKFS)
        mkfs.chmod(0o755)
        self.write_runner("printf 'fake runner flags: %s\\n' \"$*\"\n")
        for name, builder in (APPS | PERSIST_TOOLS).items():
            (self.root / f"tools/go/build-{builder}.sh").write_text(
                "#!/bin/sh\n"
                f"printf '{name} built\\n' > .build/go/{name}.ELF\n")
        self.share = self.root / "isolated-share"
        self.profile = self.root / "artifacts/session.virelaivm"
        self.env = dict(os.environ, VIRELAI_SESSION_SHARE=str(self.share),
                        VIRELAI_SESSION_SKIP_BUILD="1",
                        TMPDIR=str(self.root / "run-temp"),
                        PATH=str(self.root / "fake-bin") + os.pathsep + os.environ["PATH"])
        self.env.pop("VIRELAI_SESSION_NO_GOTABWM", None)
        self.env.pop("VIRELAI_SESSION_NO_TABWM", None)

    def write_runner(self, body):
        runner = self.root / "host/vm-runner/.build/release/VMRunner"
        runner.write_text(RUNNER_HEAD + body)
        runner.chmod(0o755)

    def run_session(self, args=()):
        result = subprocess.run(
            ["bash", str(self.root / "tools/session.sh"), *args], env=self.env,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("command not found", result.stderr)
        return result.stdout

    def test_manifest_go_apps_and_available_zig_bundle_are_staged(self):
        (self.root / "zig-out/bin/TABWM.BIN").write_bytes(b"fallback")
        (self.root / "zig-out/bin/ZC.BIN").write_bytes(b"compiler")
        (self.root / "zig-out/bin/LD.SO").write_bytes(b"loader")
        output = self.run_session()
        for name in APPS:
            self.assertEqual((self.share / f"{name}.ELF").read_text(), f"{name} built\n")
            self.assertIn(f"session: staged {name}.ELF", output)
        self.assertEqual((self.share / "ZC.BIN").read_bytes(), b"compiler")
        self.assertEqual((self.share / "TABWM.BIN").read_bytes(), b"fallback")
        self.assertEqual((self.share / "APPS.TXT").read_bytes(),
                         (ROOT / "image/apps.txt").read_bytes())
        self.assertNotIn("tabwm start", (self.share / ".virelairc").read_text())

    def test_missing_failed_and_empty_builders_do_not_fake_success(self):
        (self.root / "tools/go/build-goterm.sh").unlink()
        (self.root / "tools/go/build-gocalc.sh").write_text("#!/bin/sh\nexit 1\n")
        (self.root / ".build/go/GOCALC.ELF").write_bytes(b"stale output")
        (self.root / "tools/go/build-note.sh").write_text("#!/bin/sh\nexit 0\n")
        output = self.run_session()
        for name in ("GOTERM", "GOCALC", "NOTE"):
            self.assertIn(f"{name}.ELF unavailable:", output)
            self.assertNotIn(f"session: staged {name}.ELF", output)
            self.assertFalse((self.share / f"{name}.ELF").exists())
        self.assertTrue((self.share / "GOFILES.ELF").exists())

    def test_no_documents_settings_or_startup_overwrite(self):
        self.share.mkdir()
        documents = {"SETTINGS.TXT": b"#v2\nwm=gotabwm\ntheme=light\n",
                     ".virelairc": b"# my startup\n", "NOTES.TXT": b"my notes\n",
                     "EDIT/DRAFT.TXT": b"my draft\n", "SESSION.TABS": b"my tabs\n"}
        for name, content in documents.items():
            target = self.share / name
            target.parent.mkdir(exist_ok=True)
            target.write_bytes(content)
            bundle = self.root / "zig-out/bin" / name
            bundle.parent.mkdir(exist_ok=True)
            bundle.write_bytes(b"must not overwrite")
        self.run_session()
        self.run_session()
        for name, content in documents.items():
            self.assertEqual((self.share / name).read_bytes(), content, name)

    def test_missing_seat_toolchain_uses_existing_fallback_contract(self):
        (self.root / "tools/go/build-gotabwm.sh").write_text(
            "#!/bin/sh\necho 'missing fork toolchain'\nexit 1\n")
        output = self.run_session()
        self.assertIn("GOTABWM.ELF unavailable: builder failed", output)
        self.assertIn("tabwm start", (self.share / ".virelairc").read_text())
        self.assertFalse((self.share / "GOTABWM.ELF").exists())

    def test_runner_does_not_inherit_parent_bundle_identity(self):
        self.env["__CFBundleIdentifier"] = "com.electron.factory"
        self.write_runner(
            "printf 'runner bundle=%s\\n' \"${__CFBundleIdentifier-unset}\"\n"
            "printf 'runner share=%s\\n' \"$VIRELAI_SESSION_SHARE\"\n")
        output = self.run_session()
        self.assertIn("runner bundle=unset", output)
        self.assertIn(f"runner share={self.share}", output)
        self.assertEqual(self.env["__CFBundleIdentifier"], "com.electron.factory")

    def test_distinct_bundle_and_host_mode_keep_cli_entrypoint(self):
        runner = self.root / "host/vm-runner/.build/release/VMRunner"
        self.write_runner(
            "printf 'bundle exec=%s\\n' \"$0\"\n"
            "printf 'flags=%s\\n' \"$*\"\n"
            "cp \"$(dirname \"$0\")/../Info.plist\" \"$VIRELAI_SESSION_SHARE/fixture.plist\"\n")
        original = runner.read_text()
        output = self.run_session()
        self.assertIn("VirelaiOS.app/Contents/MacOS/VirelaiOS", output)
        self.assertIn("--display --input --host-session", output)
        self.assertIn("--timeout 0", output)
        info = plistlib.loads((self.share / "fixture.plist").read_bytes())
        # The profile manifest's identity is stamped as CFBundleIdentifier.
        self.assertEqual(info["CFBundleIdentifier"], "org.virelaios.vm.fake")
        self.assertEqual(info["CFBundleName"], "VirelaiOS")
        self.assertEqual(info["CFBundleExecutable"], "VirelaiOS")
        self.assertEqual(runner.read_text(), original)
        self.assertEqual(list((self.root / "run-temp").iterdir()), [])

    def test_runner_failure_is_reported_and_run_directory_removed(self):
        self.write_runner("echo 'fixture startup error' >&2\nexit 7\n")
        result = subprocess.run(
            ["bash", str(self.root / "tools/session.sh")], env=self.env,
            capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 7)
        self.assertIn("fixture startup error", result.stderr)
        self.assertIn("VM runner exited with status 7", result.stderr)
        self.assertEqual(list((self.root / "run-temp").iterdir()), [])

    def test_terminal_stop_waits_for_owned_runner_before_cleanup(self):
        import signal
        import time
        self.write_runner(
            "#!/bin/bash\n"
            "trap 'test -f \"$0\" && echo stopped > \"$VIRELAI_SESSION_SHARE/stopped\"; exit 143' TERM\n"
            "echo $$ > \"$VIRELAI_SESSION_SHARE/owned-pid\"\n"
            "while :; do sleep 0.05; done\n")
        with tempfile.TemporaryFile(mode="w+") as log:
            process = subprocess.Popen(
                ["bash", str(self.root / "tools/session.sh")], env=self.env,
                stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not (self.share / "owned-pid").exists() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertTrue((self.share / "owned-pid").exists())
                pid = int((self.share / "owned-pid").read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=10), 143)
                self.assertEqual((self.share / "stopped").read_text(), "stopped\n")
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
                self.assertEqual(list((self.root / "run-temp").iterdir()), [])
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)

    # --- M120a (#2558): persistence wiring ----------------------------------

    def secret_rows(self):
        rows = {}
        for line in (self.share / "SECRETS.TXT").read_text().splitlines():
            fields = line.split("\t")
            if line and not line.startswith("#"):
                rows[fields[0]] = fields
        return rows

    def owner_rows(self):
        return {line.split("\t")[0] for line in
                (self.share / "OWNERS.TXT").read_text().splitlines()
                if line and not line.startswith("#")}

    def test_provision_only_mints_credentials_and_vlfs(self):
        output = self.run_session(["--provision-only"])
        self.assertIn("session: provisioning complete", output)
        rows = self.secret_rows()
        self.assertEqual(len(rows["vsock-ctl"]), 3)          # uid_system, unbound
        self.assertEqual(rows["vsock-ctl"][1], "0")
        self.assertEqual(rows["os-update"][1], "1000")
        self.assertEqual(rows["os-update"][3], "GOUPD.ELF")
        self.assertEqual(rows["agent-hmac"][1], "1000")
        self.assertEqual(rows["agent-hmac"][3], "AGENTD.ELF,GOTOP.ELF")
        self.assertEqual(rows["host-int"][1], "1000")
        self.assertEqual(rows["host-int"][3], "GOTABWM.ELF")
        self.assertIn("GOUPD.ELF", self.owner_rows())
        self.assertIn("GOTOP.ELF", self.owner_rows())
        self.assertIn("AGENTD.ELF", self.owner_rows())
        self.assertIn("GOTABWM.ELF", self.owner_rows())
        # The update pin is the os-update row's own public half.
        sys.path.insert(0, str(self.root / "tools/agentctl"))
        import agentctl
        pub = agentctl.ed_public_key(bytes.fromhex(rows["os-update"][2])).hex()
        cfg = json.loads((self.profile / "config.json").read_text())
        self.assertEqual(cfg["updatePubkey"], pub)
        # First mint formats vlfs.img; the persistence tools are staged.
        self.assertEqual((self.profile / "vlfs.img").read_bytes(), b"VLFSMAGIC")
        self.assertTrue((self.share / "GOUPD.ELF").exists())
        self.assertTrue((self.share / "AGENTD.ELF").exists())

    def test_existing_credential_rows_and_vlfs_are_kept(self):
        self.share.mkdir()
        (self.share / "SECRETS.TXT").write_text(
            "#v1\nvsock-ctl\t0\t" + "aa" * 32 + "\n")
        self.run_session(["--provision-only"])
        self.run_session(["--provision-only"])
        text = (self.share / "SECRETS.TXT").read_text()
        self.assertEqual(text.count("vsock-ctl\t"), 1)
        self.assertIn("vsock-ctl\t0\t" + "aa" * 32, text)
        # An unformatted image is minted once, then kept across boots.
        calls = (self.share / "mkfs-calls.txt").read_text().splitlines()
        self.assertEqual(len(calls), 1)
        self.assertTrue(calls[0].endswith("vlfs.img"))

    def test_corrupt_vlfs_is_warned_not_reformatted(self):
        self.run_session(["--provision-only"])   # mint the bundle + format
        (self.profile / "vlfs.img").write_bytes(b"user volume")
        mkfs = self.root / ".build/go/mkfs.vlfs"
        mkfs.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = \"--check\" ]; then echo 'inode 7: bad checksum'; exit 1; fi\n"
            "printf 'VLFSMAGIC' > \"$1\"\n")
        output = self.run_session(["--provision-only"])
        self.assertIn("fails its VLFS check and was NOT reformatted", output)
        self.assertEqual((self.profile / "vlfs.img").read_bytes(), b"user volume")

    def test_default_posture_rides_cvc_with_vsock_ctl(self):
        output = self.run_session()
        launch = [l for l in output.splitlines() if l.startswith("fake runner flags:")][0]
        self.assertIn("--cvc-file", launch)
        self.assertNotIn("--virtio-fs", launch)
        self.assertIn("--vsock --vsock-ctl", launch)
        self.assertIn("--host-clipboard", launch)
        self.assertIn("share posture: cvc-file", output)

    def test_save_capable_rides_virtiofs_and_disarms_cvc_lanes(self):
        output = self.run_session(["--save-capable"])
        launch = [l for l in output.splitlines() if l.startswith("fake runner flags:")][0]
        self.assertIn("--virtio-fs", launch)
        self.assertNotIn("--cvc-file", launch)
        self.assertIn("--vsock --vsock-ctl", launch)
        self.assertNotIn("--host-clipboard", launch)
        self.assertIn("cvc-only host lanes", output)
        self.assertIn("share posture: virtio-fs", output)

    def test_resume_passes_resume_and_skips_first_boot_script(self):
        self.run_session(["--provision-only"])   # mint the bundle
        (self.profile / "saved-state/state.vzsave").write_bytes(b"state")
        output = self.run_session(["--resume"])
        launch = [l for l in output.splitlines() if l.startswith("fake runner flags:")][0]
        self.assertIn(f"--resume {self.profile}", launch)
        self.assertIn("--virtio-fs", launch)
        self.assertNotIn("--script", launch)

    def test_resume_without_saved_state_refuses(self):
        result = subprocess.run(
            ["bash", str(self.root / "tools/session.sh"), "--resume"],
            env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 1)
        self.assertIn("--resume needs a suspended machine", result.stderr)


if __name__ == "__main__":
    unittest.main()
