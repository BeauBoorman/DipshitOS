// The M177b (#3143) accessibility outline: an appkit window describes
// itself as an ordered list of nodes — role, state, name — published
// crash-safe to /host/A11Y.<win> so a reader (GOA11Y) can render the
// focused window's structure with no new WM_RPC kind: the focus comes
// from WINDOWS_QUERY (kind 16) and the outline rides a staged file, the
// APPSTATE pattern (index #3136, D1).
//
// D2 bounds what an outline may carry: control labels and the focused
// item's label only — never field contents, never whole-table text.
// Publication is opt-in per app (GODEMO adopts); GOVAULT never publishes.
package appkit

import "virelai/vi"

// Role is a node's semantic kind — the vocabulary a reader prints
// verbatim, so the wire spellings are the constant's own names.
type Role uint8

const (
	RoleWindow Role = iota
	RoleMenuBar
	RoleMenu
	RoleMenuItem
	RoleTree
	RoleTreeItem
	RoleTable
	RoleRow
	RoleTextField
	RoleButton
	RoleUnknown
)

// roleName is the wire + marker spelling, indexed by Role.
var roleName = [...]string{
	"window", "menubar", "menu", "menuitem", "tree", "treeitem",
	"table", "row", "textfield", "button", "unknown",
}

func (r Role) String() string {
	if int(r) < len(roleName) {
		return roleName[r]
	}
	return roleName[RoleUnknown]
}

// parseRole decodes a role token. ok=false on any unknown word — a file
// the writer did not produce is malformed, never silently misread.
func parseRole(s string) (Role, bool) {
	for i, n := range roleName {
		if s == n {
			return Role(i), true
		}
	}
	return 0, false
}

// State is the node's flag set. The wire spelling is the four letters in
// declaration order (f,e,s,d), or "-" when empty — one self-delimiting
// token, so the name may hold spaces without quoting.
type State uint8

const (
	StateFocused State = 1 << iota
	StateExpanded
	StateSelected
	StateDisabled
)

func (s State) String() string {
	if s == 0 {
		return "-"
	}
	var b [4]byte
	i := 0
	if s&StateFocused != 0 {
		b[i] = 'f'
		i++
	}
	if s&StateExpanded != 0 {
		b[i] = 'e'
		i++
	}
	if s&StateSelected != 0 {
		b[i] = 's'
		i++
	}
	if s&StateDisabled != 0 {
		b[i] = 'd'
		i++
	}
	return string(b[:i])
}

// parseState decodes a state token: "-" or the f/e/s/d letters in order.
func parseState(s string) (State, bool) {
	if s == "-" {
		return 0, true
	}
	var st State
	i := 0
	for i < len(s) {
		switch s[i] {
		case 'f':
			st |= StateFocused
		case 'e':
			st |= StateExpanded
		case 's':
			st |= StateSelected
		case 'd':
			st |= StateDisabled
		default:
			return 0, false
		}
		i++
	}
	return st, i == len(s) && len(s) > 0
}

// Node is one outline entry. Depth is the indent level — the window sits
// at 0, its controls at 1, a menu's items or a tree's children deeper.
// Name is the control's label under D2; unknown-role nodes carry none.
type Node struct {
	Depth int
	Role  Role
	State State
	Name  string
}

// Accessible is the optional outline contract. A11yTree returns the
// control's own node at depth followed by its visible descendants, in
// the order they read top to bottom. focused is the owner's verdict that
// this control holds the keyboard: when it is true the control marks
// exactly one returned node StateFocused — itself, or the deeper item
// that owns the keys — so a window's outline names one focused item,
// never two.
type Accessible interface {
	A11yTree(depth int, focused bool) []Node
}

// The staged-file contract (D1): the header, the node and byte bounds,
// and the name cut. A writer stops before exceeding either bound; a
// reader treats a file that violates the grammar as malformed.
const (
	a11yHeader   = "#a11y v1\n"
	A11yMaxNodes = 64
	A11yMaxBytes = 4 * 1024
	a11yNameMax  = 48
)

// A11yPath is the staged-file rendezvous for win's outline — one spelling
// derived from the window id, the AppStatePath pattern.
func A11yPath(win uint32) string {
	return "/host/A11Y." + vi.Itoa64(int64(win))
}

// a11yWrite is the publish seam — WriteFileSafe on the guest, a stub a
// host test can observe (the wmstate.go pattern).
var a11yWrite = vi.WriteFileSafe

// cutA11yName applies the 48-byte name bound at a rune boundary and drops
// anything past the first newline — a label is one line by grammar.
func cutA11yName(s string) string {
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' || s[i] == '\r' {
			s = s[:i]
			break
		}
	}
	if len(s) > a11yNameMax {
		cut := a11yNameMax
		for cut > 0 && s[cut]&0xc0 == 0x80 {
			cut--
		}
		s = s[:cut]
	}
	return s
}

// EncodeOutline serializes nodes into the staged-file body: the header,
// then one `<depth> <role> <state> <name>` line per node — at most
// A11yMaxNodes nodes and A11yMaxBytes bytes total, names cut at 48 bytes.
// A line that would push the file past the byte bound ends the encode:
// the outline's tail is truncated, never half-written.
func EncodeOutline(nodes []Node) []byte {
	out := append([]byte(nil), a11yHeader...)
	n := len(nodes)
	if n > A11yMaxNodes {
		n = A11yMaxNodes
	}
	for i := 0; i < n; i++ {
		nd := nodes[i]
		depth := nd.Depth
		if depth < 0 {
			depth = 0
		}
		line := vi.Itoa64(int64(depth)) + " " + nd.Role.String() +
			" " + nd.State.String()
		if name := cutA11yName(nd.Name); name != "" {
			line += " " + name
		}
		line += "\n"
		if len(out)+len(line) > A11yMaxBytes {
			break
		}
		out = append(out, line...)
	}
	return out
}

// DecodeOutline is the total inverse: the header must match and every
// remaining line must parse — a missing header, a bad field, or junk
// after the state token is a malformed file (ok=false), not a best guess.
// The reader never sees a partial decode it could mistake for the real
// outline.
func DecodeOutline(b []byte) ([]Node, bool) {
	if len(b) < len(a11yHeader) || string(b[:len(a11yHeader)]) != a11yHeader {
		return nil, false
	}
	var out []Node
	rest := string(b[len(a11yHeader):])
	for rest != "" {
		line := rest
		if i := indexByte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i+1:]
		} else {
			rest = ""
		}
		if line == "" {
			continue
		}
		n, ok := parseNodeLine(line)
		if !ok {
			return nil, false
		}
		out = append(out, n)
	}
	return out, true
}

// parseNodeLine decodes `<depth> <role> <state>[ <name>]`.
func parseNodeLine(s string) (Node, bool) {
	var n Node
	depth, s1, ok := cutField10(s, ' ')
	if !ok {
		return n, false
	}
	d, dok := parseDepth(depth)
	if !dok {
		return n, false
	}
	role, s2, ok := cutField10(s1, ' ')
	if !ok {
		return n, false
	}
	r, rok := parseRole(role)
	if !rok {
		return n, false
	}
	// The name is the optional tail: absent, the state token ends the line.
	state, rest := s2, ""
	if i := indexByte(s2, ' '); i >= 0 {
		state, rest = s2[:i], s2[i+1:]
	}
	st, sok := parseState(state)
	if !sok {
		return n, false
	}
	n.Depth, n.Role, n.State = d, r, st
	n.Name = cutA11yName(rest)
	return n, true
}

// cutField10 splits s at the first sep, returning head and the remainder
// ("" and ok=false when the separator is absent or the head is empty).
func cutField10(s string, sep byte) (head, rest string, ok bool) {
	i := indexByte(s, sep)
	if i <= 0 {
		return "", s, false
	}
	return s[:i], s[i+1:], true
}

// indexByte is the one byte-scan the package needs — no strings import,
// the image-budget posture this package keeps.
func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

// parseDepth decodes a non-negative decimal depth.
func parseDepth(s string) (int, bool) {
	if s == "" || len(s) > 3 {
		return 0, false
	}
	d := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		d = d*10 + int(s[i]-'0')
	}
	return d, true
}

// PublishOutline stages the window's outline at A11yPath — crash-safe, so
// a reader can never see half a tree. The app calls it on focus change
// and on structural change, never per frame.
func PublishOutline(win uint32, nodes []Node) bool {
	return a11yWrite(A11yPath(win), EncodeOutline(nodes)) == 0
}

// a11yDelete is the unpublish seam — FileDelete on the guest.
var a11yDelete = vi.FileDelete

// UnpublishOutline removes win's staged outline on a clean exit. A crash
// or kill leaves the file behind — the reader's kind-16 focus check means
// it is only ever read while this exact window is focused, so residue is
// dead data, never a wrong window's tree.
func UnpublishOutline(win uint32) int64 {
	return a11yDelete(A11yPath(win))
}

// A11yTree reports the button's node: role button, the widget's own
// label. OnActivate is an action, not structure, so it has no node.
func (b *ActionButton) A11yTree(depth int, focused bool) []Node {
	n := Node{Depth: depth, Role: RoleButton}
	if b.Button != nil {
		n.Name = b.Button.Label
	}
	if focused {
		n.State |= StateFocused
	}
	return []Node{n}
}

// A11yTree reports the field's node: role textfield, named by its label —
// the Prefix prompt or the Placeholder, never the contents (D2).
func (f *TextField) A11yTree(depth int, focused bool) []Node {
	name := f.Prefix
	for len(name) > 0 && (name[len(name)-1] == ' ' || name[len(name)-1] == '\t') {
		name = name[:len(name)-1]
	}
	if name == "" {
		name = f.Placeholder
	}
	n := Node{Depth: depth, Role: RoleTextField, Name: name}
	if f.Disabled {
		n.State |= StateDisabled
	}
	if focused {
		n.State |= StateFocused
	}
	return []Node{n}
}
