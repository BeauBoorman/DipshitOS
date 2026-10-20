// Command goassist is GOASSIST.ELF — the M140b (#2785) chat app over the
// M140a virelai/infer engine. A bare launch (or `model`) opens the
// windowed view backed by the staged model; `stub` opens the same view
// on the deterministic PRNG-weights model so the gate can pin the stream
// without weights; `probe` is the leg-1 console journey — one generate
// call proving the compute device shares under the seat.
//
// Conversations are files under <dataroot>/ASSIST/, published crash-safe
// through WriteFileSafe; save_state carries the open conversation's name
// and scroll row so a snapshot/restore re-opens the transcript mid-thread.
//
// Every marker is printed only AFTER its syscall returned, so the
// go-assist gate's asserts can only pass if the app actually ran.
package main

import (
	"errors"

	"virelai/gpu3d"
	"virelai/vi"
)

var errUsage = errors.New("usage")

// run is the console journey dispatcher (the goinfer shape): one journey
// per invocation, every path ends on the `goassist: done` anchor.
func run(h host, args []string) error {
	var err error
	switch args[0] {
	case "probe":
		err = jProbe(h)
	default:
		err = errUsage
	}
	if errors.Is(err, gpu3d.ErrUnsupported) {
		h.ConsoleLine(markerUnsup)
		return nil
	}
	return err
}

// dispatch picks the presentation: a bare launch and `model` are the
// windowed view on the staged weights, `stub` the same view on SynthStub,
// `probe` the console journey. On a window-less boot the bare launch
// names the journeys and exits nonzero — the honest headless answer.
func dispatch(h host, args []string) int {
	journey := ""
	if len(args) > 0 {
		journey = args[0]
	}
	switch journey {
	case "", "model":
		return runView(h, false)
	case "stub":
		return runView(h, true)
	case "probe":
		defer viewConsole(markerDone)
		if err := run(h, args); err != nil {
			viewConsole(markerError + errName(err))
			return 1
		}
		viewConsole("goassist OK")
		return 0
	}
	viewConsole("goassist: usage GOASSIST.ELF [model|stub|probe]")
	return 2
}

func main() {
	var args []string
	if a := vi.Args(); len(a) > 1 {
		args = a[1:]
	}
	vi.Exit(dispatch(guestHost{}, args))
}
