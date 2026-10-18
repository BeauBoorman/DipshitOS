// The profiler-only fixed-work fixture uses the same integer work in every
// run. Timing excludes ARM, reads, sleeps and serial output. GOMAXPROCS=1
// keeps the worker count unchanged between off and on measurements.
package main

import (
	"fmt"
	"runtime"
	"sort"

	"virelai/vi"
)

var sink uint64

//go:noinline
func fixedWork(seed uint64) uint64 {
	for i := uint64(0); i < 80_000_000; i++ {
		seed ^= seed << 13
		seed ^= seed >> 7
		seed ^= seed << 17
	}
	return seed
}

func selfPID() (uint64, error) {
	var rows [16]vi.ProcRow
	n, raw := vi.Procs(rows[:])
	if raw < 0 {
		return 0, fmt.Errorf("process snapshot %d", raw)
	}
	for _, row := range rows[:n] {
		if row.Name() == "PROFFIX.ELF" && row.State == vi.ProcRunning {
			return row.PID, nil
		}
	}
	return 0, fmt.Errorf("no fixture pid")
}

func median(values []int64) int64 {
	copy_ := append([]int64(nil), values...)
	sort.Slice(copy_, func(i, j int) bool { return copy_[i] < copy_[j] })
	return copy_[len(copy_)/2]
}

const measurementPairs = 7

func bounds(values []int64) (int64, int64) {
	minimum, maximum := values[0], values[0]
	for _, value := range values[1:] {
		if value < minimum {
			minimum = value
		}
		if value > maximum {
			maximum = value
		}
	}
	return minimum, maximum
}

// Pair ratios are the budget statistic. Their extrema describe measurement
// noise, not additional acceptance bounds.
func pairedStats(off, on []int64) (float64, float64, float64) {
	ratios := make([]float64, len(off))
	for i, baseline := range off {
		ratios[i] = float64(on[i]-baseline) / float64(baseline)
	}
	sort.Float64s(ratios)
	return ratios[len(ratios)/2], ratios[0], ratios[len(ratios)-1]
}

func run() error {
	runtime.GOMAXPROCS(1)
	pid, err := selfPID()
	if err != nil {
		return err
	}
	if args := vi.Args(); len(args) == 2 && args[1] == "--timer" {
		token, err := vi.ProfileStart([]uint64{pid})
		if err != nil {
			return err
		}
		start := vi.Nanos()
		vi.Sleep(12)
		if err := vi.ProfileStop(token); err != nil {
			return err
		}
		if vi.Nanos()-start < 10_000_000_000 {
			return fmt.Errorf("short timer probe")
		}
		fmt.Println("proffixture: timer done")
		fmt.Println("proffixture: done")
		return nil
	}
	if args := vi.Args(); len(args) == 2 && args[1] == "--samples" {
		token, err := vi.ProfileStart([]uint64{pid})
		if err != nil {
			return err
		}
		vi.Sleep(1)
		start := vi.Nanos()
		for i := 0; i < 3; i++ {
			sink = fixedWork(1)
		}
		elapsed := vi.Nanos() - start
		if err := vi.ProfileStop(token); err != nil {
			return err
		}
		var count, dropped uint64
		for batch := 0; batch < vi.ProfileRingRecords/16; batch++ {
			samples, loss, err := vi.ProfileSamples(token)
			if err != nil {
				return err
			}
			count += uint64(len(samples))
			dropped = loss
			if len(samples) < 16 {
				break
			}
		}
		fmt.Printf("prof: sample_probe samples=%d dropped=%d work_ns=%d\n", count, dropped, elapsed)
		fmt.Println("proffixture: done")
		return nil
	}
	// Populate runtime and code pages before either measurement arm.
	sink = fixedWork(1)
	var off, on [measurementPairs]int64
	var sampleCount uint64
	var dropped uint64
	// Reserve backing before either mode; the interleaved set pays no first
	// allocation cost and uses identical work in every on arm.
	token, err := vi.ProfileStart([]uint64{pid})
	if err != nil {
		return err
	}
	defer func() { _ = vi.ProfileStop(token) }()
	if err := vi.ProfileStop(token); err != nil {
		return err
	}
	measure := func(i int, values *[measurementPairs]int64, label string) error {
		vi.Sleep(1)
		start := vi.Nanos()
		value := fixedWork(1)
		elapsed := vi.Nanos() - start
		if value != sink || elapsed <= 0 {
			return fmt.Errorf("invalid fixed-work result or clock")
		}
		values[i] = elapsed
		fmt.Printf("prof: work mode=%s run=%d ns=%d checksum=%x\n", label, i+1, elapsed, value)
		return nil
	}
	for pair := 0; pair < measurementPairs; pair++ {
		if err := measure(pair, &off, "off"); err != nil {
			return err
		}
		token, err = vi.ProfileStart([]uint64{pid})
		if err != nil {
			return err
		}
		if err := measure(pair, &on, "on"); err != nil {
			return err
		}
		if err := vi.ProfileStop(token); err != nil {
			return err
		}
		var pairDropped uint64
		for batch := 0; batch < vi.ProfileRingRecords/16; batch++ {
			samples, loss, err := vi.ProfileSamples(token)
			if err != nil {
				return err
			}
			sampleCount += uint64(len(samples))
			pairDropped = loss
			if len(samples) < 16 {
				break
			}
		}
		dropped += pairDropped
	}
	// A full counter-timed delivery window on BOTH cores. Sleeping here
	// explicitly distinguishes hardware IRQ delivery from fixture polling.
	token, err = vi.ProfileStart([]uint64{pid})
	if err != nil {
		return err
	}
	start := vi.Nanos()
	vi.Sleep(12)
	if vi.Nanos()-start < 10_000_000_000 {
		return fmt.Errorf("short delivery window")
	}
	if err := vi.ProfileStop(token); err != nil {
		return err
	}
	offMedian, onMedian := median(off[:]), median(on[:])
	offMin, offMax := bounds(off[:])
	onMin, onMax := bounds(on[:])
	pairedMedian, pairedMin, pairedMax := pairedStats(off[:], on[:])
	fmt.Printf("prof: samples=%d dropped=%d off_median_ns=%d on_median_ns=%d overhead_pct=%.6f\n",
		sampleCount, dropped, offMedian, onMedian,
		100*pairedMedian)
	fmt.Printf("prof: spread off_min_ns=%d off_max_ns=%d on_min_ns=%d on_max_ns=%d pairs=%d\n",
		offMin, offMax, onMin, onMax, measurementPairs)
	fmt.Printf("prof: measurement_noise paired_min_pct=%.6f paired_max_pct=%.6f\n",
		100*pairedMin, 100*pairedMax)
	fmt.Println("proffixture: done")
	return nil
}

func main() {
	if err := run(); err != nil {
		fmt.Println("proffixture: FAIL", err)
		fmt.Println("proffixture: done")
		vi.Exit(1)
	}
}
