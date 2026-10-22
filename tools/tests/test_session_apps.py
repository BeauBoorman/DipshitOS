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
        shutil.copy(ROOT / "tools/go/ensure-guest-elf.sh",
                    self.root / "tools/go/ensure-guest-elf.sh")
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
        # The M122a doctor requires zig+swift on PATH when the build step
        # runs; the fakes log every invocation so a test can prove a step
        # ran (or, in --dry-run, provably did not).
        for tool in ("zig", "swift"):
            fake = self.root / f"fake-bin/{tool}"
            fake.write_text(f"#!/bin/sh\necho {tool} >> .build/go/tool-log\n")
            fake.chmod(0o755)
        # M128c (#2607): session.sh registers the assembled app with
        # LaunchServices via `command -v lsregister` — shadow it so the
        # real LS database is never touched and the call is assertable.
        lsreg = self.root / "fake-bin/lsregister"
        lsreg.write_text(
            "#!/bin/sh\n"
            "printf '%s\\n' \"$*\" >> \"${VIRELAI_SESSION_SHARE:-/tmp}/lsregister-calls.txt\"\n")
        lsreg.chmod(0o755)
        # A minimal patched-looking GOOS=virelai fork: bin/go answers
        # `go version` (ensure-guest-elf's toolchain id probe) and
        # syslist.go carries the '"virelai"' marker apply.sh checks for.
        fork = self.root / "fake-go-virelai"
        (fork / "bin").mkdir(parents=True)
        go = fork / "bin/go"
        go.write_text(
            "#!/bin/sh\n"
            "if [ \"$1\" = version ]; then\n"
            "    echo 'go version go1.27.1-fake virelai/arm64'\n"
            "fi\n")
        go.chmod(0o755)
        (fork / "src/internal/syslist").mkdir(parents=True)
        (fork / "src/internal/syslist/syslist.go").write_text(
            'var KnownOS = map[string]bool{\n\t"virelai":   true,\n}\n')
        (self.root / "artifacts/disk.img").write_bytes(b"fake image")
        mkfs = self.root / ".build/go/mkfs.vlfs"
        mkfs.write_text(FAKE_MKFS)
        mkfs.chmod(0o755)
        self.write_runner("printf 'fake runner flags: %s\\n' \"$*\"\n")
        for name, builder in (APPS | PERSIST_TOOLS).items():
            (self.root / f"tools/go/build-{builder}.sh").write_text(
                "#!/bin/sh\n"
                f"printf '{name} built\\n' > .build/go/{name}.ELF\n"
                f"echo {name} >> .build/go/build-log\n")
        self.share = self.root / "isolated-share"
        self.profile = self.root / "artifacts/session.virelaivm"
        self.env = dict(os.environ, VIRELAI_SESSION_SHARE=str(self.share),
                        GO_FORK_DIR=str(fork),
                        TMPDIR=str(self.root / "run-temp"),
                        PATH=str(self.root / "fake-bin") + os.pathsep + os.environ["PATH"])
        self.env.pop("VIRELAI_SESSION_SKIP_BUILD", None)
        self.env.pop("VIRELAI_SESSION_NO_GOTABWM", None)
        self.env.pop("VIRELAI_SESSION_NO_TABWM", None)

    def builder_invocations(self):
        """Fake-builder call log: one app name per line, appended per run."""
        log = self.root / ".build/go/build-log"
        return log.read_text().split() if log.exists() else []

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
        # M128c (#2607): the assembled app carries the document handler —
        # the exported UTI and the document type ride the plist verbatim
        # through the identity stamp.
        self.assertEqual(
            info["CFBundleDocumentTypes"][0]["LSItemContentTypes"],
            ["org.virelaios.virelaivm"])
        self.assertEqual(
            info["UTExportedTypeDeclarations"][0]["UTTypeIdentifier"],
            "org.virelaios.virelaivm")
        self.assertEqual(runner.read_text(), original)
        self.assertEqual(list((self.root / "run-temp").iterdir()), [])

    # --- M128c (#2607): the .virelaivm Finder document ------------------

    def test_virelaivm_document_type_and_ls_registration(self):
        # The source plist exports the UTI as a PACKAGE with the
        # filename-extension tag, and declares this app its editor.
        info = plistlib.loads(
            (ROOT / "host/vm-runner/Resources/Session-Info.plist").read_bytes())
        decls = info["UTExportedTypeDeclarations"]
        self.assertEqual(len(decls), 1)
        decl = decls[0]
        self.assertEqual(decl["UTTypeIdentifier"], "org.virelaios.virelaivm")
        self.assertIn("com.apple.package", decl["UTTypeConformsTo"])
        self.assertEqual(
            decl["UTTypeTagSpecification"]["public.filename-extension"],
            ["virelaivm"])
        docs = info["CFBundleDocumentTypes"]
        self.assertEqual(len(docs), 1)
        doc = docs[0]
        self.assertEqual(doc["LSItemContentTypes"], ["org.virelaios.virelaivm"])
        self.assertTrue(doc["LSTypeIsPackage"])
        self.assertEqual(doc["LSHandlerRank"], "Owner")

        # The assembled app is registered with LaunchServices so a
        # Finder double-click resolves the handler.
        output = self.run_session()
        app = self.profile / "VirelaiOS.app"
        self.assertIn("session: registered the .virelaivm document handler", output)
        calls = (self.share / "lsregister-calls.txt").read_text().splitlines()
        self.assertEqual(calls, [f"-f {app}"])

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
                deadline = time.monotonic() + 30
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
                rows.setdefault(fields[0], []).append(fields)
        return rows

    def owner_rows(self):
        return {line.split("\t")[0] for line in
                (self.share / "OWNERS.TXT").read_text().splitlines()
                if line and not line.startswith("#")}

    def test_provision_only_mints_credentials_and_vlfs(self):
        output = self.run_session(["--provision-only"])
        self.assertIn("session: provisioning complete", output)
        rows = self.secret_rows()
        self.assertEqual(len(rows["vsock-ctl"][0]), 3)       # uid_system, unbound
        self.assertEqual(rows["vsock-ctl"][0][1], "0")
        self.assertEqual(rows["os-update"][0][1], "1000")
        self.assertEqual(rows["os-update"][0][3], "GOUPD.ELF")
        # M173d (#3161): agent-hmac is ONE credential across two
        # principals — the daemon's uid_agent row plus GOTOP's uid_user
        # row, both carrying the same key.
        agent = {r[1]: r for r in rows["agent-hmac"]}
        self.assertEqual(sorted(agent), ["1000", "2000"])
        self.assertEqual(agent["2000"][3], "AGENTD.ELF")
        self.assertEqual(agent["1000"][3], "GOTOP.ELF")
        self.assertEqual(agent["2000"][2], agent["1000"][2])
        self.assertEqual(rows["host-int"][0][1], "1000")
        self.assertEqual(rows["host-int"][0][3], "GOTABWM.ELF")
        self.assertIn("GOUPD.ELF", self.owner_rows())
        self.assertIn("GOTOP.ELF", self.owner_rows())
        self.assertIn("AGENTD.ELF", self.owner_rows())
        self.assertIn("GOTABWM.ELF", self.owner_rows())
        # The update pin is the os-update row's own public half.
        sys.path.insert(0, str(self.root / "tools/agentctl"))
        import agentctl
        pub = agentctl.ed_public_key(bytes.fromhex(rows["os-update"][0][2])).hex()
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

    def test_pre_m173d_agent_hmac_row_gains_the_uid_agent_row(self):
        # A share provisioned before the M173d split keeps its uid_user
        # row verbatim; provisioning re-scopes the SAME credential to the
        # daemon's principal instead of minting a second key or only
        # warning.
        self.share.mkdir()
        key = "bb" * 32
        legacy = "agent-hmac\t1000\t" + key + "\tAGENTD.ELF,GOTOP.ELF"
        (self.share / "SECRETS.TXT").write_text("#v1\n" + legacy + "\n")
        output = self.run_session(["--provision-only"])
        agent = {r[1]: r for r in self.secret_rows()["agent-hmac"]}
        self.assertEqual(sorted(agent), ["1000", "2000"])
        self.assertEqual(agent["1000"], legacy.split("\t"))
        self.assertEqual(agent["2000"], ["agent-hmac", "2000", key, "AGENTD.ELF"])
        # Idempotent: a second run adds nothing and warns about nothing.
        self.run_session(["--provision-only"])
        self.assertEqual(len(self.secret_rows()["agent-hmac"]), 2)
        self.assertNotIn("agent-hmac row", output)

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
        self.assertIn("--host-outbox", launch)
        self.assertIn("share posture: cvc-file", output)

    def test_save_capable_rides_virtiofs_and_disarms_cvc_lanes(self):
        output = self.run_session(["--save-capable"])
        launch = [l for l in output.splitlines() if l.startswith("fake runner flags:")][0]
        self.assertIn("--virtio-fs", launch)
        self.assertNotIn("--cvc-file", launch)
        self.assertIn("--vsock --vsock-ctl", launch)
        self.assertNotIn("--host-clipboard", launch)
        self.assertNotIn("--host-outbox", launch)
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

    # --- M122a (#2570): incremental builds + toolchain doctor -------------

    def plan_row(self, output, app):
        for line in output.splitlines():
            if line.startswith("session:") and app in line:
                return line
        return ""

    def test_warm_run_never_rebuilds_or_restages_fresh_elfs(self):
        first = self.run_session()
        self.assertIn("session: staged GOSH.ELF", first)
        cold = self.builder_invocations()
        self.assertIn("GOSH", cold)
        second = self.run_session()
        # Every built app reports up-to-date; no builder ran; the share was
        # not rewritten.
        for name in APPS:
            self.assertIn(f"session: {name}.ELF up-to-date", second)
            self.assertNotIn(f"session: staged {name}.ELF", second)
        self.assertEqual(self.builder_invocations(), cold)
        self.assertIn("go-fork not needed", second)
        for name in APPS:
            self.assertEqual((self.share / f"{name}.ELF").read_text(),
                             f"{name} built\n")

    def test_dry_run_reports_plan_and_mutates_nothing(self):
        # Cold tree: every buildable app reports a pending rebuild.
        out = self.run_session(["--dry-run"])
        self.assertIn("--dry-run", out)
        self.assertIn("would rebuild via tools/go/build-gosh.sh",
                      self.plan_row(out, "GOSH.ELF"))
        self.assertIn("no builder", self.plan_row(out, "GODIFF.ELF"))
        self.assertNotIn("fake runner flags:", out)
        self.assertFalse((self.root / ".build/go/build-log").exists())
        self.assertFalse((self.root / ".build/go/tool-log").exists())
        self.assertFalse(self.share.exists())
        self.assertFalse(self.profile.exists())
        # Warm tree: a dry run skips the up-to-date ELFs by name and does
        # not add a single builder or zig/swift invocation.
        self.run_session()
        builds = self.builder_invocations()
        tool_log = self.root / ".build/go/tool-log"
        tools = tool_log.read_text().split() if tool_log.exists() else []
        out = self.run_session(["--dry-run"])
        self.assertIn("fresh", self.plan_row(out, "GOSH.ELF"))
        self.assertNotIn("would rebuild", self.plan_row(out, "GOSH.ELF"))
        self.assertIn("no builder", self.plan_row(out, "GODIFF.ELF"))
        self.assertEqual(self.builder_invocations(), builds)
        self.assertEqual(tool_log.read_text().split(), tools)
        self.assertNotIn("fake runner flags:", out)

    def test_missing_go_toolchain_fails_before_boot_with_fix_command(self):
        self.env.pop("GO_FORK_DIR", None)
        result = subprocess.run(
            ["bash", str(self.root / "tools/session.sh")], env=self.env,
            capture_output=True, text=True, timeout=30)
        self.assertNotEqual(result.returncode, 0)
        combined = result.stdout + result.stderr
        self.assertIn("go-fork MISSING", combined)
        self.assertIn("bash tools/go/apply.sh && just go-toolchain", combined)
        # The doctor refuses before any build step, staging, or boot.
        self.assertNotIn("building guest + image", combined)
        self.assertNotIn("fake runner flags:", combined)
        self.assertFalse((self.root / ".build/go/build-log").exists())
        self.assertFalse((self.root / ".build/go/tool-log").exists())

    def test_skip_build_covers_the_go_builders_too(self):
        self.env["VIRELAI_SESSION_SKIP_BUILD"] = "1"
        out = self.run_session()
        self.assertFalse((self.root / ".build/go/build-log").exists())
        self.assertIn("no prior build (VIRELAI_SESSION_SKIP_BUILD=1)", out)
        self.assertFalse((self.share / "GOSH.ELF").exists())
        self.assertIn("tabwm start", (self.share / ".virelairc").read_text())

    def test_skip_build_reuses_the_prior_go_output(self):
        self.run_session()
        self.env["VIRELAI_SESSION_SKIP_BUILD"] = "1"
        builds = self.builder_invocations()
        out = self.run_session()
        self.assertEqual(self.builder_invocations(), builds)
        self.assertEqual((self.share / "GOSH.ELF").read_text(), "GOSH built\n")
        self.assertIn("session: GOSH.ELF up-to-date", out)


if __name__ == "__main__":
    unittest.main()
