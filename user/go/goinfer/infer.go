package main

// The generate loop: prompt prefill then greedy decode. Greedy is not a
// limitation — it is the contract: the gate pins one answer, so the
// sampler is argmax (lowest id on ties), the same token on every run,
// every boot, K times in a row.

import (
	"errors"
)

// argmax picks the winning id — lowest index on exact ties so the pin is
// stable even when two ids land on the same probability.
func argmax(v []float32) int {
	best, bi := v[0], 0
	for i := 1; i < len(v); i++ {
		if v[i] > best {
			best, bi = v[i], i
		}
	}
	return bi
}

// generate runs prefill + greedy decode. prompt ids come from the model's
// tokenizer; maxNew bounds the answer inside seq_cap.
func (e *engine) generate(prompt []int, maxNew int) ([]int, error) {
	c := e.m.cfg
	if len(prompt) == 0 {
		return nil, errors.New("empty prompt")
	}
	if maxNew < 1 || len(prompt) > c.SeqCap {
		return nil, errors.New("prompt outside seq_cap")
	}
	pos := 0
	cur := prompt[0]
	var ids []int
	for {
		if err := e.step(cur, pos); err != nil {
			return nil, err
		}
		pos++
		if pos < len(prompt) {
			cur = prompt[pos]
			continue
		}
		// Every prompt token consumed: the last step's hidden state heads
		// for the vocab projection.
		if err := e.lmHead(); err != nil {
			return nil, err
		}
		nxt := argmax(e.logits)
		ids = append(ids, nxt)
		if nxt == c.EOS || len(ids) >= maxNew || pos >= c.SeqCap {
			break
		}
		cur = nxt
	}
	return ids, nil
}
