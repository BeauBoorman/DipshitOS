// Package main — GOTOP's gpu tab (M111d, issue #2411): the compute counters
// the way the CPU/MEM columns already show the CPU. The numbers come through
// gpu3d.SampleStats — the handle-free STATS op of sys_gpucomp (slot 90) — so
// the monitor never claims the single compute session the workload it
// watches may be holding. `busy`/`queued` are the broker's instantaneous
// flags (a synchronous RUN leaves both at zero once its fence completes);
// `lastus`, `submits` and `completed` are the evidence a kernel really ran.
package main

import (
	"errors"

	"virelai/gpu3d"
	"virelai/vi"
)

// GPUView is the gpu-tab state.
type GPUView struct {
	Stats     gpu3d.ComputeStatsBlock
	OK        bool
	refreshed bool
	err       error
}

// gpuSampleStats is the deliberate injection seam — host tests stub it the
// same way gpu3d's own tests stub CompSyscall/CompMap.
var gpuSampleStats = gpu3d.SampleStats

// NewGPUView builds an empty view (safe defaults: no sample yet).
func NewGPUView() *GPUView { return &GPUView{} }

// Refresh samples the broker's counters. A refusal keeps the error — the
// tab says why rather than painting a zeroed block as if it were real.
func (v *GPUView) Refresh() {
	v.refreshed = true
	st, err := gpuSampleStats()
	if err != nil {
		v.OK = false
		v.err = err
		return
	}
	v.Stats = st
	v.OK = true
	v.err = nil
}

// gpuErrText maps the named refusal to its marker token.
func gpuErrText(err error) string {
	switch {
	case errors.Is(err, gpu3d.ErrComputeNoDevice):
		return "no-device"
	case errors.Is(err, gpu3d.ErrComputeExhausted):
		return "exhausted"
	case errors.Is(err, gpu3d.ErrComputeBusy):
		return "busy"
	case errors.Is(err, gpu3d.ErrComputeInvalid):
		return "invalid"
	case errors.Is(err, gpu3d.ErrComputeFault):
		return "fault"
	case errors.Is(err, gpu3d.ErrComputeDevice):
		return "device-fault"
	default:
		return "error"
	}
}

// Lines is the tab's text, one entry per row.
func (v *GPUView) Lines() []string {
	if !v.refreshed {
		return []string{"gpu: not sampled"}
	}
	if !v.OK {
		return []string{"gpu: no compute stats (" + gpuErrText(v.err) + ")"}
	}
	s := v.Stats
	u32 := func(v uint32) string { return vi.Itoa64(int64(v)) }
	u64 := func(v uint64) string { return vi.Itoa64(int64(v)) }
	return []string{
		"gpu compute   sys_gpucomp slot 90",
		"",
		"busy=" + u32(s.Busy) + "  queued=" + u32(s.Queued) +
			"  sessions=" + u32(s.SessionsLive),
		"last kernel " + u64(s.LastKernelUs) + " us" +
			"   total " + u64(s.TotalKernelUs) + " us",
		"",
		"submits=" + u64(s.Submits) + "  completed=" + u64(s.Completed),
		"refusals=" + u64(s.Refusals) + "  timeouts=" + u64(s.Timeouts),
	}
}

// Marker is the serial line the gate asserts: the full counter set after
// the syscall returned, or the named refusal.
func (v *GPUView) Marker() string {
	if !v.OK {
		return "top: gpu err=" + gpuErrText(v.err)
	}
	s := v.Stats
	return "top: gpu busy=" + vi.Itoa64(int64(s.Busy)) +
		" queued=" + vi.Itoa64(int64(s.Queued)) +
		" sessions=" + vi.Itoa64(int64(s.SessionsLive)) +
		" lastus=" + vi.Itoa64(int64(s.LastKernelUs)) +
		" totalus=" + vi.Itoa64(int64(s.TotalKernelUs)) +
		" submits=" + vi.Itoa64(int64(s.Submits)) +
		" completed=" + vi.Itoa64(int64(s.Completed)) +
		" refusals=" + vi.Itoa64(int64(s.Refusals)) +
		" timeouts=" + vi.Itoa64(int64(s.Timeouts))
}
