# ADR 0038: Bounded native Zig guest target

- Status: **ACCEPTED**, effective on landing
- Date: 2026-10-01 · Design card: #1879 (R1) · Index: #1880
- Approval: **drawmeanelephant**, 2026-10-01, design and numeric workload
  budgets approved subject to recording the maintainer appointment in
  the same landing change.
- Accountable maintainer: **drawmeanelephant**, appointed by the project
  owner on 2026-10-01; appointment recorded in [ADR 0030](0030-go-is-el0.md).
- Related: [ADR 0007](0007-syscall-abi.md), [ADR 0024](0024-trust-and-isolation.md),
  [ADR 0027](0027-go-threads-futex.md).

This is the single target design for A2/A3, B1–B4 and C1–C4. Implementation
recipes are recorded below; it allocates no syscall numbers. The owner separately
approved the maintainer appointment and this design with its budgets.
Downstream implementation remains gated on landing both records.

## 1. Scope and evidence

ADR 0030's A1 amendment permits four named workloads, not general Zig
desktop growth: Oliver render/meta, k4o render, serial offline Boris,
and the actual fart-app synthesizer. They remain host-built AArch64 EL0
artifacts on Apple Virtualization.framework. Go owns the desktop and
shell. No libc/POSIX guest dependency, Linux ABI, FFI, second toolkit,
boot-default change, full Zig self-hosting or expansion of the `zc` dialect.

**Source baseline:** VirelaiOS `748eba3c` (A1 merged). The kernel/runtime
sources examined are unchanged from the issues' `fc21e531` baseline.
These are observed source contracts, **not fresh VM results**:

| Boundary | Current source contract | Design consequence |
|---|---|---|
| Native calls | [syscall.zig](../../kernel/src/syscall.zig): 79 registered rows in a 128-slot namespace; `svc #0`, number in x8, arguments in x0–x5, result in x0 | Reuse ADR 0007, including its native error numbers; never import host/Linux errno values |
| Loader | [elf.zig](../../kernel/src/elf.zig), [exec.zig](../../kernel/src/exec.zig): gap-layout static ELF, up to 3 load segments; file/initialized limits 32 MiB, mapped-segment limit 64 MiB; staged shapes still have a 2 MiB staging limit | Use a deliberately gap-layout ELF; do not charge BSS as file bytes or assume the old contiguous checker covers it |
| Entry | `exec_static_elf_gap`: x0 = argc including program name, x1 = packed argv; 8×256 B argv followed by 16×128 B env | Seven user arguments maximum; env is not a third entry register or a host pointer array |
| Environment | `pack_env` / `set_envp` truncate long entries and excess count, unlike `pack_args` | Validate owned launch inputs before packing; do not claim arbitrary inherited env is lossless |
| Memory | [process.zig](../../kernel/src/process.zig): 16 mmap regions and 4,096 dynamic-page records; [scheduler.zig](../../kernel/src/scheduler.zig): 192 KiB user stack | Bound allocation below the recording capacity, not the 1 GiB virtual reservation allowed by slot 63 |
| Files | [file_table.zig](../../kernel/src/file_table.zig): 8 handles/process, 64-byte raw paths, 31-byte listing names; slot 27 returns at most 16 rows | Existing file calls suffice for bounded explicit files, not complete recursive discovery |
| Streams | Slot 1 accepts fd 1 only, at most 256 B; file reads/writes stage at most 2,048 B; [pipe.zig](../../kernel/src/pipe.zig) is a global 4 KiB sequential buffer | B1 must supply process ownership, stderr separation and EOF; a std adapter cannot invent them |
| Publication | `virtio_file.rename` selects a backend; [virtio_fs.zig](../../kernel/src/virtio_fs.zig) uses FUSE_RENAME, while the legacy Swift file-channel handler refuses an existing destination | B4 must define replace and no-replace deliberately; blanket “rename never overwrites” comments are not the contract |
| Audio | [virtio_snd.zig](../../kernel/src/virtio_snd.zig): 16-byte `AudioInfo`, negotiated format/rate/channels, 64 KiB maximum per slot-43 play | WAV export is the floor; finite converted playback is optional, not continuous audio |

The registration count includes 76 `table_storage[sys_…]` assignments
and three numeric-index assignments: 48 (`sys_drag_start`), 52
(`sys_win_move_to_workspace`) and 54 (`sys_setrlimit`). Recounting their
resolved indexes gives 79 distinct registered slots, 0–78.

### Toolchain observations

The installed Zig **0.16.0** was probed with exported function bodies,
`zig build-obj -target aarch64-freestanding-none -O ReleaseSafe
-fno-emit-bin`. These were compile-only diagnostics:

| Probe | Observed result |
|---|---|
| Fixed `std.Io.Writer` and formatting | Compiled |
| `std.heap.page_allocator`, defaults | Refused: missing freestanding page-size configuration |
| Same, 4,096-byte page sizes supplied | Refused: missing `MREMAP` in the platform definitions |
| Same, `root.os.heap.page_allocator` supplied by a fixed buffer | Compiled |
| `std.Io.File.stdout()` | Refused: missing `STDOUT_FILENO` |
| `std.process.Args` iteration | Refused: freestanding `Vector` is `void` |
| `std.Thread.spawn` | Refused: unsupported OS `freestanding` |
| Default `std.Io.Threaded` and default `std.debug.print` | Refused through missing `getrandom` |

The installed std sources also expose `std_options_debug_io`,
`std_options_FilePermissions` and `std_options_cwd`; these are root
declarations, not fields to invent in `std.Options`. `Io.File.Handle`
currently aliases `std.posix.fd_t`; freestanding supplies `void`.
`process.Environ.Block` also selects a non-vector freestanding form.
Thus a custom Io vtable **alone** cannot provide the target.
No complete native Io backend or workload was compiled or run by R1.
Diagnostic sources/output stay under gitignored `artifacts/rfc-1879/`.

## 2. Owned build and std integration

**Decision:** use the stock pinned compiler with an owned, narrowly patched
stdlib tree and a native SDK. The compiler target remains
`aarch64-freestanding-none`; “Virelai target” names this complete build
recipe, not a new upstream OS tag or an imaginary OS-plugin facility.

A2/A3 will own the following layout (proposed paths, not existing tools):

- `tools/zig/`: toolchain/dependency lock, deterministic stdlib-overlay
  materializer, linker contract and build/artifact checks.
- `user/zig/`: entry, native syscall wrapper, bounded allocator,
  platform types, synchronous Io backend and capability table.
- Allowlisted app adapters under `user/src/`, retaining upstream engines
  as pinned source inputs rather than maintaining forks of their logic.

Materialize a private stdlib from the exact compiler distribution into
`.build/zig-guest/`, verify original-file hashes, apply the tracked overlay,
and select it with **`--zig-lib-dir`**. Never edit the installed Zig tree
or a shared dependency cache. A2 records the compiler archive checksum,
dependency content hashes and patch hashes before its first reproducible
build; this RFC's commit pins are not substitutes for that lock.
No automatic dependency update during a guest build.

drawmeanelephant owns compiler/dependency upgrades and overlay drift.
Each update must revalidate the exported-body/std-negative probes, full
vtable, ELF/startup checks, resource bounds and affected host/guest goldens
and class-B gates. Until those pass, retain the previous pin or suspend
the affected workload explicitly. A patch applying cleanly is not upgrade
acceptance; changing the allowlist still requires ADR 0030 approval.

Use baseline AArch64 CPU features, single-threaded compilation, explicit
entry, no PIE, no libc and no dynamic interpreter. ReleaseSafe is the
initial acceptance mode; changing optimization/float settings requires
new goldens and bounds checks. Do not enable fast-math for the synth.

The A3 overlay is limited to selecting Virelai's **type and entry
integration**, gated by an explicit root target declaration:

1. Supply meaningful file/directory/socket/process handle and metadata
   types and the constants instantiated by the full `Io.VTable`.
   A conditional branch in `std.posix.system` may select a native type
   namespace because Io currently refers to it. That does **not** implement
   POSIX operations or map native calls to Linux numbers. Unsupported
   direct `std.posix` operations remain compile-time errors.
2. Select bounded argument/environment vector representations and native
   `process.exit`/abort behavior. Construct `std.process.Init` explicitly
   from the SDK, including the real allocator, Io, environment map and
   declared preopens; do not run the default hosted startup.
3. Prefer the existing allocator/debug/permissions/cwd hooks over patches.
   `std.Options.page_size_min` and `page_size_max` are both 4,096.
   `cwd` is an SDK directory token rooted at `/host`, not a host descriptor.
4. Implement the **entire typed vtable** with supported operations or
   explicit refusals. A3's compile test instantiates every field, not just
   a lazily analyzed import. Default `Threaded`/Evented backends and
   `std.Thread` are excluded from the first-stage dependency graph.

`std.Io.failing` is not a production default: it can fabricate zero random
bytes and misleading filesystem answers. Pure containers, parsing,
formatting, hashing, caller-allocated algorithms and fixed readers/writers
stay upstream. Unsupported platform behavior is never papered over with
success-shaped stubs.

## 3. Startup, allocation and termination

Use exactly two load segments: R+X text/rodata at `0x0040_0000` and
R+W data/BSS at `align4096(text_end) + 4096`. The deliberate gap selects
the env-capable loader path even when text ends on a page boundary.
Include writable startup state so the second segment cannot disappear.
Keep the full mapped image, including the loader's rounded argv/env tail,
below `elf.gap_base_max`. No PT_INTERP, PT_DYNAMIC, PT_TLS, unresolved
symbols, required runtime relocations or W+X segment is accepted.

The SDK exports `_start` with the native register convention, validates
argc and bounded NUL termination, and builds stable pointer/slice views.
The env block starts at `argv + 2048`; scan at most sixteen slots, stopping
at an empty entry. Never zero or allocate through the loader's argument
tail. The program name is argv[0], not the first input path.

Owned launchers reject >7 user arguments, >255 bytes/argument, >16 env
entries or >127 bytes/`KEY=VALUE` before launch. The SDK rejects malformed
received blocks as `InvalidStartupBlock`; it cannot recover bytes already
truncated by another launcher. Slot 28 has no env parameter. A2 must prove
environment delivery using the existing env-capable launch route and
document the other routes' limitations, not promise general inheritance.
Workload behavior must not rely on ambient env to bypass CLI limits.

Allocate **one** bounded, populated anonymous RW arena using slot 63.
Include all heap allocations, input/output buffers, std state, alignment
waste and allocator metadata within the workload's aggregate cap.
Suballocate with reuse on free; `root.os.heap.page_allocator` draws from
that same arena rather than mapping per allocation. Unsupported alignment
or exhausted capacity returns allocation failure. Resize/remap may refuse;
an allocate-copy-free fallback charges both live allocations.

The arena stays mapped until process exit; individual frees return storage
to the allocator, not physical pages to the kernel. This keeps mapping
count bounded and avoids assuming repeated/partial munmap behavior.
Slot 64 exists, but is not needed for this first-stage allocator.
Failure to reserve/populate the arena is `OutOfMemory` and exits before
opening outputs. A2 must measure post-exit reclamation, including a failed
reservation; a failing native cleanup contract is a blocker, not permission
to hide it with an SDK success result.

Normal exit flushes both output streams, closes owned handles, and uses
slot 3. Success is 0; usage, I/O, resource and unsupported-operation
failures are nonzero with a bounded diagnostic on stderr. A failed flush
must change the exit result. Panic/abort uses an allocation-free diagnostic
and nonzero exit, not default `Threaded` debug I/O. Before B1, SDK fixture
diagnostics may use chunked slot-1 console output, but do not establish
separate stdout/stderr support.

## 4. Approved first-stage budgets

These are **chosen first-stage ceilings**, not measured workload footprints
or promises that every within-limit input succeeds. Heap exhaustion and
other resource refusals remain possible below an input/output ceiling.
If the pinned engine cannot meet them, hold that workload and seek an
explicit budget amendment. Do not silently adopt host defaults.

| Workload | Input bytes | Normal output bytes | Aggregate arena | User-stack budget | Open SDK resources |
|---|---|---|---|---|---|
| Oliver render/meta | 128 KiB total stdin | 512 KiB | 8 MiB | 128 KiB | 3 streams + 2 files |
| k4o render | 128 KiB template + 128 KiB JSON | 1 MiB | 8 MiB | 128 KiB | 3 streams + 2 files |
| Boris serial offline | 128 KiB/file, 1 MiB aggregate content/templates/assets/config | 2 MiB aggregate staged artifacts | 12 MiB | 128 KiB | 3 streams + 5 file/directory/cursor resources total |
| fart-synth WAV | 255-byte phrase or one u64 seed | 441,044 B WAV (5 s mono S16 at 44,100 Hz plus 44-byte header) | 4 MiB | 128 KiB | 3 streams + 1 file |

Common ceilings and enforcement:

- **Image:** file ≤8 MiB and page-rounded load segments plus argv/env
  tail ≤16 MiB per artifact. A2's artifact check rejects `ImageBudget`.
  Stack and arena are charged separately. A maximum Boris instance thus
  budgets 16 MiB image + 12 MiB arena + 192 KiB user stack + 192 KiB kernel
  stack, before page tables/kernel bookkeeping; it is not a reservation
  guarantee in the 256 MiB VM.
- **Memory:** one ≤12 MiB arena means at most 3,072 dynamic pages, below
  the current 4,096-record capacity. Allocator accounting enforces it
  before requesting memory. No secondary unaccounted page allocator.
- **Stack:** retain the existing 192 KiB mapping; require ≤128 KiB
  worst-case use for supported input, leaving 64 KiB margin. A2/A3 own
  compiler/call-depth checks and stack high-water instrumentation in
  fixtures. Each workload must bound recursive grammar depth or reject
  that input before descending. A measured small example is not a proof
  of a worst-case bound; missing enforceable depth analysis blocks release.
  The kernel's guard fault is not the normal budget-refusal mechanism.
- **Args/env:** the 7×255 and 16×127 payload limits above; no ABI increase.
  `ArgumentLimit`, `EnvironmentLimit` and `InvalidStartupBlock` are
  SDK diagnostic names, not new kernel errno assignments.
- **Paths before B2:** ≤64 bytes for the complete native path including
  `/host/`; ≤31 bytes/component as a conservative portable subset.
  Join relative paths to the declared guest cwd, then check the full byte
  length. Never clip, normalize an escape into acceptance or route to USB.
- **Boris after B2:** propose ≤512 bytes/full guest path, ≤255
  bytes/component, nesting depth ≤8 below the supplied root, ≤256 total
  visited entries and ≤128 emitted artifact files. Count directories and
  ignored entries too. B2 must add/version the native contract and obtain
  its ADR 0007 approval before these wider limits exist. CLI path arguments
  still fit 255 bytes; generated descendants can be longer.
- **Handles:** at most 8 native handles and 8 live SDK resource records,
  including streams, directory contexts and enumeration cursors. B2/C3
  must close/materialize bounded traversal state rather than keep one
  descriptor per depth plus three streams. A full table refuses
  `HandleLimit`; it never evicts a live handle.
- **Diagnostics:** ≤16 KiB per invocation, separate from normal output
  and charged to memory when buffered. Exhaustion emits one reserved
  bounded `DiagnosticLimit` message, stops work and exits nonzero.
- **I/O:** budget-aware reads probe one byte beyond a full input limit;
  capped writes reject before publication. `InputLimit`, `OutputLimit`,
  `TreeLimit`, `PathLimit` and `OutOfMemory` name distinct refusals.
  k4o's `--max-output=0` or a value above 1 MiB is rejected, not unlimited.
  C1 must enforce Oliver's 128 KiB stdin limit in its own guest adapter;
  no host CLI input-limit flag supplies that enforcement. Its boundary
  tests accept 131,072 bytes and refuse 131,073 as `InputLimit`.
- **Synth:** preflight the phrase plan/sample count, refusing >220,500
  samples as `DurationLimit` before rendering. Optional playback uses at
  most 65,536 **converted** bytes in one slot-43 call; longer audio is
  WAV-export-only or explicitly `PlaybackLimit`. No repeated START/STOP
  chunks disguised as seamless playback.

## 5. Capability and native-facility map

Every backend operation has an explicit supported/refused entry. Native
failure maps to the narrow std error set where truthful. If the std set
cannot name the refusal, return `Unexpected` with a bounded named native
diagnostic; never return zero bytes as success/EOF for an unsupported call.
For a no-error-return API, exclude the caller at compile time or terminate
with a named unsupported-operation diagnostic. Do not invent a timestamp,
identity, successful lock, random bytes or successful close.

| Requirement | First-stage route | Owner / unsupported boundary |
|---|---|---|
| Args, env, init, allocation, exit, panic | Entry adapter, hooks, slots 63/3 | A2; no hosted startup, fork, signal emulation or compiler TLS |
| stdin/stdout/stderr; `operate` streaming arms, writer flush | Native process stream bindings from B1; chunk confirmed writes, preserve short reads | A3+B1; absent input binding is refused, not attached to unrelated tty input |
| Open/read/write/close, bounded mkdir, truncate, sync | Slots 23–26, directory-create mode, 36, 77; native flags translated explicitly | A3; existing write-open truncates, so read/write open is not automatically POSIX-compatible |
| Seek, positional I/O, append, exclusive create | Implement only semantics supported by a proven primitive; first-stage engines use sequential input and buffered render/output | A3 audits callers; no fake seek, reopen-and-truncate emulation or racy stat-then-create; unsupported option combinations refuse |
| Directory iteration, path/name widths | Versioned complete enumeration with bounded cursor lifecycle and explicit end-of-directory | B2; legacy slot 27 is not a complete walker, even when repeatedly called |
| Stat/length, identity, timestamps, no-follow | Honest metadata and contained lookup/open on supported backends | B3; before it, operations requiring full `File.Stat` refuse rather than synthesize inode/mtime/mode |
| Replace and preserve-existing rename | Distinct operations, source/destination trust checks, same-share staging | B4; preserve-existing must not silently become overwrite on VirtioFS |
| Cwd, relative directory operations, executable name | Bounded SDK path/token state rooted in the supplied guest share | A3; not host cwd, host descriptors, chdir syscall or arbitrary host path access |
| Permissions/ownership | Preserve kernel principal/capability checks (slots 68/69 where applicable); truthful native permissions type | A3/B3; no fabricated chmod/chown success or capability elevation |
| Monotonic clock; wall time; sleep | Existing EL0 counter/frequency convention, slot 66 wall seconds and slot 4 tick sleep | A3 only if reached: report actual resolution, wall-unavailable refusal; no sub-tick parked-wait promise |
| Randomness | Caller-seeded deterministic synth; slot 72 for secure entropy, including C3's atomic-commit path | A3/C3; no ambient entropy required by the three audited pure engine paths, but Boris publication requires end-to-end entropy verification; no zero-filled fallback |
| Async/concurrency, mutex/futex | Synchronous `async` completion where the Io contract permits it; `concurrent` returns `ConcurrencyUnavailable` | A3; no non-progressing wait pretending success; threads/TLS/timed-wait depth belongs to conditional B5 |
| Network, subprocesses, file-backed mmap, links, watch | Compile out or explicitly refuse in the first-stage adapters/backend | A3/C3; existing sockets/readiness 30–33/76 and threads/futex 73/74 are not blanket Zig std support; B5/B6 remain conditional |
| Audio | Pure deterministic WAV, optionally query 42 then convert and submit raw PCM with 43 | C4; absent device refuses; no WAV header in PCM, no host speech/audio commands; B7 remains conditional |

B1 supplies a bounded **per-process** stream binding contract at spawn,
with endpoint ownership/refcounts, direction, close, teardown, inheritance
and explicit EOF. File-redirection or immutable bounded input is enough for
the first CLI proofs; general concurrent Unix pipes are not required.
Three stream identities must not alias native file handles 0–2 accidentally.
Separate destinations remain separate through panic/debug paths. B1's wire
extension, if needed, goes through ADR 0007, not an overloaded undocumented
argument register or env side channel.

Before B3, A3's explicit-file helpers read sequentially to EOF with the
input-limit probe, without requiring full stat or seek. C1/C2 adapt their
CLI I/O glue to those helpers when an upstream convenience reader assumes
metadata. They do not make up `File.Stat` fields to keep an unchanged host
`main` compiling. Errors flushing output remain errors even where a host
entry point currently ignores them.

B2 must return lossless names and a continuation/end indicator. Cursor
reuse across processes, stale/closed cursors and capacity exhaustion
refuse. Mutation during enumeration must have a stated restart/error or
stable-snapshot contract, not silent omissions or duplicate pages.
Preserve old callers with a versioned/additive interface.

B3 supplies stable identities within a declared filesystem lifetime
(including a filesystem discriminator if the backend needs one), not a
path hash or universal zero. For Boris, no-follow and containment must
hold through lookup/open and mutation, not merely a preflight stat.
Test a replaced directory/symlink between check and use. Unsupported
metadata or a backend that cannot preserve containment blocks that path.
Watch remains excluded even if its metadata prerequisites become available.

B4 must prove replace, preserve-existing, and failed-replacement preservation
on each supported backend. An unsupported backend refuses before touching
the destination. No delete-then-rename or overwrite-copy fallback may stand
in for failure-preserving replacement. File sync exists; do not promise
directory-fsync/power-loss durability or an atomic multi-file site switch
without the corresponding primitive and evidence.

## 6. Workloads, pins and order

Retain these exact upstream inputs for the initial implementation:

| Workload | Pin | Adapter and acceptance boundary |
|---|---|---|
| [Oliver](https://github.com/drawmeanelephant/oliver/tree/3615e6253f0e17b410cf1b987507d30bfcde537c) | `3615e6253f0e17b410cf1b987507d30bfcde537c` | C1 refreshes the real-library proof, then render/meta CLI; stdin EOF, pure HTML/JSON stdout, diagnostics on stderr. Reuse parser/renderer semantics; unsupported commands refuse before work |
| [k4o](https://github.com/drawmeanelephant/k4o/tree/59f88233589d2643ba5b4f380e3db70664bba2b3) | `59f88233589d2643ba5b4f380e3db70664bba2b3` | C2 reuses `renderFormatWithLimit`: textile/markdown/gfm goldens, template+JSON files, explicit allocation/output refusals. Buffer rendering so invalid input never emits partial normal output |
| [Boris](https://github.com/drawmeanelephant/boris/tree/08969742f85238443ce5cd1cd53ceab1b1f3f85a) | `08969742f85238443ce5cd1cd53ceab1b1f3f85a` | C3 is a distinct serial offline build retaining the compiler, scanner and publication semantics, not the normal hosted CLI with a runtime flag |
| [fart-app](https://github.com/drawmeanelephant/fart-app/tree/bd453937b30ae6eb28c69f6a497ba202efe4cd05) | `bd453937b30ae6eb28c69f6a497ba202efe4cd05` | C4 imports the actual `synth.zig` path and its local dependencies; deterministic WAV goldens and OOM/duration refusals, optional finite playback. Go FART is a different program |

Oliver and k4o declare no package dependencies in their pinned manifests.
Boris pins its **own Oliver revision**
`80d53b2118005b314d4c551d18a023f293eecc75`
(`oliver-1.1.0-LOsZkBWrJwAXanVPCdrIH78YlOL63fgQUUSBhIBLXwhm`);
do not silently replace it with C1's newer pin. Its normal executable
unconditionally links libc-enabled secp256k1 at
`6e2c8bc4ecdc6e71dbe7a368f360d8d453ce435d`.

C3 must exclude keys/auth/network/preview modules and that dependency from
the **build graph**, then link-check the complete offline compiler path.
`jobs=1` as a runtime default does not remove the `std.Thread.spawn` branch
in `compile.zig`; the guest build needs compile-time serial selection.
Boris's no-libc build remains unverified. If required offline semantics
still reach a hosted dependency or missing file operation, C3 stops with
that exact blocker rather than emitting placeholder artifacts.

C3's atomic-commit path must exercise the native entropy adapter through
slot 72 end to end, including short-fill/error handling and explicit
entropy-unavailable failure before publication. A working deterministic
render engine does not prove temporary-file naming or atomic commit.
No zero bytes, deterministic temporary-name fallback or ignored entropy
failure may substitute for that verification.

Boris's `artifact_sink.Dir.commit(false)` intentionally removes selected
outputs, and its cross-device fallback copies over a destination. Neither
is acceptable as a target-side “failed replacement preserves old content”
implementation. The guest publication adapter must retain prior good
outputs on budget/I/O/publication failure, keep diagnostic failure reports
separate, and reject cross-device fallback. B4 guarantees each individual
replacement, not rollback of earlier successful replacements in a batch.
The host/guest golden harness must distinguish those semantics.

**Implementation order after this accepted design lands:**

1. A2 #1866: startup/build/artifact fixture, bounded allocator, pinned lockfile.
2. A3 #1867 and B1 #1868: std integration and real process streams.
   Define the B1 contract before binding it in A3; these are not two
   agents editing the same ABI/SDK files at once.
3. C1 #1875 / C2 #1876: first library refresh and CLI proofs. Refresh
   `live-oliver` rather than cloning it; CLI acceptance requires A3+B1.
4. B2 #1869, B3 #1870, B4 #1871: coordinate shared kernel/backend files
   in sequence, then C3 #1877. C4 #1878 can run alongside filesystem
   work after A2/A3; CLI standard-stream adoption also consumes B1.
5. B5 #1872 is activated only for the explicit-context subset below.
   B6 #1873 and B7 #1874 remain conditional. Parallel
   Boris, preview/watch/network, NINJAM and continuous audio require a
   later owner-approved scope and design amendment.

Oliver walk/mutation remains outside this first stage even after B1–B4.
Do not reopen completed loader/RNG/Go-thread/fsync bring-up to make the
dependency graph look larger. A failed existing primitive is a precise
blocker to investigate, not proof the whole facility is missing.

## 7. Verification and approval

**A2/A3 class A:** reproducible builds from the lock; exported-body probes
for all supported std paths and named compile-time negatives for excluded
paths; complete Io vtable instantiation; argv/env malformed/boundary cases;
allocator reuse/OOM and short-write/zero-progress/EOF error tests.

A2 must validate its emitted ELF against the **current kernel parser** and
the narrower SDK profile, including file/mapped/argument-tail budgets.
Extend the existing artifact-checking machinery with an explicit SDK
profile and cross-tests against `elf.parse_head`; preserve the `zc` profile.
[`check-zc-host-contract.py`](../../tools/check-zc-host-contract.py) currently
requires ≤2 contiguous segments and ≤512 KiB, so its present “CONTRACT OK”
does not establish gap-layout SDK compatibility. Correct its stale blanket
claims within A2, without changing the `zc` dialect.

**Native class B:** extend existing declarative specs where they already
cover the seam: `live-el0-exec`/`go-args` for unchanged loader consumers,
`live-vm-depth` for native memory regressions, `live-user-fs` and
`live-trust-modes` for file/security behavior, and `live-oliver` for C1.
Use a new declarative spec only for a genuinely uncovered workload.
No new `verify-*.sh`, committed logs or generated fleet snapshot.

Acceptance must include:

- Startup argv/env bytes read back independently, long-argument refusal,
  clean exit, failed allocation and post-exit resource recovery.
- B1 stdout/stderr isolation, >256 B output, >2,048 B file I/O,
  redirected EOF, short writes, disconnect/close, two-process isolation.
- B2 >16 entries, colliding 31-byte prefixes, exact/over name/path/depth/
  entry limits, cursor close/death and directory mutation.
- B3 distinct/stable nested identities, no-follow root/intermediate/leaf,
  containment races, permission denial, real metadata or named refusal.
- B4 two publications, no-overwrite, injected failure preserving old
  content and both-end authorization on VirtioFS and the legacy backend.
- C1/C2 independent host-engine output comparisons, supported CLI options,
  invalid-input diagnostics and all budget refusals. Library-only success
  is labeled separately from CLI acceptance.
- C3 complete no-libc dependency/link closure, host/guest compiler artifact
  comparison on a nested corpus, second publication and failure cases;
  atomic-commit entropy through slot 72, including failure preserving
  prior published content.
- C4 byte-exact WAV with independent RIFF/sample-count checks, deterministic
  repetition, allocation/duration limits and missing-device refusal.
  Optional playback independently checks converted PCM format and byte
  count; a WAV file or syscall marker alone is not audible acceptance.
- Per-workload measured file size, mapped bytes, arena peak, stack bound,
  peak handles and cleanup. Limits are tested at and beyond the boundary;
  evidence remains under `artifacts/`, not narrative reports in git.

R1 itself is **docs-only**: source cross-checks, compile-only diagnostics,
local-link checks, `git diff --check` and the issue-coordination gate are
its validation. No VM gates, complete workload builds, audible results or
newly supported std behavior are claimed by this record.

**Acceptance:** drawmeanelephant approved the build/overlay ownership,
capability/refusal map, numeric budgets and verification/dependency order
on 2026-10-01, with the maintainer appointment recorded in ADR 0030 in the
same landing change. This record includes the registration-count
clarification and explicit C1 input-limit / C3 entropy requirements from
that review. Only the approved landing unblocks A2 and the dependency
order above. Remaining measurements belong to the named implementation
cards and are release gates, never assumed successful results.

## 8. A2 implementation and use

The A2 fixture is `user/zig/fixture.zig`; the reusable entry adapter,
startup views, single-arena allocator and console-only runtime live beside
it. `tools/zig/lock.json` pins official compiler archives. A2 introduced no
third-party packages and an empty std overlay; A3 adds the narrowly owned
type/Io integration in §9. The materializer verifies every original
file against the pinned archive, refuses drift/additions, and never edits
the installed compiler or downloads during a build.

```sh
python3 tools/zig/sdk.py fetch          # explicit one-time network step
python3 tools/zig/sdk.py build          # .build/zig-guest/ZGUEST.BIN + receipt
zig build zig-guest-check              # two fresh caches, parser/probes/unit tests
bash tools/gate/vgate.sh tools/gate/specs/live-el0-exec.spec
bash tools/gate/vgate.sh tools/gate/specs/live-vm-depth.spec
```

The receipt includes compiler/archive/library/input hashes, artifact hash
and maximum compiler frame. Builds emit assembly for per-function frame
checks; the entry paints 132 KiB below SP and the fixture measures high-water
use against the 128 KiB budget. Neither proves arbitrary recursive workload
depth: A3/C1–C4 must supply their own enforceable call-depth bounds.
Archive pins also exist for Linux build hosts; native execution remains
macOS 27+/Apple silicon/VZ, and A2's observed compiler host is arm64 macOS.

The monitor env route has a **narrower** limit than the loader: sixteen
variables, names ≤32 bytes and values ≤64 bytes (`shell.zig`), with silent
clipping before packing. The live fixture uses only lossless inputs on
that route; host tests separately exercise all sixteen 127-byte ABI
entries. `startup.pack` rejects invalid/over-limit owned inputs before
writing; slot 28 still has **no environment parameter** and takes user
arguments only, with the gap loader prepending the program name.

A2's console writes are synchronous and unbuffered. Startup refusal exits
64, application/resource/write failure exits 70, and panic exits 71;
success is 0. A2's modes open no file handles or streams. A3 adds explicit
files, flush/close and `std.process.Init`; separate stderr remains B1 work,
not a success-shaped placeholder. The live reservation-failure fixture fills
the native region table using unpopulated pages, then verifies SDK
`OutOfMemory` and post-reap page recovery without exhausting physical RAM.

## 9. A3 std boundary and upgrade contract

**Owner:** drawmeanelephant maintains `tools/zig/overlay.json`,
`user/zig/platform.zig`, `io.zig`, `operations.zig`, `refusals.zig` and
the root hooks in `runtime.zig`. The six-file overlay selects native
types, argument/environment views, declared preopens, exit/abort and the
explicit rejection of the default `Threaded` backend. Every selection
requires both freestanding and the root `virelai` declaration. It does
not implement POSIX. Archive checksums, original-file checksums, unique
replacement anchors and the lock's overlay checksum all fail closed.
Materializations are private and keyed by archive **and** overlay hashes.

### Target recipe

Use the §8 offline builder/checker. The complete root contract, also used
by every native exported-body probe, is:

```zig
const std = @import("std");
const sdk = @import("runtime.zig");
pub const virelai = sdk.platform;
pub const os = sdk.os;
pub const std_options = sdk.std_options;
pub const std_options_debug_io = sdk.std_options_debug_io;
pub const std_options_FilePermissions = sdk.std_options_FilePermissions;
pub const std_options_cwd = sdk.std_options_cwd;
pub const panic = std.debug.FullPanic(sdk.panic);
```

The root explicitly exports `entry.zig`'s native entry, calls
`sdk.initialize(arena_bytes)` before using Io/debug, and constructs
`sdk.InitState.init(startup)` in stationary storage. `InitState.get`
supplies the real allocator, Io, args, borrowed environment vector, env
map and borrowed `/host` cwd preopen. Do not free the loader's borrowed
args/environment. `InitState.deinit` frees only its owned allocations.
No stdin/stdout/stderr preopens are declared before B1.

`sdk.py build` records the exact compiler flags: private `--zig-lib-dir`,
`-target aarch64-freestanding-none -mcpu baseline -O ReleaseSafe
-fsingle-threaded -fno-PIE`, native entry/linker script and no libc.
Compilation without single-threaded selection is rejected by name.
Using the installed stdlib instead of this recipe is **not** this target.

| Audit probe | Result under this recipe |
|---|---|
| Default page allocator, including the configured-page variant | Supported through `root.os.heap.page_allocator`; both page sizes are 4,096. Resize/remap refuse and allocations remain in A2's single arena |
| `File.stdout()` and incomplete handles | Supported typed SDK tokens; stdin/stdout/stderr are distinct negative identities, not kernel handles 0–7. Actual unbound stream I/O returns `Unexpected` plus `Unsupported:UnboundOrClosedInput/Output`, never EOF or discarded writes |
| `Thread.spawn` | Compile-time single-threaded refusal; B5 uses a separate explicit native API, not a std backend |
| Default `Io.Threaded` (`getrandom` / `IOV_MAX`) | Named `VirelaiUnsupportedThreaded`; use `sdk.io`, not invented constants to make a hosted backend compile |
| Default `debug.print` | Supported by the explicit debug Io hook, allocation-free chunked slot-1 console diagnostics **after initialize**, not a claim of stderr separation |
| Direct POSIX `PROT`, `MREMAP`, errno or `getrandom` | Named `VirelaiUnsupportedPosix`; the allocator/entropy paths do not instantiate POSIX primitives or import Linux errno values |
| Args/env, exit/abort | Native views and std Init compile; normal exit cleans up SDK files, abort diagnoses and exits nonzero |

### Capability/refusal ownership

`operations.zig` pins all **109** Zig 0.16 vtable field names and order.
The complete typed table is linked, including every refusal body. A field
with no implementation in `Backend` uses the signature-preserving refusal
adapter: `OperationUnsupported` / `UnsupportedOperation` when available,
otherwise `Unexpected`, with `Unsupported:<operation>` diagnostics. If the
return type cannot express a truthful refusal (including cancellation-only
errors), it diagnoses and exits 70. There is no `Io.failing` fallback.

| Implemented selection | Exact scope / limit |
|---|---|
| `dirOpenFile`, `dirCreateFile`, `dirCreateDir` | Sequential read-only open; write-only create/truncate; single mkdir with default native permissions. Reject read/write or write-only nontruncating open, exclusive/append, locks, custom permissions, no-follow/resolve-beneath requests **before** calling the kernel |
| `operate` file arms, `fileClose`, `fileSync`, `fileSetLength` | Slots 23–26/36/77; ≤2,048 B chunks, confirmed short counts, zero write progress is an error, EOF only from a real input read. Truncate rejects lengths above u32 before narrowing. Close failure terminates for std's void API; SDK `closeChecked` is fallible |
| Positional reads/writes and seeks | `Unseekable`, allowing std Reader/Writer's supported streaming fallback at initial offset zero. No fake positioning |
| Cwd/path state | Borrowed `/host` token and `processCurrentPath`; ≤64 B full paths and ≤31 B components. Reject escapes, NUL, empty/dot components and non-host absolute paths. This is **not** B3's symlink/TOCTOU containment proof; cwd changes and directory opens/iteration refuse |
| `randomSecure`, `random` | Slot 72, ≤256 B confirmed fills; short fills loop, zero/error/overcount fails `EntropyUnavailable`. The void API terminates on failure, never seeds a deterministic fallback |
| `async`, `groupAsync`, cancellation state | Synchronous completed work, no future/task allocation. `concurrent`, `groupConcurrent`, concurrent batches return `ConcurrencyUnavailable`; parked waits and asynchronous batches refuse |
| Debug lock/unlock | Single-threaded synchronous console hook; flush/write failures are fatal, nested lock refuses, only no-color mode. Ordinary `File.stderr()` still refuses before B1 |
| Everything else in the pinned table | Explicit refusal: stat/length/full metadata (B3), traversal (B2), publication/rename (B4), permissions/ownership changes, links, file-backed mmap, subprocesses, network, tty queries, clocks/sleep and futexes. No forged stat, time, identity, successful lock or successful unsupported close |

Use `io_helpers.readBounded` for metadata-free sequential input, including
the extra-byte limit probe. Buffer/render and check the workload output
limit **before creating/truncating the destination**; `writeBounded`
additionally checks it before writing. Flush each application-owned writer
explicitly and propagate failure before `sdk.finish`. Generic hosted
convenience readers requiring stat/seek and atomic publishers are not
silently made compatible.

**Existing native finding, no A3 ABI change:** `file_table.close` discards
the host backend's close status before returning slot-26 success. A3 can
check only the native result; it does not claim host-close durability.
Explicit slot-77 sync is tested and failures propagate. Any requirement to
expose host-close failures belongs to a separately approved native B-card.

### Budgets and upgrade checks

Backend records and dynamic std state use the same arena. A3 conservatively
allows four open files plus three reserved stream identities and one
borrowed cwd, at most eight SDK resources; stale tokens cannot alias a
reused native fd. This does **not** expand Boris's resource budget.
Diagnostics retain A2's aggregate 16 KiB cap and reserved limit message.
The fixture reserves 1 MiB; no workload ceilings or boot defaults change.
SDK file helpers are iterative, not recursive tree walkers. Compiler-frame
and stack-paint checks cover the fixture, not arbitrary user formatters or
engine recursion; C1–C4 still need their enforceable input/call-depth bounds.

On **every compiler upgrade**, re-pin archives and review all six original
file hashes/anchors, the root hooks' types, native handle/constants,
argument/environment/entry selection and all 109 vtable signatures,
including `Operation` arms. Run `zig build zig-guest-check` (two clean
offline builds, ELF/parser corpus, exported-body positive/negative probes,
fatal-refusal subprocesses and SDK unit tests), `zig build test`, and
`live-el0-exec`, `live-vm-depth`, `live-user-fs`, `live-trust-modes`.
Preserve the unmarked stock-target negative probes and the `zc` checker.
Re-run affected workload goldens and gates when those workloads exist.
Clean patch application alone is never upgrade acceptance. Test counts,
measurements and observed versus blocked native steps belong in the landing
PR and local gate artifacts, not a duplicated status log here.

## B5 amendment — explicit native threads (#1872)

The owner's B5 implementation prompt activates this bounded subset, not
parallel Boris or a new worker budget. `user/zig/threads.zig` supplies
allocation-free `Thread.spawn/join`, `attach`, `wait/wake` and an optional
caller-owned mutex. Keep A2/A3's SDK, allocator, std.Thread, Io.Threaded
and concurrency refusals unchanged. Native children run on core 0, sharing
its preemptive/cooperative scheduler; no multicore speedup is promised.
This keeps exit-stack reclamation serialized with the core-0 idle reaper.
Workers must not call the SDK's
single-threaded allocator/backend. No detach, cancellation, nested join
dependencies, hosted startup or automatic ELF TLS loading is supported.

**TLS/context:** the pinned compiler probes establish AArch64 variant-I
static local-exec: TPIDR_EL0 plus a 16-byte prefix rounded to TLS alignment.
The #1907 planner initializes an explicit caller-supplied template, zeros
its remaining memory and padding, and refuses alignment/capacity/overlap.
B5 installs this real TP register before a child starts and saves/restores
it on IRQ, yield and parked-wait switches, including park
back to kernel tasks. General registers, SP, PC and SIMD registers use the
existing exception frame. Reserve x18 in the native compiler recipe because
the exception frame does not preserve that platform register. Changing
FPCR/FPSR is outside this subset.

The caller provides disjoint mapped writable stacks (at least 4 KiB,
16-byte aligned top), TLS buffers and a read-only template. These remain
owned and alive until successful join. The explicit API reserves the
prefix for its entry/argument; the body uses the planner's returned
`tls_offset`, not a hard-coded offset for alignments above 16. Initialized
and zero-only bytes are independent per task. Primary-task `attach` must
precede TP-relative access. Raw `threadlocal` in production artifacts still
refuses through the unchanged SDK ELF checker/linker: compiler-emitted
PT_TLS, PIC/TLSDESC and dynamic TLS are **not** implicitly loaded by B5.
This is an explicit native context API, not a std.Thread port.

**Lifetime/capacity:** sixteen extra threads per process, the existing
64-task global pool (shell/worker/idle included) — both raised by M129b
(#2611) from six and 16 — and one existing 192 KiB kernel
exception stack per child. Caller-owned stack/TLS bytes charge the existing
mapped-image or mmap limits. Allocation or pool exhaustion refuses with
`Capacity`; no budget grows. An exited native child retains its task seat
and exception stack until its single-use process-bound join token is
consumed. Retained children count against the sixteen-thread cap. Join can
park or observe an already exited child, returns its u8 status, orders its
writes and permits caller-storage reuse; idle reap frees the exception
stack. Self/foreign/stale/double joins and dependency chains refuse.
Process exit/kill/fault abandons retained tokens and uses existing sibling
kill/reap teardown. Go's zero-TLS create/exit remains detached and returns
the original kernel task ID.

**Futex/deadlines:** shared aligned u32 words use acquire/release atomics.
Compare-after-seat and wake use the same scheduler lock; seat allocation
is also under that lock. Wake is advisory and waiters recheck their
condition. The strict native wait accepts zero (indefinite) or positive
whole-second relative durations. Other durations return
`UnsupportedPrecision` before parking, and the raw syscall returns EINVAL.
An extra phase-guard tick prevents early expiry on the one-second timer.
Expiry makes the task runnable with ETIMEDOUT; wake returns 0 and a changed
word EAGAIN. Scheduling, skipped ticks and contention can delay resumption:
there is no wall-time upper bound or fine deadline guarantee. Callers with
an absolute budget must stop/recompute it themselves, never restart a full
relative timeout after a spurious wake. Overflow refuses explicitly.
Legacy Go futex op 0 keeps its existing coarse rounding contract.

**Evidence:** `zig build test` covers context selection, blocking/late join,
status, retention/reap, stale token and capacity refusal, futex contention
and both lost-wake comparisons. `zig build zig-guest-check` also builds the
x18-reserved explicit-context fixture and repeats the pinned TLS compiler
probes. Extended `live-el0-exec` runs six real EL0 contexts, contends on a
futex mutex, joins all children, refuses the seventh and fine timeouts,
checks a coarse timeout against CNTPCT, and requires independent exact
post-reap page recovery. No boot-default or app activation changes.
