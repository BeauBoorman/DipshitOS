package main

// GOINFER — the M111c (issue #2410) guest LLM inference app on the M111b
// GPU compute path (ADR 0053). Every matmul and the vocab softmax ride
// sys_gpucomp; norms, RoPE, residuals and sampling stay on the CPU — the
// same split the ADR pins.
//
// Journeys (the seat exec's argv):
//
//	stub            deterministic PRNG-weights model, K=5 runs — the
//	                live-gpu3d leg payload; needs no fetched weights
//	model [path]    the owner-approved real model from a VIW image on the
//	                share (default /host/GOINFER/SMOLLM2.VIW). Weights are
//	                staged off-image per the card's licence gate; absent
//	                bytes are a named failure, never a fabricated answer.
//
// Receipts land in /host/GOINFER/RECEIPT.TSV — the same evidence seam
// GPUTRIANGLE uses. On a device-less boot the app prints
// `goinfer: unsupported` and writes NO receipt.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"virelai/gpu3d"
	"virelai/vi"
)

const (
	appName    = "GOINFER.ELF"
	receiptDir = "/host/GOINFER"
	receiptTSV = receiptDir + "/RECEIPT.TSV"
	modelPath  = receiptDir + "/SMOLLM2.VIW"

	// The card's fixed prompts — pinned because the gate pins the answer.
	stubPrompt  = "GOINFER stub check: the quick brown fox"
	stubMaxNew  = 16
	modelMaxNew = 64

	stubK      = 5
	stageBytes = 1 << 20 // load chunk; session.Write chunks finer anyway
)

// The ChatML markers, assembled so the tokenizer's literal special strings
// never sit inside this file's own markup.
var (
	chatStart = "<" + "|im_start|>"
	chatEnd   = "<" + "|im_end|>"
	// modelPrompt is the card's fixed prompt in the model's chat format.
	modelPrompt = chatStart + "system\n" +
		"You are a helpful AI assistant named SmolLM, trained by Hugging Face" +
		chatEnd + "\n" + chatStart + "user\n" +
		"What is the capital of France?" + chatEnd + "\n" +
		chatStart + "assistant\n"
)

// recorder is the TSV receipt writer (the gputriangle shape).
type recorder struct{ rows [][]string }

func (r *recorder) row(cells ...string) { r.rows = append(r.rows, cells) }

func (r *recorder) tsv() []byte {
	var sb strings.Builder
	for _, row := range r.rows {
		for i, c := range row {
			if i > 0 {
				sb.WriteByte('\t')
			}
			c = strings.ReplaceAll(c, "\t", " ")
			c = strings.ReplaceAll(c, "\n", " ")
			sb.WriteString(c)
		}
		sb.WriteByte('\n')
	}
	return []byte(sb.String())
}

// errName maps an error to a stable console/receipt token.
func errName(err error) string {
	switch {
	case errors.Is(err, gpu3d.ErrComputeNoDevice):
		return "nodevice"
	case errors.Is(err, gpu3d.ErrComputeInvalid):
		return "invalid"
	case errors.Is(err, gpu3d.ErrComputeBadHandle):
		return "badhandle"
	case errors.Is(err, gpu3d.ErrComputeExhausted):
		return "exhausted"
	case errors.Is(err, gpu3d.ErrComputeBusy):
		return "busy"
	case errors.Is(err, gpu3d.ErrComputeTimedOut):
		return "timeout"
	case errors.Is(err, gpu3d.ErrComputeLost):
		return "lost"
	case errors.Is(err, gpu3d.ErrComputeFault):
		return "fault"
	case errors.Is(err, gpu3d.ErrComputeDevice):
		return "device"
	case errors.Is(err, errWeightsAbsent):
		return "absent"
	}
	return "error"
}

func is(n int) string { return strconv.Itoa(n) }

// idlist renders generated ids compactly for the console/receipt.
func idlist(ids []int) string {
	var sb strings.Builder
	for i, id := range ids {
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(is(id))
	}
	return sb.String()
}

// app bundles the host seam and the receipt.
type app struct {
	h   host
	rec recorder
}

// openComp wraps the seam so every journey names the unsupported case the
// same way — ENXIO/ENOSYS is a device absence, not a failure.
func (a *app) openComp() (dev, error) {
	return a.h.OpenComp()
}

// runOnce is one full inference lifecycle: open the session, stream the
// VIW through staging into sealed weight buffers, generate greedily,
// close. The K=5 leg is five of these — a run is the whole pipeline, not
// a loop tick.
func (a *app) runOnce(src io.Reader) (ids []int, st gpu3d.ComputeStatsBlock, m *model, err error) {
	s, err := a.openComp()
	if err != nil {
		return nil, st, nil, err
	}
	defer s.Close()
	im, err := readVIWHead(src)
	if err != nil {
		return nil, st, nil, err
	}
	m, err = loadModel(im, src, s, stageBytes)
	if err != nil {
		return nil, st, nil, err
	}
	defer m.freeBuffers(s)
	eng, err := newEngine(s, m)
	if err != nil {
		return nil, st, nil, err
	}
	defer eng.free()
	tok, err := parseTokenizer(im.Tok)
	if err != nil {
		return nil, st, nil, err
	}
	m.tok = tok
	prompt := stubPrompt
	maxNew := stubMaxNew
	if im.Header.Model.Seed == 0 {
		prompt = modelPrompt
		maxNew = modelMaxNew
	}
	ids, err = eng.generate(tok.Encode(prompt), maxNew)
	if err != nil {
		return nil, st, nil, err
	}
	st, err = s.Stats()
	if err != nil {
		return nil, st, nil, err
	}
	return ids, st, m, nil
}

// jStub is the gate leg: K=5 complete runs of the deterministic stub
// model, each a fresh session, every answer pinned-identical by
// construction. A divergence would mean the device or the path is
// nondeterministic — the app says so instead of printing K=5.
func (a *app) jStub() error {
	var first string
	var firstIds string
	for k := 1; k <= stubK; k++ {
		img := synthStub()
		ids, st, m, err := a.runOnce(bytes.NewReader(img))
		if errors.Is(err, gpu3d.ErrComputeNoDevice) {
			return gpu3d.ErrUnsupported
		}
		if err != nil {
			a.rec.row("stub", "run", is(k), errName(err))
			return fmt.Errorf("stub run %d: %w", k, err)
		}
		ans := m.tok.Decode(ids)
		a.rec.row("stub", "run", is(k), "ids="+idlist(ids),
			"submits="+is(int(st.Submits)), "completed="+is(int(st.Completed)))
		a.h.ConsoleLine("goinfer: stub run k=" + is(k) +
			" ids=" + idlist(ids) + " answer=" + strconv.Quote(ans) +
			" submits=" + is(int(st.Submits)))
		if k == 1 {
			first, firstIds = ans, idlist(ids)
		} else if ans != first {
			a.rec.row("stub", "diverged", is(k))
			a.h.ConsoleLine("goinfer: stub diverged k=" + is(k))
			return errors.New("stub answer diverged")
		}
	}
	a.rec.row("stub", "consistent", "K="+is(stubK), "ids="+firstIds)
	a.h.ConsoleLine("goinfer: stub consistent K=" + is(stubK))
	a.h.ConsoleLine("goinfer: stub answer " + strconv.Quote(first))
	return a.writeReceipts()
}

// jModel runs the owner-approved real model from a staged VIW image. The
// file's absence is a named failure: the app never fabricates an answer
// for weights it was never given.
func (a *app) jModel(path string) error {
	if !a.h.FileExists(path) {
		a.rec.row("model", "absent", path)
		a.h.ConsoleLine("goinfer: weights absent")
		return errWeightsAbsent
	}
	src, err := a.h.OpenRead(path)
	if err != nil {
		return err
	}
	defer src.Close()
	ids, st, m, err := a.runOnce(src)
	if errors.Is(err, gpu3d.ErrComputeNoDevice) {
		return gpu3d.ErrUnsupported
	}
	if err != nil {
		a.rec.row("model", "run", errName(err))
		return fmt.Errorf("model run: %w", err)
	}
	ans := m.tok.Decode(ids)
	a.rec.row("model", "loaded", "params="+is(int(m.params)),
		"vocab="+is(m.cfg.Vocab), "layers="+is(m.cfg.Layers))
	a.rec.row("model", "answer", ans, "ids="+idlist(ids),
		"submits="+is(int(st.Submits)), "completed="+is(int(st.Completed)))
	a.h.ConsoleLine("goinfer: loaded params=" + is(int(m.params)) +
		" vocab=" + is(m.cfg.Vocab))
	a.h.ConsoleLine(`goinfer: model answer "` + ans + `"`)
	a.h.ConsoleLine("goinfer: stats submits=" + is(int(st.Submits)) +
		" completed=" + is(int(st.Completed)) +
		" refusals=" + is(int(st.Refusals)) +
		" timeouts=" + is(int(st.Timeouts)))
	return a.writeReceipts()
}

func (a *app) writeReceipts() error {
	if err := a.h.MkdirShare(receiptDir); err != nil {
		return err
	}
	return a.h.WriteShareFile(receiptTSV, a.rec.tsv())
}

var (
	errUsage         = errors.New("usage")
	errWeightsAbsent = errors.New("weights absent")
)

func run(h host, args []string) error {
	a := &app{h: h}
	a.rec.row("schema", "1")
	journey := ""
	if len(args) > 0 {
		journey = args[0]
	}
	a.rec.row("app", appName, journey)
	var err error
	switch journey {
	case "stub":
		err = a.jStub()
	case "model":
		path := modelPath
		if len(args) > 1 {
			path = args[1]
		}
		err = a.jModel(path)
	default:
		err = errUsage
	}
	if errors.Is(err, gpu3d.ErrUnsupported) {
		a.h.ConsoleLine("goinfer: unsupported")
		return nil
	}
	if err != nil {
		_ = a.writeReceipts()
		a.h.ConsoleLine("goinfer: error " + errName(err))
		return err
	}
	a.h.ConsoleLine("goinfer OK")
	return nil
}

func main() {
	var args []string
	if a := vi.Args(); len(a) > 1 {
		args = a[1:]
	}
	if err := run(guestHost{}, args); err != nil {
		vi.Exit(1)
	}
	vi.Exit(0)
}
