//go:build virelai || btmath

package main

import (
	"testing"

	tea "charm.land/bubbletea/v2"
)

// pressKey drives Update the way the guest's key decoder would: one scripted
// byte string becomes the KeyPressMsg a real terminal would produce for it.
func pressKey(m model, s string) model {
	var k tea.Key
	switch s {
	case "\r", "\n":
		k = tea.Key{Code: tea.KeyEnter}
	case "\x7f", "\b":
		k = tea.Key{Code: tea.KeyBackspace}
	default:
		k = tea.Key{Code: []rune(s)[0], Text: s}
	}
	next, _ := m.Update(tea.KeyPressMsg(k))
	return next.(model)
}

func TestTextinputRefusesNonDigits(t *testing.T) {
	m := newModel(defaultSeed, defaultRounds)
	m = pressKey(m, "1")
	for _, bad := range []string{"x", "-", "+"} {
		m = pressKey(m, bad)
		if got := m.input.Value(); got != "1" {
			t.Fatalf("%q keystroke changed input to %q", bad, got)
		}
		if m.input.Err != nil {
			t.Fatalf("refused %q keystroke left Err set: %v", bad, m.input.Err)
		}
	}
}

func TestTextinputAcceptsDigitsAndBackspace(t *testing.T) {
	m := newModel(defaultSeed, defaultRounds)
	for _, k := range []string{"1", "2", "3", "\x7f"} {
		m = pressKey(m, k)
	}
	if got := m.input.Value(); got != "12" {
		t.Fatalf("digits+backspace produced %q, want \"12\"", got)
	}
}

func TestEnterSubmitsTheAnswer(t *testing.T) {
	m := newModel(defaultSeed, defaultRounds) // seed 7 round 1: 9 + 8 = ? -> 17
	for _, k := range []string{"1", "7"} {
		m = pressKey(m, k)
	}
	if m.answered {
		t.Fatal("model evaluated before Enter")
	}
	m = pressKey(m, "\r")
	if !m.answered || m.correct != 1 || m.score != 10 {
		t.Fatalf("Enter did not submit: answered=%v correct=%d score=%d",
			m.answered, m.correct, m.score)
	}
	if m.feedback != "Correct. +10 points" {
		t.Fatalf("unexpected feedback %q", m.feedback)
	}
}

// The default script is the gate's scripted session: the model must reach
// the same 65/3/2 the guest-side selftest and the host-side SESSION.TXT
// check pin down.
func TestDefaultScriptedKeysReachScore65(t *testing.T) {
	m := newModel(defaultSeed, defaultRounds)
	for _, k := range parseKeys(defaultKeys) {
		m = pressKey(m, k)
		if m.done {
			break
		}
	}
	if !m.done {
		t.Fatal("default script did not finish the session")
	}
	if m.score != 65 || m.correct != 3 || m.incorrect != 2 {
		t.Fatalf("scripted session: score=%d correct=%d wrong=%d, want 65/3/2",
			m.score, m.correct, m.incorrect)
	}
}
