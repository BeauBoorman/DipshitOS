# Bounded syscall tracing

Build with `bash tools/go/build-strace.sh` after provisioning the Go 1.27.1
fork. The CLI accepts:

```text
STRACE.ELF -p <pid|name> [-e slot,...]
STRACE.ELF [-e slot,...] exec <file> [args...]
```

Names must match exactly one live process, case-insensitively. The CLI polls
once per scheduler tick, stops when the target exits, and has a 120-second
ceiling. It prints cumulative loss instead of pretending the capture is
complete. The default slot mask includes all slots; use `-e` for busy apps.

## Importable API

Import `virelai/strace`, not its `cmd` package:

```go
func Arm(pids, slots []uint64) (*Session, error)
func ArmExec(file string, args []string, slots []uint64) (*Session, uint64, error)
func Render(record vi.TraceRecord) string

type Session struct{ Token uint64 }
func (s *Session) Exec(file string, args []string) (uint64, error)
func (s *Session) Filter(pids, slots []uint64) error
func (s *Session) Disarm() error
func (s *Session) Status() (vi.ObserveReadHeader, error)
func (s *Session) Read() ([]vi.TraceRecord, uint64, error)
func (s *Session) Drain(maxBatches int, fn func(vi.TraceRecord, string) bool) (uint64, error)
```

`ArmExec` returns the session and already-traced child pid. The kernel pins
this opt-in spawn to the caller's core and adds its pid before releasing
the IRQ-masked exec locks. Ordinary exec is unchanged. The child inherits
the caller's uid and capabilities.

Nil `slots` selects all slots; an empty non-nil slice selects none. Filters
replace the entire target set and mask. There is one session system-wide,
owned by its opening uid, recoverable by that uid or `cap_proc_admin`.
Opening another invalidates the old token. Disarm retains unread records.
Reads return at most 16 whole records and cumulative dropped count. Callers
must sleep between empty polls and disarm when finished. `Drain` is the
shared read-render-print loop the three consumers used to open-code: it
reads until an empty batch (or a batch bound), prints each rendered record,
and hands the caller's callback the record and its line for counting,
retention, or early exit.

`Render` returns one line without a newline. Strings are escaped, truncated
captures have `…`, inaccessible input has `<fault>`, and native negative
results retain native errno names, including the file/socket domain aliases.
CNTPCT and all six raw arguments remain available in the record. Slots 70/71
never copy user memory and contain no args/results/string bytes; the renderer
also refuses to reveal them even if given a malformed record.

`live-strace` tests the legacy monitor path and the ring. Its measurement
boot is explicitly opt-in with `TRACE_MEASURE=1`: run it only while holding
the VZ lock on a quiet host. Without that opt-in, the report says overhead
was not measured. The fixture reports seven interleaved off/on pairs for
10,000 calls, a separate 100,000-call baseline/filtered comparison, and CNTFRQ.
Each pair reports raw aggregate durations; summaries retain median/min/max
added cost. Confirm no other VMRunner or worktree build/test process before
the set, hold the VZ lock throughout, and record `uptime` before and after.
The owner's 2026-10-06 rulings withdraw the former load-average cutoff and
clarify that ADR budgets apply to added mean, not paired spread. Disclose
spread as measurement noise.

`TRACE_CAPTURE_MEASURE=1` opts into seven 10,000-call off/on pairs with
128-byte input strings. A guest ARM64 assembly seam brackets each slot-23
SVC with serialized CNTPCT reads; invalid flags return EINVAL before file
allocation or host I/O. The ring is checked for complete, unfaulted 128-byte
copies. Sample arrays are touched beforehand and published afterwards.
Raw little-endian tick arrays retain each off/on duration in pair order.
The gate independently recomputes added mean and nearest-rank p95. Absolute
traced p95 is also reported as a conservative upper bound on added p95;
do not subtract two quantiles and call that a per-call percentile.
