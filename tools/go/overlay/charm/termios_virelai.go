//go:build virelai

package tea

import (
	"fmt"

	"github.com/charmbracelet/x/term"
)

// The unix shape minus termios: the guest's tty is the kernel's bound
// /dev/tty behind a hosted window, so "is a terminal" is teatty's
// bound-fd answer (through the staged x/term) and MakeRaw is an honest
// no-op — there is no line discipline to enter or restore.
// ttyInput/ttyOutput set as usual so checkResize and the renderer see a
// real terminal.
func (p *Program) initInput() (err error) {
	// Check if input is a terminal
	if f, ok := p.input.(term.File); ok && term.IsTerminal(f.Fd()) {
		p.ttyInput = f
		p.previousTtyInputState, err = term.MakeRaw(p.ttyInput.Fd())
		if err != nil {
			return fmt.Errorf("error entering raw mode: %w", err)
		}
	}

	if f, ok := p.output.(term.File); ok && term.IsTerminal(f.Fd()) {
		p.ttyOutput = f
	}

	return nil
}

func (*Program) checkOptimizedMovements(*term.State) {}

// The guest has no SIGTSTP and no process-group signal to suspend on;
// suspension is refused by absence, as on Windows.
const suspendSupported = false

func suspendProcess() {}
