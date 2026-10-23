#!/usr/bin/env bash
#
# build-context.sh -- generate artifacts/context.md: a deterministic,
# plaintext snapshot of the project for human or LLM review.
#
# No embeddings, no vector database, no network. Pure shell + the project's
# own files. Excludes .git, .zig-cache, zig-out, disk images and compiled
# binaries by construction (only specific text files are included).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
OUT="artifacts/context.md"
mkdir -p artifacts

fence() {
    printf '\n```\n'
    if [ -f "$1" ]; then
        cat "$1"
    else
        echo "(missing: $1)"
    fi
    printf '\n```\n'
}

section() { printf '\n## %s\n\n' "$1"; }

{
    section "VirelaiOS project context"
    printf 'Generated: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'Host: %s, macOS %s\n' "$(uname -m)" "$(sw_vers -productVersion 2>/dev/null || echo unknown)"
    printf 'Zig: %s\n' "$(zig version 2>/dev/null || echo 'not found')"
    printf 'Swift: %s\n' "$(swift --version 2>&1 | head -1 || echo 'not found')"

    section "Git status"
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        printf '\n```\n'
        git status --short --branch
        printf '\n```\n'

        section "Recent commits"
        git log --oneline -10 2>/dev/null || echo "(no commits yet)"

        section "Current diff (unstaged)"
        git diff --stat || true
        git diff || true

        section "Current diff (staged)"
        git diff --cached --stat || true
        git diff --cached || true
    else
        echo "Not a git repository."
    fi

    section "README.md"
    fence README.md

    section "AGENTS.md"
    fence AGENTS.md

    section "Build configuration"
    fence build.zig
    fence build.zig.zon
    fence justfile
    fence .zigversion

    section "docs/architecture.md"
    fence docs/architecture.md

    section "docs/hardware-contract.md"
    fence docs/hardware-contract.md

    section "docs/roadmap.md"
    fence docs/roadmap.md

    section "docs/testing.md"
    fence docs/testing.md

    section "docs/status.md"
    fence docs/status.md

    section "docs/archive/march-m3.md (milestone-three per-step tracker)"
    fence docs/archive/march-m3.md

    # Claims and per-branch logs are GitHub issues/comments since 2026-09-03
    # (label `claim`) — there are no docs/claims or docs/logs files to fence.
    # Open claims: gh issue list --label claim --state open

    section "docs/decisions/0001-arm64-uefi-zig.md"
    fence docs/decisions/0001-arm64-uefi-zig.md

    section "docs/decisions/0002-kernel-handoff.md"
    fence docs/decisions/0002-kernel-handoff.md

    section "docs/decisions/0003-ci-and-branch-rules.md"
    fence docs/decisions/0003-ci-and-branch-rules.md

    section "docs/decisions/0004-kernel-proper.md"
    fence docs/decisions/0004-kernel-proper.md

    section "boot/src/main.zig"
    fence boot/src/main.zig

    section "kernel/src/main.zig"
    fence kernel/src/main.zig

    section "kernel/linker.ld"
    fence kernel/linker.ld

    section "tools/elf2bin.py"
    fence tools/elf2bin.py

    section "host/vm-runner/Package.swift"
    fence host/vm-runner/Package.swift

    section "host/vm-runner/Sources/VMRunner/main.swift"
    fence host/vm-runner/Sources/VMRunner/main.swift

    section "image/make-image.sh"
    fence image/make-image.sh

    section "tools/inspect.sh"
    fence tools/inspect.sh

    section "Inspection output"
    if [ -f artifacts/inspect.txt ]; then
        fence artifacts/inspect.txt
    else
        echo "(none yet -- run: zig build inspect > artifacts/inspect.txt)"
    fi

    section "Runtime logs"
    for f in artifacts/*.log; do
        [ -e "$f" ] || continue
        fence "$f"
    done
} > "$OUT"

echo "context written to $OUT"
