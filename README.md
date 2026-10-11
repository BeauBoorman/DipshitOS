# VirelaiOS

[![CI](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml/badge.svg)](https://github.com/drawmeanelephant/DipshitOS/actions/workflows/ci.yml)

A from-scratch AArch64 operating system. It boots under real UEFI firmware on
**Apple silicon**, hosted by Apple's **Virtualization.framework**
(**macOS 27 or newer**). It is **not Linux, not Unix, and not QEMU** — no
libc, no POSIX, no existing guest OS, no emulator in the boot path. The guest
is freestanding [Zig](https://ziglang.org/); the host launcher is Swift.

The name is a joke. The engineering is not: every subsystem is either verified
deterministically or **live-gated** on real hardware.

📚 **Documentation site: <https://drawmeanelephant.github.io/DipshitOS/>**
(compiled by [Boris](https://github.com/drawmeanelephant/boris) and published
to GitHub Pages).

## Status

Every milestone through **M86** has landed, and every milestone index but one
has closed (observed 2026-09-29). The **boot default is the Go seat**:
`GOTABWM.ELF` autostarts and hosts Go EL0
clients over the `WM_RPC` tab contract, with Zig `TABWM.BIN` retained by
decision (ADR 0034) as the `settings set wm tabwm` fallback. The one open arc is
**M84, remote framebuffer** ([#1807](https://github.com/drawmeanelephant/DipshitOS/issues/1807)) —
an RFB server a Mac can Screen Share into. The guest wire and its live gate
landed; the macOS Screen Sharing tape is blocked on
[#1835](https://github.com/drawmeanelephant/DipshitOS/issues/1835), because
Screen Sharing refuses the `None` security type. The arcs around it — terminal
graphics (`IMGCAT.ELF` over sixel) and window chrome with the published
`appkit` canvas — are closed. [`docs/status.md`](docs/status.md) is the canonical
accounting and the readable summary is the
[documentation site](https://drawmeanelephant.github.io/DipshitOS/).

The first thirty-one milestones — the boot
pipeline, the interactive `virelai>` monitor, userspace (allocator,
scheduler, EL0 + syscalls), processes (IPC, wait, kill), networking
(virtio-net → ARP → IPv4/ICMP → UDP → DHCP → TCP), graphics (framebuffer →
Road Pops terminal → Driving Award window manager), input (USB XHCI + HID),
usability, app events, the userland filesystem, the desktop platform —
`CALC.BIN`, `NOTEPAD.BIN`, `TOP.BIN` are all retired Zig (M62h/M66c/M71g),
now the Go `GOCALC.ELF` / `NOTE.ELF` / `GOTOP.ELF` — alongside `GOFILES.ELF`
and the `GOTABWM.ELF` seat, network
apps, shared services (clipboard + app timers), audio, kernel consolidation,
desktop completeness and the post-M17 arcs, and the M18–M27 experience layer
(terminal & shell depth, shell programming, text rendering & Unicode, window
management depth, developer tools, the text editor, CALC, file manager depth,
network experience, desktop polish).

The 2026-08-27 hardware-depth trio rounded it out:

- **M28 — SMP:** a second CPU core online via PSCI, per-core schedulers,
  spinlocks, and GICv3 IPIs — `smp: cores=2 online=2` live-gated on real VZ.
- **M29 — VM depth:** demand paging, copy-on-write, and anonymous
  `sys_mmap`/`sys_munmap` (ADR 0007 slots 63/64).
- **M30 — dynamic linking:** a freestanding runtime linker (`LD.SO`) plus
  `LIBUI.SO`/`LIBFONT.SO` shared libraries, zero libc, W^X multi-aperture
  isolation, live-gated.
- **M31 — dynamic linking ecosystem:** the desktop apps migrated to dynamic
  executables (`CALC.ELF`, `NOTEPAD.ELF`, `FILE.ELF`, `DESKTOP.ELF`) with
  runtime `dlopen`/`dlsym` plugin loading.

Also landed: an in-guest HTTP/1.1 web server (claim 0750 — Zig `HTTPD.BIN` was
retired to `GOHTTPD.ELF` in M71l), offline preflight for the M26 network apps
(N13/N14), and a
wall-clock bounding fix for `sys_tcp_connect` (#613).

**Right now:** the boot default is the Go seat, and the Go toolchain runs
in-guest — a single boot autostarts `GOTABWM.ELF` and hosts Go clients as tabs
(the shell `GOSH.ELF`, the editor `NOTE.ELF`), and the guest's own
`cmd/compile` + `cmd/link` build and run the pinned hello program
(`live-selfhost-go`). Everything since M31 is one row per milestone in
[`docs/status.md`](docs/status.md); this README does not duplicate that table.

## Quick start

To open a usable windowed desktop from a clean clone, run this from the
repository root on Apple silicon with macOS 27 or newer:

```bash
git clone https://github.com/drawmeanelephant/DipshitOS.git
cd DipshitOS
source tools/env-check.sh
just session
```

`just session` is the supported local host launch. It builds the guest, disk
image and runner, seeds the persistent share at `artifacts/session-share`,
and launches a per-run, ad-hoc-signed `VirelaiOS.app` with bundle identity
`org.virelaios.host`. No installation or permission change is performed.
The app requests activation and makes its VM view the first responder when
the window becomes key. Click its **VirelaiOS** window if macOS keeps another
app active. Native AppKit dispatch handles keyboard and mouse events.

The title/status shows **Starting VM**, then **VirelaiOS** once VZ starts.
A runner preflight/startup/runtime error stays visible until dismissed;
build/staging errors appear in the launching terminal.
Close the window, choose **Quit VirelaiOS** (Cmd-Q), or press Ctrl-C in the
launching terminal to stop the owned VM and drain its serial output. The
command waits for the runner before removing its temporary app/EFI vars;
the runner discards its writable disk overlay. Rerun the same command to
relaunch: VM RAM does not survive, but share documents/settings do.
The generated app is not a standalone Finder launch/install artifact.
The unbundled `VMRunner` CLI remains the gate entrypoint.

Guest serial output is saved to
`artifacts/session-serial.log`. This is an interactive class-C session, so it
does not run in CI.

The environment check verifies the modern Homebrew host tools. If it fails
because macOS system tools appear first in `PATH`, run
`brew install bash gnu-sed jq yq`, fix `PATH` as the check instructs, and
source `tools/env-check.sh` again. The session also requires `just`, Zig,
Swift/Xcode command-line tools, and Python 3.

Session options (set before `just session`):

```bash
VIRELAI_SESSION_SHARE=/path/to/share just session
VIRELAI_SESSION_NO_TABWM=1 just session
VIRELAI_SESSION_NO_GOTABWM=1 just session
VIRELAI_SESSION_SKIP_BUILD=1 bash tools/session.sh
```

`VIRELAI_SESSION_SHARE` relocates the persistent share. On a share without an
existing `.virelairc`, `VIRELAI_SESSION_NO_TABWM=1` starts the classic floating
window manager; `VIRELAI_SESSION_NO_GOTABWM=1` skips the Go seat and writes a
startup file for the Zig TABWM fallback. Existing `.virelairc` files are kept
as-is. `VIRELAI_SESSION_SKIP_BUILD=1` skips the script's own build steps when
calling `tools/session.sh` directly; the runner, `artifacts/disk.img`, and
staged files must already exist. `just session` retains its normal Zig image
dependency.

### Remote-only terminal through host SSH

On the Apple-silicon VM host, start a foreground service with a **dedicated**
absolute share (not your desktop share):

```bash
bash tools/remote-terminal.sh serve --share /absolute/remote-share
```

In another host terminal, or from a different machine through OpenSSH:

```bash
bash tools/remote-terminal.sh attach --share /absolute/remote-share
ssh -tt operator@vm-host 'cd /absolute/VirelaiOS && bash tools/remote-terminal.sh attach --share /absolute/remote-share'
```

The operator must already have authorized SSH key access and Remote Login
enabled on the host. Use the same host account for serve and attach.
Verify the host-key fingerprint through a trusted
channel before accepting it; never disable host-key checking. These tools do
not enable SSH, install servers, use sudo, or change firewall/router settings.
SSH supplies remote encryption. The loopback HMAC bridge authenticates but
does **not** encrypt; host-account authorization grants guest-console authority.

`serve` builds/checks the image, SPIKE runner and source-fresh GOSH. It seeds
`#v2`, `wm=none`, `shell=sh`, GOSH and serial support files, without a GUI
seat or a boot-default change. Documents and `GOSH-HISTORY.TXT` persist.
Executable/support files refresh on service restart. Incompatible settings,
an active `.virelairc`, or a nonempty unconfigured share are refused, never
rewritten. `--port 24681` is the default, validated and always loopback-only.
Private session state and the file-only random secret live outside the share
under `~/.virelai/remote-terminal/`; reattachments reuse the live secret.
The build needs the provisioned `GOOS=virelai` fork (`bash tools/go/apply.sh`
then `just go-toolchain`); set `GO_FORK_DIR` when it is outside the checkout's
parent directory.

Ctrl-C in **attach** cancels the guest line; Ctrl-] disconnects only the
client. Reattach reaches the same live VM, and a disconnected partial line
is cancelled. Ctrl-C in **serve** stops the VM and cleans only its temporary
state/vars/overlay, not the share. Ctrl-D on an empty GOSH line, `exit`, or
`monitor` hands serial back to the kernel monitor; that is not a GOSH
acceptance. From the still-connected monitor, `exec GOSH.ELF serial` returns
to GOSH, or restart the service. A second client gets a busy refusal.

This is a host terminal rendering serial bytes, not guest SSH, Screen,
PTY-size negotiation, graphics, resize, or expanded TUI compatibility.
The required **real two-machine** fixture and its precise blockers are in
[`docs/testing.md`](docs/testing.md#remote-terminal-m87).

For serial-only development or deterministic builds, use the lower-level
commands:

```bash
zig build            # compile the AArch64 UEFI application
zig build image      # build the GPT+FAT32 disk image
zig build run        # serial takeover path
```

`zig build run` writes kernel serial output to `artifacts/vm-serial.log`.
`zig build console` opens an interactive `virelai>` console, and
`zig build test-console` runs the deterministic transcript test.

**Requirements:** Apple silicon, macOS 27+, Zig 0.17.0, `just`, Swift + Xcode
command-line tools, Python 3, bash, and the Homebrew `bash`, `gnu-sed`, `jq`,
and `yq` tools. No root, no `mtools`, no Linux/QEMU path.

## Verification

The project separates two classes of evidence:

- **Class A** — deterministic (formatting, unit tests, a byte-identical console
  transcript, the build pipeline). Runs in CI on every push.
- **Class B** — **live-gated**: boots a real Virtualization.framework VM on
  Apple silicon and asserts on what the kernel reports. CI cannot run these.

```bash
just verify-portable   # class A, mirrors CI
just verify-vz         # class B, Apple silicon, boots real VMs
```

## Layout

- `boot/` — the AArch64 UEFI boot loader.
- `kernel/` — the freestanding kernel and every subsystem.
- `user/` — EL0 programs: flat `.BIN` images, dynamic `.ELF` executables,
  and the `LD.SO`/`LIBUI.SO`/`LIBFONT.SO` shared libraries.
- `host/vm-runner/` — the Swift Virtualization.framework launcher.
- `site/` — the public documentation corpus (compiled by Boris).
- `docs/` — the engineering warehouse: claims, decisions (ADRs), status,
  hardware contract, gate inventory, and the [memorial to `calm-lavoisier`](docs/calm-lavoisier-memorial.md).
- [`docs/app-authoring.md`](docs/app-authoring.md) — the short path from an
  empty Go app to a staged, gated EL0 client.

See `AGENTS.md` for the project rules, and the
[development guide](https://drawmeanelephant.github.io/DipshitOS/development.html)
for how the pieces fit.

## License

VirelaiOS is **source-available, not open source** — the code is publicly
visible so it can be reviewed and learned from, but you may not use, modify,
redistribute, or incorporate it without written permission. Forks are not
freedom. The binding terms are [`LICENSE`](LICENSE); a plain-language summary
is on the [documentation site](https://drawmeanelephant.github.io/DipshitOS/license.html).
