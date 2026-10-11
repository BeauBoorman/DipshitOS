#!/usr/bin/env bash
# Run the VirelaiOS unit test suites.
#
# M41 cutover: Runs the unified parallel `zig build test` pipeline across all
# kernel modules, decoupled test suites (syscall, scheduler, monitor, shell,
# alloc, net, driving_award, ui), and shared test mocks. Also supports legacy
# individual module testing if arguments are passed.
set -euo pipefail

# Run from the repo root no matter where the script is invoked from.
cd "$(dirname "${BASH_SOURCE[0]}")/.."

if [ "$#" -gt 0 ]; then
  # Compatibility mode: run specific test targets
  echo "== zig test $@ =="
  zig test "$@"
  exit 0
fi

echo "=== verify-unit-tests: running unified parallel test suite (zig build test) ==="
zig build test --summary all

# App-level test roots (TABWM.BIN / SEXIBURG.BIN) run as direct `zig test`
# invocations rather than `zig build test` targets: their transitive
# lib/font_ttf glyph-rasterization tests print to stderr, and the Zig 0.17
# build runner relays a stale "failed command:" line for a SUCCESSFUL
# run step whenever the child had stderr output (the Step docs' own note:
# result_failed_command "may be populated even if the step succeeded").
# Direct runs keep the coverage without the noise. (M42 SX1, issue #982)
echo "=== verify-unit-tests: app-level test roots (direct zig test) ==="
zig test user/src/lib/tabapp.zig
# M42 UX r2 (claim #1011): TABWM imports the shared wnd_core dialog rule,
# so the direct run needs the module mapping.
zig test --dep wnd_core -Mroot=user/src/tabwm.zig -Mwnd_core=kernel/src/wnd_core.zig
zig test user/src/sexiburger.zig

# M97c (#2098/#2099): the tombstone engine and ld.so test blocks (incl. the
# pid-bound fault-evidence and malformed-staged-image suites) have no
# build.zig test root — both modules are only reached as guest-binary
# dependencies. Direct runs keep the coverage without claiming build.zig.
zig test kernel/src/tombstone.zig
zig test user/src/ld.zig

echo "verify-unit-tests: all unit tests passed"
exit 0
