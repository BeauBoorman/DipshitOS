// engine.go — GOASSIST's model session (M140b, #2785): the lazy half of
// the windowed app. The first send opens the process's one compute
// session and streams a VIW through staging into sealed weight buffers —
// the resident-app shape, one load for the app's life. The stub persona
// (SynthStub) needs no weights; the default persona is the staged model,
// and its absence is a named refusal, never a fabricated answer.
package main

import (
	"bytes"
	"errors"
	"io"
	"strconv"
	"strings"

	"virelai/gpu3d"
	"virelai/infer"
)

const (
	// modelPath is the staged owner-approved VIW — the same artifact and
	// staging seam GOINFER uses, so one operator install serves both.
	modelPath = "/host/GOINFER/SMOLLM2.VIW"
	// stageBytes bounds the load's read chunk (the kernel's 4 MiB window
	// is the limit; a WRITE stages finer itself).
	stageBytes = 1 << 20
	// maxNew bounds one answer inside seq_cap.
	maxNew = 64

	probeMaxNew = 8
	probePrompt = "goassist probe: answer with a token"
)

var (
	errWeightsAbsent = errors.New("weights absent")
	errCancelled     = errors.New("cancelled")
)

// The ChatML markers, assembled so the tokenizer's literal special strings
// never sit inside this file's own markup.
var (
	chatStart = "<" + "|im_start|>"
	chatEnd   = "<" + "|im_end|>"
	chatSys   = chatStart + "system\nYou are a helpful assistant." +
		chatEnd + "\n"
)

// engine owns the compute session and loaded model for the app's life.
// stub selects SynthStub instead of the staged VIW.
type engine struct {
	stub  bool
	dev   infer.Dev
	model *infer.Model
}

// ensure performs the one-time open + load. The weights check precedes
// the session open so an absent file never spends the device.
func (e *engine) ensure(h host) error {
	if e.model != nil {
		return nil
	}
	var src io.ReadCloser
	if e.stub {
		src = io.NopCloser(bytes.NewReader(infer.SynthStub()))
	} else {
		if !h.FileExists(modelPath) {
			return errWeightsAbsent
		}
		f, err := h.OpenRead(modelPath)
		if err != nil {
			return err
		}
		src = f
	}
	defer src.Close()
	s, err := h.OpenComp()
	if err != nil {
		return err
	}
	m, err := infer.Load(src, s, stageBytes)
	if err != nil {
		_ = s.Close()
		return err
	}
	e.dev, e.model = s, m
	return nil
}

// prompt encodes the conversation for the model: the system framing plus
// each turn, dropping the oldest turns until the encoding leaves maxNew
// tokens of seq_cap headroom. The transcript itself never loses them —
// only the window the model sees shrinks.
func (e *engine) prompt(c *conversation) []int {
	tok := e.model.Tokenizer()
	cap4 := e.model.Header().SeqCap - maxNew
	var sb strings.Builder
	turns := c.turns
	for {
		sb.Reset()
		sb.WriteString(chatSys)
		for _, t := range turns {
			sb.WriteString(chatStart + t.role + "\n" + t.text + chatEnd + "\n")
		}
		sb.WriteString(chatStart + "assistant\n")
		ids := tok.Encode(sb.String())
		if len(ids) <= cap4 || len(turns) <= 1 {
			return ids
		}
		turns = turns[1:]
	}
}

// generate streams one answer: cb sees each id as produced (its non-nil
// return aborts the decode, which Generate propagates with the ids so
// far). The returned string is the full decode of whatever ids were made.
func (e *engine) generate(prompt []int, cb func(id int) error) (string, []int, error) {
	ids, err := e.model.Generate(prompt, maxNew, cb)
	return e.model.Tokenizer().Decode(ids), ids, err
}

// close releases the model's weight buffers and the session.
func (e *engine) close() {
	if e.model != nil {
		e.model.Close()
		e.model = nil
	}
	if e.dev != nil {
		_ = e.dev.Close()
		e.dev = nil
	}
}

// errName maps an error to a stable console token (the goinfer shape).
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
	case errors.Is(err, errCancelled):
		return "cancelled"
	}
	return "error"
}

func is(n int) string { return strconv.Itoa(n) }

// idlist renders generated ids compactly for the console.
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

// jProbe is the leg-1 journey: one full generate under the seat proving
// the compute device is shareable. A device-less boot names itself
// unsupported; every refusal is named.
func jProbe(h host) error {
	s, err := h.OpenComp()
	if errors.Is(err, gpu3d.ErrComputeNoDevice) {
		return gpu3d.ErrUnsupported
	}
	if err != nil {
		h.ConsoleLine("goassist: probe refused " + errName(err))
		return err
	}
	defer s.Close()
	m, err := infer.Load(bytes.NewReader(infer.SynthStub()), s, stageBytes)
	if err != nil {
		h.ConsoleLine("goassist: probe refused " + errName(err))
		return err
	}
	defer m.Close()
	ids, err := m.Generate(m.Tokenizer().Encode(probePrompt), probeMaxNew, nil)
	if err != nil {
		h.ConsoleLine("goassist: probe refused " + errName(err))
		return err
	}
	st, _ := s.Stats()
	h.ConsoleLine("goassist: probe ok toks=" + is(len(ids)) +
		" ids=" + idlist(ids) + " submits=" + is(int(st.Submits)))
	return nil
}
