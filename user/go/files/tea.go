//go:build virelai || fileman

// The Bubble Tea face of the M74a file manager: a real tea.Model whose
// Update takes HID-derived key messages (decoded from the bound /dev/tty by
// keys.Decode) and MouseClickMsg values (the kernel's ?1006 SGR cell
// coordinates, 1-based, passed through untouched), and whose View emits the
// ANSI frame into that bound tty. Like charmhello/pulse, Bubble Tea's host
// Program loop never runs here — main owns the read loop.
package main

import (
	tea "charm.land/bubbletea/v2"

	"virelai/rss/keys"
)

// Init is intentionally command-free: Virelai feeds key bytes from main.
func (model) Init() tea.Cmd { return nil }

// Update consumes one Bubble Tea message against a copy of the model.
func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyPressMsg:
		m.handleKey(fromTea(msg))
	case tea.MouseClickMsg:
		// msg.X/Y are the kernel's SGR cell coords (1-based over the
		// client area) — handleClick documents and consumes that space.
		m.handleClick(msg.X, msg.Y)
	}
	return m, nil
}

// View renders the frame as Bubble Tea's ANSI View for the bound tty.
func (m model) View() tea.View { return tea.NewView(m.render()) }

// toTea maps a decoded tty key onto the Bubble Tea key message Update
// consumes (the rss/ui shape: runes carry Text+Code, specials carry Code).
func toTea(ev keys.Event) tea.KeyPressMsg {
	switch ev.Key {
	case keys.KeyRune:
		return tea.KeyPressMsg(tea.Key{Text: string(ev.Rune), Code: ev.Rune})
	case keys.KeyUp:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyUp})
	case keys.KeyDown:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyDown})
	case keys.KeyLeft:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyLeft})
	case keys.KeyRight:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyRight})
	case keys.KeyEnter:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEnter})
	case keys.KeyEsc:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEscape})
	case keys.KeyBackspace:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyBackspace})
	case keys.KeyHome:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyHome})
	case keys.KeyEnd:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyEnd})
	case keys.KeyPageUp:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyPgUp})
	case keys.KeyPageDown:
		return tea.KeyPressMsg(tea.Key{Code: tea.KeyPgDown})
	case keys.KeyTab:
		return tea.KeyPressMsg(tea.Key{Code: '\t'})
	case keys.KeyCtrlZ:
		return tea.KeyPressMsg(tea.Key{Code: 0x1a})
	default:
		return tea.KeyPressMsg(tea.Key{Code: 3}) // Ctrl-C
	}
}

// fromTea is the inverse: a Bubble Tea key press back to the pure keys.Event
// the state machine switches on.
func fromTea(k tea.KeyPressMsg) keys.Event {
	switch k.Code {
	case tea.KeyUp:
		return keys.Event{Key: keys.KeyUp}
	case tea.KeyDown:
		return keys.Event{Key: keys.KeyDown}
	case tea.KeyLeft:
		return keys.Event{Key: keys.KeyLeft}
	case tea.KeyRight:
		return keys.Event{Key: keys.KeyRight}
	case tea.KeyEnter:
		return keys.Event{Key: keys.KeyEnter}
	case tea.KeyEscape:
		return keys.Event{Key: keys.KeyEsc}
	case tea.KeyBackspace:
		return keys.Event{Key: keys.KeyBackspace}
	case tea.KeyHome:
		return keys.Event{Key: keys.KeyHome}
	case tea.KeyEnd:
		return keys.Event{Key: keys.KeyEnd}
	case tea.KeyPgUp:
		return keys.Event{Key: keys.KeyPageUp}
	case tea.KeyPgDown:
		return keys.Event{Key: keys.KeyPageDown}
	case '\t':
		return keys.Event{Key: keys.KeyTab}
	case 3:
		return keys.Event{Key: keys.KeyCtrlC}
	case 0x1a:
		return keys.Event{Key: keys.KeyCtrlZ}
	}
	if k.Text != "" {
		r := []rune(k.Text)
		return keys.Event{Key: keys.KeyRune, Rune: r[0]}
	}
	if k.Code >= 0x20 {
		return keys.Event{Key: keys.KeyRune, Rune: k.Code}
	}
	return keys.Event{Key: keys.KeyNone}
}
