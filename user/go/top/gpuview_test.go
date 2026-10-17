package main

import (
	"strings"
	"testing"

	"virelai/gpu3d"
)

// fakeGpuStats installs a canned sample through the gpuSampleStats seam.
func fakeGpuStats(t *testing.T, st gpu3d.ComputeStatsBlock, err error) {
	t.Helper()
	prev := gpuSampleStats
	gpuSampleStats = func() (gpu3d.ComputeStatsBlock, error) { return st, err }
	t.Cleanup(func() { gpuSampleStats = prev })
}

// TestGpuLinesRenderTheCounters pins the text the tab paints: the broker's
// instantaneous flags, the kernel-time pair, and the submit ledger.
func TestGpuLinesRenderTheCounters(t *testing.T) {
	fakeGpuStats(t, gpu3d.ComputeStatsBlock{
		Busy:          0,
		Queued:        1,
		SessionsLive:  1,
		LastKernelUs:  1234,
		TotalKernelUs: 5678,
		Submits:       3,
		Completed:     3,
		Refusals:      1,
		Timeouts:      0,
	}, nil)
	v := NewGPUView()
	v.Refresh()
	if !v.OK {
		t.Fatal("view must be OK after a successful sample")
	}
	text := strings.Join(v.Lines(), "\n")
	for _, want := range []string{
		"busy=0  queued=1  sessions=1",
		"last kernel 1234 us   total 5678 us",
		"submits=3  completed=3",
		"refusals=1  timeouts=0",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("lines missing %q:\n%s", want, text)
		}
	}
}

// TestGpuMarkerCarriesTheLedger pins the serial evidence: every counter on
// one line, after the syscall returned.
func TestGpuMarkerCarriesTheLedger(t *testing.T) {
	fakeGpuStats(t, gpu3d.ComputeStatsBlock{
		Busy:          1,
		Queued:        2,
		SessionsLive:  1,
		LastKernelUs:  99,
		TotalKernelUs: 999,
		Submits:       7,
		Completed:     6,
		Refusals:      5,
		Timeouts:      4,
	}, nil)
	v := NewGPUView()
	v.Refresh()
	want := "top: gpu busy=1 queued=2 sessions=1 lastus=99 totalus=999" +
		" submits=7 completed=6 refusals=5 timeouts=4"
	if got := v.Marker(); got != want {
		t.Fatalf("marker = %q, want %q", got, want)
	}
}

// TestGpuRefusalIsVisible pins that a refused STATS says so — the tab names
// the refusal instead of painting a plausible-looking zeroed device.
func TestGpuRefusalIsVisible(t *testing.T) {
	fakeGpuStats(t, gpu3d.ComputeStatsBlock{}, gpu3d.ErrComputeNoDevice)
	v := NewGPUView()
	v.Refresh()
	if v.OK {
		t.Fatal("view must not be OK after a refusal")
	}
	if got := v.Marker(); got != "top: gpu err=no-device" {
		t.Fatalf("marker = %q", got)
	}
	if !strings.Contains(v.Lines()[0], "no-device") {
		t.Fatalf("refusal line = %q", v.Lines()[0])
	}
}

// TestGpuUnsampledIsHonest pins that a never-refreshed view does not claim
// zero counters — it says the sample never ran.
func TestGpuUnsampledIsHonest(t *testing.T) {
	v := NewGPUView()
	if got := v.Lines(); len(got) != 1 || !strings.Contains(got[0], "not sampled") {
		t.Fatalf("unsampled lines = %v", got)
	}
}
