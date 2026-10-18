package main

import (
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestMeasurementStatistics(t *testing.T) {
	values := []int64{103, 101, 200, 104, 100, 99, 102}
	if got := median(values); got != 102 {
		t.Fatalf("median=%d", got)
	}
	minimum, maximum := bounds(values)
	if minimum != 99 || maximum != 200 {
		t.Fatalf("range=%d..%d", minimum, maximum)
	}
	if values[0] != 103 {
		t.Fatal("statistics reordered the measurements")
	}
	if measurementPairs < 7 {
		t.Fatal("owner requires at least seven pairs")
	}
}

func TestPairedMedianBudgetStatistic(t *testing.T) {
	off := []int64{100, 100, 100, 100, 100, 800, 800}
	on := []int64{99, 99, 99, 199, 199, 800, 800}
	pairedMedian, minimum, maximum := pairedStats(off, on)
	if pairedMedian != 0 || math.Abs(minimum+0.01) > 1e-12 || math.Abs(maximum-0.99) > 1e-12 {
		t.Fatalf("paired statistics=%g/%g/%g", pairedMedian, minimum, maximum)
	}
	if float64(median(on)-median(off))/float64(median(off)) < 0.02 {
		t.Fatal("fixture must distinguish paired median from the ratio of medians")
	}
}

// Synthetic serial tests validate the gate logic, not hardware overhead.
func TestOverheadAssertionUsesOnlyPairedMedianBudget(t *testing.T) {
	spec, err := os.ReadFile("../../../tools/gate/specs/live-observe.spec")
	if err != nil {
		t.Fatal(err)
	}
	start := "vgate_assert overhead python <<'PY'\n"
	_, script, ok := strings.Cut(string(spec), start)
	if !ok {
		t.Fatal("overhead assertion missing")
	}
	script, _, ok = strings.Cut(script, "\nPY\n")
	if !ok {
		t.Fatal("overhead assertion terminator missing")
	}
	tests := []struct {
		name     string
		on       int64
		outlier  bool
		grouped  bool
		mixed    bool
		wantPass bool
	}{
		{"median-below", 100500000, false, false, false, true},
		{"median-at-boundary", 108000000, false, false, false, false},
		{"spin-budget-red", 110000000, false, false, false, false},
		{"noise-straddles-budget", 100500000, true, false, false, true},
		{"paired-not-ratio-of-medians", 0, false, false, true, true},
		{"old-grouped-order", 100500000, false, true, false, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			var serial strings.Builder
			off, on := make([]int64, 7), make([]int64, 7)
			for i := range off {
				off[i], on[i] = 100000000, test.on
			}
			if test.outlier {
				on[6] = 103000000
			}
			if test.mixed {
				off = []int64{100000000, 100000000, 100000000, 100000000, 100000000, 800000000, 800000000}
				on = []int64{99000000, 99000000, 99000000, 199000000, 199000000, 800000000, 800000000}
			}
			write := func(mode string, pair int) {
				ns := off[pair-1]
				if mode == "on" {
					ns = on[pair-1]
				}
				fmt.Fprintf(&serial, "prof: work mode=%s run=%d ns=%d checksum=1234\n", mode, pair, ns)
			}
			if test.grouped {
				for _, mode := range []string{"off", "on"} {
					for pair := 1; pair <= 7; pair++ {
						write(mode, pair)
					}
				}
			} else {
				for pair := 1; pair <= 7; pair++ {
					write("off", pair)
					write("on", pair)
				}
			}
			pairedMedian, pairedMin, pairedMax := pairedStats(off, on)
			offMin, offMax := bounds(off)
			onMin, onMax := bounds(on)
			fmt.Fprintf(&serial, "prof: samples=700 dropped=0 off_median_ns=%d on_median_ns=%d overhead_pct=%.6f\n",
				median(off), median(on), 100*pairedMedian)
			fmt.Fprintf(&serial, "prof: spread off_min_ns=%d off_max_ns=%d on_min_ns=%d on_max_ns=%d pairs=7\n", offMin, offMax, onMin, onMax)
			fmt.Fprintf(&serial, "prof: measurement_noise paired_min_pct=%.6f paired_max_pct=%.6f\n", 100*pairedMin, 100*pairedMax)
			for core := 0; core <= 1; core++ {
				fmt.Fprintf(&serial, "prof: timer core=%d irq=1000 poll=0 elapsed_cntpct=240000000 freq=24000000 physical_ticks=10\n", core)
			}
			path := filepath.Join(t.TempDir(), "synthetic-serial.log")
			if err := os.WriteFile(path, []byte(serial.String()), 0600); err != nil {
				t.Fatal(err)
			}
			cmd := exec.Command("python3", "-c", script)
			cmd.Env = append(os.Environ(), "VG_SER="+path)
			out, err := cmd.CombinedOutput()
			if (err == nil) != test.wantPass {
				t.Fatalf("pass=%v, want %v: %v\n%s", err == nil, test.wantPass, err, out)
			}
			if test.outlier && !strings.Contains(string(out), "measurement_noise") {
				t.Fatalf("range not labeled measurement noise:\n%s", out)
			}
		})
	}
}
