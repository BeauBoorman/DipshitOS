// presets.go — the optional prompt-preset list (#2920): a store-local
// PRESETS.TXT names up to presetMax system-prompt presets; a new
// conversation offers them, and the chosen one lands as the transcript's
// @@system turn so it survives save/restore with the conversation itself.
//
// The file shares the conversation codec's line grammar so it stays
// readable with `vf cat`:
//
//	GOASSIST-PRESETS v1
//	@@coder
//	You are a terse systems programmer. Answer in three sentences.
//	@@poet
//	Answer in rhyming couplets.
//
// A `@@`-line inside a prompt body is space-protected exactly like a turn
// body. Decode is strict in the codec's own style — bad magic, a missing
// name, a duplicate, a body before the first name, a bound overflow, or
// trailing garbage refuse the WHOLE file: a malformed preset list offers
// nothing rather than half a menu.
package main

import "strings"

const (
	// presetsName is the file inside the conversation store directory —
	// beside the .CHAT files, where a dropped edit lands with them.
	presetsName     = "PRESETS.TXT"
	presetMagic     = "GOASSIST-PRESETS v1"
	presetMax       = 8
	presetNameMax   = 24
	presetPromptMax = 1024
	presetFileMax   = 16 * 1024
)

// preset is one named system prompt.
type preset struct {
	name   string
	prompt string
}

// validPresetName bounds a marker line's name: non-empty, bounded, and
// edge-trimmed so `@@ name` is never silently a different name than `@@name`.
func validPresetName(n string) bool {
	return len(n) >= 1 && len(n) <= presetNameMax && n == strings.TrimSpace(n)
}

// decodePresets is the strict reader. ok=false means the file is refused
// wholesale; an absent file never reaches here (the caller treats a read
// error as "no presets", the common case).
func decodePresets(b []byte) ([]preset, bool) {
	if len(b) == 0 || len(b) > presetFileMax {
		return nil, false
	}
	s := string(b)
	if !strings.HasPrefix(s, presetMagic+"\n") {
		return nil, false
	}
	s = s[len(presetMagic)+1:]
	var out []preset
	var cur *preset
	seen := map[string]bool{}
	for _, ln := range strings.Split(s, "\n") {
		if strings.HasPrefix(ln, convMark) {
			name := ln[len(convMark):]
			if !validPresetName(name) || seen[name] || len(out) >= presetMax {
				return nil, false
			}
			seen[name] = true
			out = append(out, preset{name: name})
			cur = &out[len(out)-1]
			continue
		}
		if cur == nil {
			// Only the file's trailing newline is legal before the first
			// marker — same rule as the conversation codec.
			if ln != "" {
				return nil, false
			}
			continue
		}
		if strings.HasPrefix(ln, " "+convMark) {
			ln = ln[1:]
		}
		if cur.prompt != "" {
			cur.prompt += "\n"
		}
		cur.prompt += ln
		if len(cur.prompt) > presetPromptMax {
			return nil, false
		}
	}
	if cur != nil && strings.HasSuffix(cur.prompt, "\n") {
		cur.prompt = strings.TrimSuffix(cur.prompt, "\n")
	}
	for _, p := range out {
		if strings.TrimSpace(p.prompt) == "" {
			return nil, false
		}
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}

// loadPresets reads the store's PRESETS.TXT. refused distinguishes "the
// file exists but is malformed" (a named console refusal) from the common
// "no file" — which is simply no presets, no noise.
func loadPresets(h host, dir string) (list []preset, refused bool) {
	b, err := h.ReadFileAll(dir+"/"+presetsName, presetFileMax)
	if err != nil {
		return nil, false
	}
	p, ok := decodePresets(b)
	if !ok {
		return nil, true
	}
	return p, false
}
