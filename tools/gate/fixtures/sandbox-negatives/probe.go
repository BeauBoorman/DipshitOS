// Sandbox-negative battery fixture (M116e, issue #2471): the
// boundary-word probe. One binary is staged under every corpus name —
// the GRANTS.TXT row (or its absence) is the experiment's controlled
// variable, the live-trust-grants same-bytes pattern.
//
// Each run prints one named refusal or landing line per attempted word
// (`negprobe: file|net ok|denied name=<image> rc=<errno>`), then a done
// marker and a clean exit: confined is a refusal, never a stuck app.
//
// Runtime-only like tools/go/hello.go — the gate builds it per run with
//
//	GO_BUILD_NAME=NEGPROBE bash tools/go/build-go.sh \
//	    tools/gate/fixtures/sandbox-negatives/probe.go
package main

import (
	"time"
	"virelai/vi"
	"virelai/vsys"
)

func errnoName(rc int64) string {
	switch -rc {
	case vi.ErrEACCES:
		return "EACCES"
	case vi.ErrENOENT:
		return "ENOENT"
	}
	return "errno" + vsys.Itoa64(-rc)
}

func main() {
	me := "?"
	if args := vi.Args(); len(args) > 0 {
		me = args[0]
	}
	// The `file` word: open a share file through the file ABI.
	if _, rc := vi.ReadFileAll("PROBE.TXT", 64); rc < 0 {
		vsys.Println("negprobe: file denied name=" + me + " rc=" + errnoName(rc))
	} else {
		vsys.Println("negprobe: file ok name=" + me)
	}
	// The `net` word: a socket open against the live responder.
	c, err := vi.DialTimeout("10.0.0.2", 8080, 5*time.Second)
	if err != nil {
		vsys.Println("negprobe: net denied name=" + me + " rc=" + err.Error())
	} else {
		vsys.Println("negprobe: net ok name=" + me)
		_ = c.Close()
	}
	vsys.Println("negprobe: done name=" + me)
	vsys.Exit(0)
}
