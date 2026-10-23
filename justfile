# VirelaiOS command aliases.
# Requires: just (https://github.com/casey/just)
# All recipes simply delegate to the Zig build system.
#
# Verification classes (definitions: docs/gate-inventory.md; the generated
# fleet inventory: docs/gate-fleet-inventory.md — M40 GF5):
#   A — portable / build CI. Deterministic, no Apple silicon, no VZ VM.
#       This is exactly what GitHub CI proves. `just verify-portable` runs
#       the same set locally (`just verify` is a legacy alias).
#   B — Apple-silicon Virtualization.framework hardware gate. Boots a real
#       VZ VM on Apple silicon. CI does NOT run these and cannot prove them;
#       run `just verify-vz` on a development host.
#   C — interactive / manual hardware gate. Needs a human at the keyboard.
#   D — diagnostic experiment. NOT an acceptance gate.

# Legacy alias for the full portable/build gate set (class A)
alias verify := verify-portable

# Run the full portable/build gate set (class A; mirrors CI). Does NOT run
# the Apple-silicon VZ hardware gates (class B) — that is `just verify-vz`.
verify-portable:
    python3 tools/test-timing.py init
    zig fmt --check boot/src/*.zig kernel/src/*.zig user/src/*.zig build.zig
    python3 tools/test-timing.py run timing-reporter -- python3 -m unittest discover -s tools/tests -p test_test_timing.py
    python3 tools/test-timing.py run registry -- python3 -m unittest discover -s tools/tests -p test_component_registry.py
    python3 tools/test-timing.py run zig-unit -- bash tools/verify-unit-tests.sh
    python3 tools/test-timing.py run console-transcript -- zig build test-console
    zig build
    zig build image
    zig build inspect
    swift build --package-path host/vm-runner
    python3 tools/test-timing.py run swift-host -- swift test --package-path host/vm-runner
    python3 tools/test-timing.py run go-user -- go -C user/go test -count=1 ./...
    python3 tools/test-timing.py run go-vlfs -- go -C tools/go/vlfs test -count=1 ./...
    zig build context
    bash tools/status/verify-issue-coordination.sh
    python3 tools/test-timing.py run coordination -- bash tools/status/test-coordination.sh
    bash tools/inventory-gates.sh --check
    bash tools/lint-workflows.sh
    bash tools/verify-mmu-debt.sh
    bash tools/verify-glyph-raster.sh
    bash tools/verify-ttf-fonts.sh
    bash tools/verify-mutations.sh
    bash tools/verify-bss-budget.sh
    bash tools/verify-vf-class-a.sh
    python3 tools/test-timing.py run gate-runner -- bash tools/gate/test-gate-run.sh
    python3 tools/test-timing.py run benchmark-checker -- python3 tools/gate/bench-check.py
    python3 tools/test-timing.py run guest-elf -- bash tools/go/test-ensure-guest-elf.sh
    python3 tools/test-timing.py finish

# The class-B fleet is DISCOVERED, not listed (M40 GF5): every spec in
# tools/gate/specs/ plus the four legacy class-B scripts (bad-handoff,
# marker, nvram-console, host-console) run via tools/gate/fleet.sh.
# Adding a spec file adds it to verify-vz / gate / gates / the CI shards
# with zero list edits. The serial-takeover gate (`zig build run`) is an
# interactive console takeover (needs a TTY) and is deliberately not part
# of the automated fleet — run `just run`. Apple silicon only.
verify-vz:
    bash tools/gate/fleet.sh verify-vz

# Run one fleet member by exact id or unique prefix (spec or legacy script):
#   just gate live-args            just gate bad-handoff
gate ID:
    bash tools/gate/fleet.sh run "{{ID}}"

# Run every fleet member whose id contains the pattern (substring match):
#   just gates net-arp             just gates wnd6
gates PATTERN:
    bash tools/gate/fleet.sh run "{{PATTERN}}"

# List the class-B fleet (kind<TAB>id — the same list the CI shards consume)
gate-list:
    bash tools/gate/fleet.sh list

# Provision the GOOS=virelai Go toolchain + gate fixtures (issue #1163;
# idempotent — apply.sh and the host make.bash pass run only when
# missing). HOST PREREQUISITE for the go-hello / go-args / go-goroutines /
# go-stress / go-panic / go-win / go-net (govinet/govidns) /
# live-smp-scale class-B gates:
# `just verify-vz` includes them, and they refuse
# to run (honestly) until this has produced .build/go/{GOHELLO,GOARGS,
# GOROUT,GOSTRESS,GOPANIC,GOWIN,GOVINET,GOVIDNS,GOSCALE}.ELF on this
# machine — plus GOBIG.ELF (M70c-K #1504: the 9.5 MiB image go-hello run 02
# streams, which the old 2 MiB staging bound refused), GOREAD.ELF (M70c
# #1455: the share-read measurement, go-hello run 04), GOSYSCALL.ELF
# (M70c-S1L #1540: the os/fmt fixture, go-hello run 05), GOBIGREAD.ELF
# (#2354: the region-straddle large-read fixture, go-hello run 13) and
# GOSELFHOST.ELF
# (M70c-S2 #1544: the in-guest build-loop driver, live-selfhost-go). First run takes
# several minutes (one Go make.bash pass; the second cross-std pass is
# phase-2 opt-in via GOVIRELAI_STD=1).
go-toolchain:
    bash tools/go/build-go.sh tools/go/hello.go tools/go/goargs.go tools/go/goroutines.go tools/go/gostress.go tools/go/gopanic.go tools/go/gowin.go tools/go/gonet.go tools/go/govinet.go tools/go/govidns.go tools/go/smpscale.go tools/go/gobig.go tools/go/goloadbss.go tools/go/goread.go tools/go/gosyscall.go tools/go/gobigread.go tools/go/selfhost.go

# Build the phase-2 netpoll + os.File/net.Conn fixture (issue #1163):
# .build/go/GONET.ELF. HOST PREREQUISITE for the go-net class-B gate.
go-gonet:
    bash tools/go/build-go.sh tools/go/gonet.go

# Build the M67a vi-socket fixtures (#1446): .build/go/GOVINET.ELF
# (loopback + closed-port) and .build/go/GOVIDNS.ELF (DNS round trip).
# HOST PREREQUISITE for the go-net class-B gate's M67a runs.
go-govinet:
    bash tools/go/build-go.sh tools/go/govinet.go tools/go/govidns.go

# Build the M68a Go shell (#1449): .build/go/GOSH.ELF. HOST PREREQUISITE
# for the go-sh class-B gate.
go-gosh:
    bash tools/go/build-gosh.sh

# Build the M70g G1 in-guest SSH-2 server (#1491): .build/go/GOSSHD.ELF.
# HOST PREREQUISITE for the live-ssh-server class-B gate.
go-sshd:
    bash tools/go/build-sshd.sh

# Build the M71j in-guest SSH-2 client (#1569): .build/go/GOSSH.ELF.
# HOST PREREQUISITE for the live-ssh-endpoint/negative/nocred class-B gates.
go-ssh:
    bash tools/go/build-ssh.sh

# Build the independent host RFB probe for the M84c hermetic live gate.
go-rfbprobe:
    bash tools/go/rfbprobe/build.sh

# Compile the AArch64 UEFI application and kernel image (class A — zig build)
build:
    zig build

# Run the M1.5 kernel monitor module unit tests (class A — zig test per module; skips modules not yet landed)
test:
    bash tools/verify-unit-tests.sh

# Run the automated virelai> transcript test — mock console, no VM (class A; M1.5 march step 19)
test-console:
    zig build test-console

# Boot the VM and save the host-side NVRAM marker ladder (class B mechanism — ADR 0004 D4 fallback, `zig build marker`; Apple silicon only)
marker:
    zig build marker

# Verify the ADR 0004 D4 fixed-memory-marker fallback gate (class B — boots a VZ VM; Apple silicon only)
verify-marker:
    bash tools/verify-marker.sh

# Boot the -Dnvram-console=true image and reconstruct the post-exit NVRAM console stream (class B mechanism — zig build nvram-console; claim 0015; Apple silicon only)
nvram-console:
    zig build nvram-console

# Verify the claim-0015 NVRAM console gate (class B — post-exit console bytes via the NVRAM channel; boots a VZ VM; Apple silicon only)
verify-nvram-console:
    bash tools/verify-nvram-console.sh

# Verify the claim-0017 pre-exit virtio-pci TX diagnostic (class D — can the transport TX while Boot Services + firmware address space are still active? boots a VZ VM; Apple silicon only)
verify-preexit-tx:
    bash tools/verify-preexit-tx.sh

# Boot the -Dpreexit-tx=true image and report whether the pre-exit virtio TX reached vm-serial.log (class D mechanism — zig build preexit-tx; claim 0017; Apple silicon only)
preexit-tx:
    zig build preexit-tx

# Verify the claim-0018 post-exit virtio TX bisect gate (class D — N identical VZ boots, per-stage markers, determinism report; Apple silicon only)
verify-tx-diag:
    bash tools/verify-tx-diag.sh

# Boot the -Dtx-diag=true image once and save the per-stage post-exit TX marker ladder (class D mechanism — zig build tx-diag; claim 0018; Apple silicon only)
tx-diag:
    zig build tx-diag

# Extract the flat kernel image zig-out/bin/KERNEL.BIN (class A tooling — zig build kernel; no VM)
kernel:
    zig build kernel

# Create the FAT32+GPT boot disk image (class A — zig build image)
image:
    zig build image

# Boot with the Swift Virtualization.framework runner (class B gate — the live serial takeover gate, claim 0002; PASSING since claim 1517; Apple silicon only)
run:
    zig build run

# Boot an interactive host serial console (class C — interactive/manual hardware gate; requires a human at the keyboard; Apple silicon only)
console:
    zig build console

# Boot an interactive WINDOWED desktop session from a clean checkout (class C — Apple silicon + macOS 27+).
# Builds the guest, image, and SPIKE runner; seeds the persistent share; opens the Go seat's first-boot shell workspace.
# Ctrl-C ends the session; serial log at artifacts/session-serial.log. See README for the VIRELAI_SESSION_* options.
# Pass-through flags (M120a #2558): `just session --save-capable` rides virtio-fs so suspend/snapshot
# are armed; `just session --resume` continues a suspended machine.
session *ARGS:
    bash tools/session.sh {{ARGS}}

# Inspect the EFI binary and disk image (class A — zig build inspect)
inspect:
    zig build inspect

# Regenerate artifacts/context.md (class A — zig build context)
context:
    zig build context

# Sanity-check the host toolchain at session start (class A — sourceable, no VM):
# verifies bash/sed/jq/yq resolve to the MODERN Homebrew builds, re-prepends
# /opt/homebrew/bin to PATH, and bitches vocally about any 2007-era /bin/bash
# or BSD sed it finds. Run `just check-env` directly, or `source tools/env-check.sh`
# from your login/agent startup so every session checks once.
check-env:
    bash tools/env-check.sh

# Verify the MMU takeover contract is intact (class A — ADR 0006 supersession + kernel T0SZ=16/TLBI comments; deterministic, no VM — claims 0022/1517)
verify-mmu-debt:
    bash tools/verify-mmu-debt.sh

# Enforce the kernel `.bss` ceiling (class A — ADR 0013 D3.1; deterministic, no VM). Builds the kernel, reads the linked ELF's `.bss` size, and fails if it exceeds the explicit 7.0 MiB budget.
verify-bss-budget:
    bash tools/verify-bss-budget.sh

# Verify the multiagent coordination surface (class A — claims are GitHub issues labeled `claim`; the gate reads open issues via gh and fails on Touches overlaps between different branches)
verify-coordination:
    bash tools/status/verify-issue-coordination.sh

# Regenerate (default) or verify (--check: fail on drift) the machine-generated
# gate fleet inventory (M40 GF1, issue #934 — docs/gate-fleet-inventory.md).
# The check is the registration guard: every added/removed/renamed script
# under tools/ must ship with a regenerated report.
[positional-arguments]
inventory-gates *ARGS:
    #!/usr/bin/env bash
    bash tools/inventory-gates.sh "$@"

# Lint the GitHub Actions workflows (class A — actionlint, pinned; self-bootstraps into .build/ when not on PATH)
lint-workflows:
    bash tools/lint-workflows.sh

# Test the coordination tooling itself (class A — offline fixtures for the issue gate + staleness sweep + real-time unlabel guard)
test-coordination:
    bash tools/status/test-coordination.sh

# One issue per card, and the card IS the claim: claim an EXISTING card (issue)
# in place, adding the `claim` label + machine-read Owner/Scope/Touches fields.
# Prefer this over filing a new issue.
[positional-arguments]
claim-card ISSUE *ARGS:
    #!/usr/bin/env bash
    bash tools/status/claim-card.sh "$@"

# Rehearse the real-time claim:stale removal path end to end (live: creates + closes a throwaway claim issue; REHEARSAL_MODE=local forces the in-process guard run)
rehearse-unlabel:
    bash tools/status/rehearse-unlabel.sh

# Preview which open claim issues the weekly staleness sweep would warn on (live dry-run)
sweep-stale-claims:
    bash tools/status/sweep-stale-claims.sh --dry-run

# For an existing card, prefer `just claim-card <issue>`.
# Otherwise file an ad-hoc claim (tools/status/new-claim.sh, label `claim`),
# bare title or full flags: `just claim "Fix the flake"` / `just claim --touches ...`.
[positional-arguments]
claim *ARGS:
    #!/usr/bin/env bash
    bash tools/status/new-claim.sh "$@"

# Create an isolated per-agent checkout (issue #523 item 1; claim 4928):
#   just new-agent buffy m18-t16-scripting
# → worktree at ../virelaios-<name>, branch agent/<name>/<slug> off origin/main.
# Each worktree has its own .build/ and artifacts/, so concurrent agents
# never contend for build caches or live VM gate files. File your claim
# issue from inside the new worktree (gh issue create --label claim, or
# just claim "<title>"), not from the main one.
new-agent NAME SLUG:
    @test ! -e "../virelaios-{{NAME}}" \
        || { echo "error: ../virelaios-{{NAME}} already exists (just resume-agent {{NAME}} <branch>?)"; exit 1; }
    git fetch -q origin
    @git show-ref --verify -q "refs/heads/agent/{{NAME}}/{{SLUG}}" \
        && { echo "error: branch agent/{{NAME}}/{{SLUG}} already exists — use: just resume-agent {{NAME}} agent/{{NAME}}/{{SLUG}}"; exit 1; } || true
    git worktree add "../virelaios-{{NAME}}" -b "agent/{{NAME}}/{{SLUG}}" origin/main
    @echo "→ cd ../virelaios-{{NAME}}"

# Reattach an existing branch into its own worktree:
#   just resume-agent buffy agent/buffy/m18-t16-scripting
resume-agent NAME BRANCH:
    @test ! -e "../virelaios-{{NAME}}" \
        || { echo "error: ../virelaios-{{NAME}} already exists"; exit 1; }
    @git show-ref --verify -q "refs/heads/{{BRANCH}}" \
        || { echo "error: no local branch {{BRANCH}} (git fetch + retry?)"; exit 1; }
    git worktree add "../virelaios-{{NAME}}" "{{BRANCH}}"
    @echo "→ cd ../virelaios-{{NAME}}"

# Remove an agent worktree when its work is merged (branch kept until you delete it)
drop-agent NAME:
    git worktree remove "../virelaios-{{NAME}}"

# Show every checkout/worktree and its branch
list-agents:
    @git worktree list

# Verify the pre-exit failure path (class B — boots a VZ VM; Apple silicon only)
verify-bad-handoff:
    bash tools/verify-bad-handoff.sh

# Verify the M34 host file channel wire parity (class A — pure host-side:
# virtio_file G1–G6, VFWire S1–S4, fixture sha256 pins, BSS budget;
# issues #735/#736, claim 4515)
verify-vf-class-a:
    bash tools/verify-vf-class-a.sh

# Verify the M1.5 host-side interactive serial plumbing (class B — boots VZ VMs; Apple silicon only)
verify-host-console:
    bash tools/verify-host-console.sh
