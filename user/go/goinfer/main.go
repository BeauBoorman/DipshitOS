package main

// GOINFER — the M111c (issue #2410) guest LLM inference app on the M111b
// GPU compute path (ADR 0053). Every matmul and the vocab softmax ride
// sys_gpucomp; norms, RoPE, residuals and sampling stay on the CPU — the
// same split the ADR pins. Since M140a (#2784) the engine — VIW loader,
// tokenizer, forward pass, greedy decode — is virelai/infer; this file is
// the CLI over it.
//
// Journeys (the seat exec's argv):
//
//	(bare)          M122c (#2572): the windowed view — Stub/Model buttons
//	                and a log mirroring every goinfer: line, for the
//	                launcher's "LLM Infer" row. One compute session per
//	                process: a spent session says so, honestly.
//	stub            deterministic PRNG-weights model, K=5 runs — the
//	                live-gpu3d leg payload; needs no fetched weights
//	model [path]    the owner-approved real model from a VIW image on the
//	                share (default /host/GOINFER/SMOLLM2.VIW): one load,
//	                K=5 fixed-prompt decodes, licence receipt per run.
//	                Weights are staged off-image per the card's licence
//	                gate; absent bytes are a named failure, never a
//	                fabricated answer.
//
// Receipts land in /host/GOINFER/RECEIPT.TSV — the same evidence seam
// GPUTRIANGLE uses. On a device-less boot the app prints
// `goinfer: unsupported` and writes NO receipt.

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"virelai/gpu3d"
	"virelai/infer"
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
	modelK     = 5
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
func (a *app) openComp() (infer.Dev, error) {
	return a.h.OpenComp()
}

// runOnce is one full inference lifecycle on the journey's session:
// stream the VIW through staging into sealed weight buffers, generate
// greedily, free every buffer. The K=5 leg is five of these — a run is
// the whole pipeline, not a loop tick. (The session is per-journey, not
// per-run: OpenCompute maps a fixed-VA window that Close does not unmap
// — a process can open exactly one session, which is also the realistic
// resident-app pattern.)
func (a *app) runOnce(s infer.Dev, src io.Reader) (ids []int, st gpu3d.ComputeStatsBlock, m *infer.Model, err error) {
	m, err = infer.Load(src, s, stageBytes)
	if err != nil {
		return nil, st, nil, err
	}
	defer m.Close()
	prompt := stubPrompt
	maxNew := stubMaxNew
	if m.Header().Model.Seed == 0 {
		prompt = modelPrompt
		maxNew = modelMaxNew
	}
	ids, err = m.Generate(m.Tokenizer().Encode(prompt), maxNew, nil)
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
// model — each a fresh VIW load and greedy decode on the journey's one
// compute session — every answer pinned-identical by construction. A
// divergence would mean the device or the path is nondeterministic; the
// app says so instead of printing K=5.
func (a *app) jStub() error {
	s, err := a.openComp()
	if errors.Is(err, gpu3d.ErrComputeNoDevice) {
		return gpu3d.ErrUnsupported
	}
	if err != nil {
		return err
	}
	defer s.Close()
	img := infer.SynthStub()
	var first string
	var firstIds string
	var prev gpu3d.ComputeStatsBlock
	for k := 1; k <= stubK; k++ {
		ids, st, m, err := a.runOnce(s, bytes.NewReader(img))
		if err != nil {
			a.rec.row("stub", "run", is(k), errName(err))
			return fmt.Errorf("stub run %d: %w", k, err)
		}
		// Stats accumulate per session; the per-run count is the delta.
		delta := st.Submits - prev.Submits
		prev = st
		ans := m.Tokenizer().Decode(ids)
		a.rec.row("stub", "run", is(k), "ids="+idlist(ids),
			"submits="+is(int(delta)), "completed="+is(int(st.Completed)))
		a.h.ConsoleLine("goinfer: stub run k=" + is(k) +
			" ids=" + idlist(ids) + " answer=" + strconv.Quote(ans) +
			" submits=" + is(int(delta)))
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

// jModel runs the owner-approved real model from a staged VIW image: one
// stream-and-seal load — the file is hashed as it passes so the receipt
// carries the staged sha256 — then K=5 greedy decodes of the card's fixed
// prompt, each run emitting the licence receipt (licence, model, sha,
// resident size) the card demands. The file's absence is a named failure:
// the app never fabricates an answer for weights it was never given.
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
	s, err := a.openComp()
	if errors.Is(err, gpu3d.ErrComputeNoDevice) {
		return gpu3d.ErrUnsupported
	}
	if err != nil {
		return err
	}
	defer s.Close()

	sum := sha256.New()
	tr := io.TeeReader(src, sum)
	t0 := a.h.Nanos()
	m, err := infer.Load(tr, s, stageBytes)
	if err != nil {
		a.rec.row("model", "run", errName(err))
		return fmt.Errorf("model run: %w", err)
	}
	defer m.Close()
	tok := m.Tokenizer()
	sha := hex.EncodeToString(sum.Sum(nil))
	loadMs := (a.h.Nanos() - t0) / 1e6
	resident := a.h.SelfMemBytes()

	hdr := m.Header()
	rec := hdr.Model
	a.rec.row("model", "loaded", "params="+is(int(m.Params())),
		"vocab="+is(hdr.Vocab), "layers="+is(hdr.Layers),
		"load_ms="+is(int(loadMs)))
	a.h.ConsoleLine("goinfer: loaded params=" + is(int(m.Params())) +
		" vocab=" + is(hdr.Vocab) + " load_ms=" + is(int(loadMs)))
	a.h.ConsoleLine("goinfer: licence=" + rec.License +
		" model=" + rec.ID + " sha=" + sha +
		" resident=" + strconv.FormatUint(resident, 10))
	a.rec.row("model", "licence", "licence="+rec.License,
		"model="+rec.ID, "source="+rec.Source,
		"usha="+rec.UpstreamSHA256, "ssha="+sha,
		"resident="+strconv.FormatUint(resident, 10))

	prompt := tok.Encode(modelPrompt)
	var first string
	var firstIds string
	var prev gpu3d.ComputeStatsBlock
	for k := 1; k <= modelK; k++ {
		d0 := a.h.Nanos()
		ids, err := m.Generate(prompt, modelMaxNew, nil)
		if err != nil {
			a.rec.row("model", "run", is(k), errName(err))
			return fmt.Errorf("model run %d: %w", k, err)
		}
		ns := a.h.Nanos() - d0
		tokps := "0"
		if ns > 0 {
			tokps = strconv.FormatFloat(float64(len(ids))*1e9/float64(ns), 'f', 2, 64)
		}
		st, err := s.Stats()
		if err != nil {
			return err
		}
		delta := st.Submits - prev.Submits
		prev = st
		ans := tok.Decode(ids)
		a.rec.row("model", "run", is(k), "ids="+idlist(ids),
			"toks="+is(len(ids)), "tokps="+tokps,
			"submits="+is(int(delta)),
			"licence="+rec.License, "model="+rec.ID,
			"ssha="+sha, "resident="+strconv.FormatUint(resident, 10))
		a.h.ConsoleLine("goinfer: model run k=" + is(k) +
			" ids=" + idlist(ids) + " tokps=" + tokps)
		if k == 1 {
			first, firstIds = ans, idlist(ids)
		} else if ans != first {
			a.rec.row("model", "diverged", is(k))
			a.h.ConsoleLine("goinfer: model diverged k=" + is(k))
			return errors.New("model answer diverged")
		}
	}
	st, err := s.Stats()
	if err != nil {
		return err
	}
	a.rec.row("model", "consistent", "K="+is(modelK), "ids="+firstIds)
	a.rec.row("model", "answer", first, "ids="+firstIds,
		"submits="+is(int(st.Submits)), "completed="+is(int(st.Completed)))
	a.h.ConsoleLine("goinfer: model consistent K=" + is(modelK))
	a.h.ConsoleLine(`goinfer: model answer "` + first + `"`)
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
	// The journey-end marker every path emits — success, named refusal,
	// unsupported, usage — so a gate leg can sequence on one line without
	// knowing which outcome the journey took.
	defer h.ConsoleLine("goinfer: done")
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
		a.h.ConsoleLine("goinfer: error " + errName(err) + " (" + err.Error() + ")")
		return err
	}
	a.h.ConsoleLine("goinfer OK")
	return nil
}

// dispatch picks the presentation: a bare launch is a person clicking the
// catalog row — the windowed view, not a usage error on a console they
// cannot see (M122c). An argv names a journey.
func dispatch(args []string) int {
	if len(args) == 0 {
		return runView()
	}
	if err := run(guestHost{}, args); err != nil {
		return 1
	}
	return 0
}

func main() {
	var args []string
	if a := vi.Args(); len(a) > 1 {
		args = a[1:]
	}
	vi.Exit(dispatch(args))
}
