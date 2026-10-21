// Package teatty is the Bubble Tea v2 counterpart of gsport/tty (#2957):
// it claims the calling process's controlling terminal for a
// GOTABWM-hosted window, binds it through sys_tty_attach's window
// front-end (ADR 0020 Amendment A), and hands the v2 Charm overlays the
// host state they cannot compute — "is this fd the bound /dev/tty" and
// "how many CELLS does the kernel grid hold now".
//
// Design — the gsport/tty (M95c #2011) shape kept, re-proven for tea v2:
//
//   - Backend: the seat-bound window tty, not the kernel console. Only a
//     hosted window appears in the seat's window list.
//   - Event ownership: once a Program runs, the v2 overlay's
//     listenForResize goroutine owns the process's ADR 0009 queue.
//     teatty drains nothing after hand-off; NoteResize/NotifyClose only
//     record what that goroutine observed, so term.GetSize and the app's
//     own teardown answer from the same event stream.
//   - Resize: cells, never pixels — the tabapp.CellGrid formulas
//     (clamp(w/cellW, 8, 80) / (h-16)/cellH), with the cell re-read per
//     event because a font zoom moves the rung (M80i).
//   - Shutdown: WIN_CLOSE reaches the model as tea.QuitMsg; ^C/^D are
//     ordinary decoded keys the model maps itself — v2 needs no sig
//     seam, so the v1 Controller is deliberately absent.
//
// On the host every syscall returns -ENOSYS, so Open reports the refusal
// and the package stays plain unit-test surface (the os.Pipe File shape
// and the cell math).
package teatty

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	"virelai/tabapp"
	"virelai/vi"
)

// devTTY is the kernel's controlling-terminal path (file_table.is_tty_path).
const devTTY = "/dev/tty"

// Open's stage failures, so the caller can keep its old per-stage exit
// vocabulary instead of string-matching.
var (
	ErrWindow = errors.New("teatty: win_open refused (no seat on this platform)")
	ErrTTY    = errors.New("teatty: cannot open " + devTTY)
	ErrAttach = errors.New("teatty: cannot bind " + devTTY + " to the window")
)

// state is process-scoped: one controlling terminal, one bound window.
var (
	mu     sync.Mutex
	tab    *tabapp.TabApp
	ttyFd  = -1
	in     *File
	out    *File
	cols   = 0
	rows   = 0
	closed = false // the event goroutine saw WIN_CLOSE
)

// The kernel's hid_to_bytes encodes Return (usage 0x28) as LF, the
// console line editor's convention; a terminal front-end feeds Bubble
// Tea, whose decoder (ultraviolet decoder.go:1140-1144) names only CR
// `enter`. Read therefore maps 0x0a -> 0x0d — the one deliberate
// normalization — everywhere EXCEPT inside a DECSET-2004 bracketed
// paste, where a newline is pasted content, not a key.
const (
	pasteBegin = "\x1b[200~"
	pasteEnd   = "\x1b[201~"
	markerLen  = 6
)

// File is the term.File Bubble Tea v2 reads for input and writes for
// output. The kernel's tty read is non-blocking (0 = empty queue), so
// Read paces itself — the tea readLoop simply blocks here until the WM's
// key pump delivers bytes. out holds normalized bytes not yet handed to
// the caller; tail holds a trailing partial paste marker while its end
// is undecided.
type File struct {
	// f is the host-test handle only (os.Pipe). On virelai the File
	// carries the raw kernel fd and does I/O through vi slots: the
	// fork's os.File layer treats an O_RDWR handle as a positional file
	// whose bookkeeping fights the tty queue — the raw slot call is the
	// honest primitive (the same lesson gsport/tty recorded).
	fd      int
	f       *os.File
	out     []byte
	tail    []byte
	inPaste bool
	scratch [512]byte
}

// readRaw is one device read: the queue drain on virelai, the pipe read
// on host.
func (f *File) readRaw(buf []byte) (int, error) {
	if f.f != nil {
		return f.f.Read(buf)
	}
	n, r := vi.FileRead(uint32(f.fd), buf)
	if r < 0 {
		return 0, fmt.Errorf("teatty: read %s: errno %d", devTTY, -r)
	}
	return n, nil
}

// writeRaw is one device write: the raw out-ring append on virelai, the
// pipe write on host.
func (f *File) writeRaw(p []byte) (int, error) {
	if f.f != nil {
		return f.f.Write(p)
	}
	n, r := vi.FileWriteAll(uint32(f.fd), p)
	if r < 0 {
		return n, fmt.Errorf("teatty: write %s: errno %d", devTTY, -r)
	}
	return n, nil
}

// Read fills p from the terminal input queue, pacing empty polls with
// vi.Sleep(1) instead of returning 0 — a 0 return is not EOF on a
// level-triggered tty queue, and propagating it would end Bubble Tea's
// readLoop on the first empty poll.
func (f *File) Read(p []byte) (int, error) {
	for {
		if len(f.out) > 0 {
			n := copy(p, f.out)
			f.out = f.out[n:]
			return n, nil
		}
		n, err := f.readRaw(f.scratch[:])
		if errors.Is(err, io.EOF) {
			err = nil
		}
		src := make([]byte, 0, len(f.tail)+n)
		src = append(src, f.tail...)
		src = append(src, f.scratch[:n]...)
		out, tail, paste := translateEnter(src, f.inPaste)
		f.inPaste = paste
		f.tail = append(f.tail[:0], tail...)
		f.out = append(f.out, out...)
		if len(f.out) > 0 {
			continue
		}
		if err != nil {
			// Flush a truncated marker tail so every read byte reaches
			// the caller; the error surfaces on the next Read.
			f.out = append(f.out, f.tail...)
			f.tail = f.tail[:0]
			if len(f.out) > 0 {
				continue
			}
			return 0, err
		}
		if n == 0 {
			vi.Sleep(1)
		}
	}
}

// translateEnter applies the LF -> CR mapping over src; bytes inside a
// bracketed paste pass through verbatim. A trailing prefix of the
// expected marker (up to markerLen-1 bytes) is held back as tail for the
// next call, so a marker split across kernel reads is still recognized.
// pasteOut is the paste state after consuming src.
func translateEnter(src []byte, paste bool) (out, tail []byte, pasteOut bool) {
	for i := 0; i < len(src); {
		marker := []byte(pasteBegin)
		if paste {
			marker = []byte(pasteEnd)
		}
		rel := bytes.Index(src[i:], marker)
		end := len(src)
		if rel >= 0 {
			end = i + rel
		} else {
			for k := markerLen - 1; k > 0; k-- {
				if len(src)-i >= k && bytes.Equal(src[len(src)-k:], marker[:k]) {
					end = len(src) - k
					break
				}
			}
		}
		if paste {
			out = append(out, src[i:end]...)
		} else {
			for _, c := range src[i:end] {
				if c == '\n' {
					c = '\r'
				}
				out = append(out, c)
			}
		}
		if rel < 0 {
			return out, append(tail, src[end:]...), paste
		}
		// The marker itself passes through — the decoder owns the bracket.
		out = append(out, marker...)
		i = end + markerLen
		paste = !paste
	}
	return out, nil, paste
}

// Write appends to the terminal output ring through the raw slot.
func (f *File) Write(p []byte) (int, error) {
	return f.writeRaw(p)
}

// Close is a no-op: the terminal's lifecycle belongs to Close.
func (f *File) Close() error { return nil }

// Fd is the kernel file handle — the term.File contract.
func (f *File) Fd() uintptr {
	if f.f != nil {
		return f.f.Fd()
	}
	return uintptr(f.fd)
}

// Open hosts the app's window under the seat and binds the controlling
// terminal to it: tabapp.Init (win_open + declare_fullscreen), open
// /dev/tty (slot 23), then sys_tty_attach(TtyWindow, win) (slot 67). The
// kernel orders it the same way every bound-tty app does: the attach
// fails EINVAL unless /dev/tty is already open. The last-known cell size
// seeds at the declared rect's grid; the seat's host-canvas grant
// arrives as the first WIN_RESIZE the Program's event goroutine
// consumes. Input and output share the one kernel handle — .tty reads
// drain the input ring, .tty writes append to the output ring — on
// separate File wrappers so the caller's io.Reader/io.Writer seams stay
// distinct. On the host the open fails inside tabapp.Init with ENOSYS.
func Open(cfg tabapp.Config) (input *File, output *File, err error) {
	mu.Lock()
	defer mu.Unlock()
	if in != nil {
		return in, out, nil
	}
	ta := tabapp.Init(cfg)
	if ta == nil {
		return nil, nil, ErrWindow
	}
	h, r := vi.FileOpen(devTTY, vi.ModeRead|vi.ModeWrite)
	if r < 0 {
		ta.Close()
		return nil, nil, fmt.Errorf("%w: errno %d", ErrTTY, -r)
	}
	if r := vi.TtyAttachWindow(ta.Win); r != 0 {
		vi.FileClose(uint32(h))
		ta.Close()
		return nil, nil, fmt.Errorf("%w: errno %d", ErrAttach, -r)
	}
	tab, ttyFd = ta, int(h)
	in = &File{fd: ttyFd}
	out = &File{fd: ttyFd}
	cw, ch := vi.TerminalCell()
	cols, rows = tabapp.CellGrid(ta.W, ta.H, cw, ch)
	closed = false
	return in, out, nil
}

// Bound reports whether the controlling terminal is claimed (post-Open).
func Bound() bool {
	mu.Lock()
	defer mu.Unlock()
	return ttyFd >= 0
}

// IsBoundFd reports whether fd is the bound controlling terminal — the
// term.IsTerminal answer Bubble Tea's initInput gate needs.
func IsBoundFd(fd uintptr) bool {
	mu.Lock()
	defer mu.Unlock()
	return ttyFd >= 0 && uintptr(ttyFd) == fd
}

// Size is the last-known terminal size in CELLS — term.GetSize's answer.
// Seeded at Open and refreshed by every WIN_RESIZE the Program's event
// goroutine consumes, so checkResize stays honest without an ioctl.
func Size() (w, h int) {
	mu.Lock()
	defer mu.Unlock()
	return cols, rows
}

// NoteResize applies a WIN_RESIZE pixel payload: re-reads the active
// cell rung (a font zoom moves it — M80i), recomputes the kernel's cell
// formulas, stores the answer for Size, and returns the new cells for
// the WindowSizeMsg.
func NoteResize(wpx, hpx uint32) (int, int) {
	cw, ch := vi.TerminalCell()
	return noteResize(wpx, hpx, cw, ch)
}

// noteResize is NoteResize with the rung explicit, so host tests can pin
// the cell math at every zoom rung without faking SETTINGS.TXT.
func noteResize(wpx, hpx, cw, ch uint32) (int, int) {
	mu.Lock()
	defer mu.Unlock()
	cols, rows = tabapp.CellGrid(wpx, hpx, cw, ch)
	return cols, rows
}

// NotifyClose is the WIN_CLOSE half of the event goroutine: the window's
// close gesture is already on its way to the model as tea.QuitMsg —
// this records it so Closed reports the terminal gone.
func NotifyClose() {
	mu.Lock()
	closed = true
	mu.Unlock()
}

// Closed reports whether a WIN_CLOSE was observed (post-notify).
func Closed() bool {
	mu.Lock()
	defer mu.Unlock()
	return closed
}

// WindowID is the hosted window's id (-1 before Open), for markers.
func WindowID() int {
	mu.Lock()
	defer mu.Unlock()
	if tab == nil {
		return -1
	}
	return tab.Win
}

// Close detaches the controlling terminal (slot 67 selector 0), closes
// the /dev/tty handle and the window. Idempotent; the app defers it.
func Close() {
	mu.Lock()
	defer mu.Unlock()
	if ttyFd >= 0 {
		_ = vi.TtyAttach(vi.TtyDetach)
		vi.FileClose(uint32(ttyFd))
		ttyFd = -1
		in, out = nil, nil
	}
	if tab != nil {
		tab.Close()
		tab = nil
	}
}
