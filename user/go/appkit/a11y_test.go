package appkit

import (
	"testing"

	"virelai/widgets"
)

// Conformance pins: the card's controls implement Accessible.
var (
	_ Accessible = &MenuBar{}
	_ Accessible = &TreeController{}
	_ Accessible = &TableController{}
	_ Accessible = &TextField{}
	_ Accessible = &ActionButton{}
)

func TestRoleStateWire(t *testing.T) {
	for r := Role(0); r <= RoleUnknown; r++ {
		back, ok := parseRole(r.String())
		if !ok || back != r {
			t.Fatalf("role %d round-trip = %q %v", r, r.String(), ok)
		}
	}
	if RoleUnknown.String() != "unknown" {
		t.Fatalf("unknown spells %q", RoleUnknown.String())
	}
	if _, ok := parseRole("bogus"); ok {
		t.Fatal("bogus role parsed")
	}
	for _, s := range []State{0, StateFocused, StateFocused | StateSelected,
		StateFocused | StateExpanded | StateSelected | StateDisabled} {
		back, ok := parseState(s.String())
		if !ok || back != s {
			t.Fatalf("state %d (%q) round-trip = %d %v", s, s.String(), back, ok)
		}
	}
	if State(0).String() != "-" || (StateFocused|StateExpanded).String() != "fe" {
		t.Fatalf("state spellings: %q %q", State(0).String(), (StateFocused | StateExpanded).String())
	}
	for _, bad := range []string{"", "x", "fz", "f-f"} {
		if _, ok := parseState(bad); ok {
			t.Fatalf("state %q parsed", bad)
		}
	}
}

func TestOutlineOrderIsFocusOrder(t *testing.T) {
	a := &focusProbe{}
	b := &focusProbe{}
	c := &focusProbe{}
	ring := NewFocusRing(a, b, c)
	ring.Focus(1)
	out := ring.Outline(1)
	if len(out) != 3 {
		t.Fatalf("outline len = %d", len(out))
	}
	// Ring order is the outline order — the same order Tab walks.
	for i, n := range out {
		if n.Role != RoleUnknown || n.Depth != 1 {
			t.Fatalf("node %d = %+v: a non-Accessible item must appear as unknown", i, n)
		}
	}
	if out[1].State != StateFocused {
		t.Fatalf("focused item state = %v", out[1].State)
	}
	if out[0].State != 0 || out[2].State != 0 {
		t.Fatalf("unfocused items carry state: %+v", out)
	}
	// Focus moves: the focused marker moves with it, in ring order.
	ring.Next()
	out = ring.Outline(1)
	if out[2].State != StateFocused || out[1].State != 0 {
		t.Fatalf("focus move outline = %+v", out)
	}
}

func TestMenuBarA11yTree(t *testing.T) {
	quit, exp := 0, 0
	b := &MenuBar{Menus: demoMenus(&quit, &exp)}

	// Idle bar: the bar node plus one menu node per title, no items.
	out := b.A11yTree(1, true)
	if len(out) != 4 || out[0].Role != RoleMenuBar || out[0].Name == "" {
		t.Fatalf("idle bar = %+v", out)
	}
	if out[0].State != StateFocused {
		t.Fatalf("idle focused bar = %+v", out[0])
	}
	for i, want := range []string{"File", "Edit", "View"} {
		if out[i+1].Role != RoleMenu || out[i+1].Name != want || out[i+1].Depth != 2 {
			t.Fatalf("menu %d = %+v", i, out[i+1])
		}
	}

	// F10 menu mode: the bar expands, the highlighted title is selected
	// and focused, and items stay hidden until the menu opens.
	b.Activate(0)
	out = b.A11yTree(1, true)
	if out[0].State != StateExpanded {
		t.Fatalf("active bar = %+v", out[0])
	}
	if out[1].State != StateSelected|StateFocused {
		t.Fatalf("active title = %+v", out[1])
	}
	if len(out) != 4 {
		t.Fatalf("active but closed shows no items: %+v", out)
	}

	// Open: only the open menu's items appear; the highlighted item is
	// the focused node; a disabled row says so.
	b.OpenMenu(1) // Edit: Cut is disabled, Copy is first-enabled
	out = b.A11yTree(1, true)
	if len(out) != 6 {
		t.Fatalf("open menu outline = %+v", out)
	}
	if out[2].State != StateSelected|StateExpanded {
		t.Fatalf("open menu = %+v", out[2])
	}
	items := out[3:]
	if items[0].Role != RoleMenuItem || items[0].Name != "Cut" ||
		items[0].State != StateDisabled {
		t.Fatalf("disabled item = %+v", items[0])
	}
	if items[1].Name != "Copy" || items[1].State != StateSelected|StateFocused {
		t.Fatalf("hovered item = %+v", items[1])
	}

	// Exactly one focused node exists anywhere in the subtree.
	focused := 0
	for _, n := range out {
		if n.State&StateFocused != 0 {
			focused++
		}
	}
	if focused != 1 {
		t.Fatalf("focused nodes = %d", focused)
	}
}

func TestTreeA11yTree(t *testing.T) {
	view := &widgets.Tree{}
	ctl := NewTreeController(view, []*TreeNode{
		{Label: "system", Expanded: true, Kids: []*TreeNode{
			{Label: "kernel"},
			{Label: "services", Kids: []*TreeNode{{Label: "net"}}},
		}},
		{Label: "apps"},
	})
	ctl.SelectRow(1)
	out := ctl.A11yTree(1, true)
	if len(out) != 5 || out[0].Role != RoleTree {
		t.Fatalf("tree outline = %+v", out)
	}
	// Depths follow the model: roots at +1, kids one deeper.
	want := []struct {
		depth int
		name  string
		state State
	}{
		{2, "system", StateExpanded},
		{3, "kernel", StateSelected | StateFocused},
		{3, "services", 0},
		{2, "apps", 0},
	}
	for i, w := range want {
		if out[i+1].Role != RoleTreeItem || out[i+1].Depth != w.depth ||
			out[i+1].Name != w.name || out[i+1].State != w.state {
			t.Fatalf("treeitem %d = %+v want %+v", i, out[i+1], w)
		}
	}
	// Not the focus owner: the selected row keeps selected, drops focused.
	out = ctl.A11yTree(1, false)
	if out[2].State != StateSelected {
		t.Fatalf("unfocused tree sel = %+v", out[2])
	}
}

func TestTableA11yTree(t *testing.T) {
	tbl := &widgets.Table{
		Cols: []widgets.TableColumn{{Title: "Name"}, {Title: "Kind"}},
		Rows: 64, Row: 2, Col: 1,
	}
	ctl := NewTableController(tbl)
	out := ctl.A11yTree(1, true)
	// headers + focused row + self = 4
	if len(out) != 4 || out[0].Role != RoleTable {
		t.Fatalf("table outline = %+v", out)
	}
	if out[1].Name != "Name" || out[2].Name != "Kind" ||
		out[1].Role != RoleRow || out[2].Role != RoleRow {
		t.Fatalf("header rows = %+v", out[1:])
	}
	last := out[3]
	if last.Role != RoleRow || last.Name != "row 3 of 64" ||
		last.State != StateSelected|StateFocused {
		t.Fatalf("focused row = %+v", last)
	}
	// No contents leak: only the index and count ride the name.
	tbl.Row, tbl.Col = -1, -1
	out = NewTableController(tbl).A11yTree(1, true)
	if len(out) != 3 || out[0].State != StateFocused {
		t.Fatalf("no-cell table = %+v", out)
	}
}

func TestTextFieldPublishesLabelNotValue(t *testing.T) {
	f := NewTextField(widgets.Rect{}, 64)
	f.SetValue("secret-typed-value")
	f.Prefix = "> "
	out := f.A11yTree(1, true)
	if len(out) != 1 || out[0].Role != RoleTextField {
		t.Fatalf("field outline = %+v", out)
	}
	if out[0].Name != ">" {
		t.Fatalf("field name = %q", out[0].Name)
	}
	// The placeholder is the label when no prefix is set; the value is
	// never the name (D2).
	f.Prefix = ""
	f.Placeholder = "search names"
	out = f.A11yTree(1, true)
	if out[0].Name != "search names" {
		t.Fatalf("placeholder name = %q", out[0].Name)
	}
	for _, n := range EncodeOutline(out) {
		_ = n
	}
	if got := string(EncodeOutline(out)); contains(got, "secret-typed-value") {
		t.Fatal("field contents leaked into the outline")
	}
}

func contains(s, sub string) bool {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

func TestActionButtonA11yTree(t *testing.T) {
	b := &ActionButton{Button: &widgets.Button{Label: "Apply"}}
	out := b.A11yTree(1, true)
	if len(out) != 1 || out[0].Role != RoleButton ||
		out[0].Name != "Apply" || out[0].State != StateFocused {
		t.Fatalf("button outline = %+v", out)
	}
}

func TestEncodeOutlineBounds(t *testing.T) {
	// 64-node bound: more nodes in, exactly 64 lines out.
	var nodes []Node
	for i := 0; i < 100; i++ {
		nodes = append(nodes, Node{Depth: 1, Role: RoleTreeItem, Name: "x"})
	}
	enc := EncodeOutline(nodes)
	dec, ok := DecodeOutline(enc)
	if !ok {
		t.Fatal("bounded encode must still decode")
	}
	if len(dec) != A11yMaxNodes {
		t.Fatalf("decoded %d nodes, bound %d", len(dec), A11yMaxNodes)
	}
	// 4 KiB bound: long names never push the file past it.
	nodes = nodes[:0]
	for i := 0; i < 64; i++ {
		nodes = append(nodes, Node{Depth: 2, Role: RoleMenuItem,
			Name: "a-very-long-menu-item-label-that-keeps-going-past-the-cut"})
	}
	enc = EncodeOutline(nodes)
	if len(enc) > A11yMaxBytes {
		t.Fatalf("encoded %d bytes over %d", len(enc), A11yMaxBytes)
	}
	if _, ok := DecodeOutline(enc); !ok {
		t.Fatal("byte-bounded encode must still decode")
	}
	// Names cut at 48 bytes on a rune boundary.
	long := ""
	for len(long) < 60 {
		long += "é" // two bytes per rune
	}
	cut := cutA11yName(long)
	if len(cut) > 48 || len(cut)%2 != 0 {
		t.Fatalf("name cut = %d bytes", len(cut))
	}
}

func TestOutlineGrammarRoundTrip(t *testing.T) {
	nodes := []Node{
		{Depth: 0, Role: RoleWindow, Name: "Dialog"},
		{Depth: 1, Role: RoleMenuBar, State: StateExpanded, Name: "Menu bar"},
		{Depth: 2, Role: RoleMenu, State: StateSelected | StateExpanded, Name: "File"},
		{Depth: 3, Role: RoleMenuItem, State: StateFocused | StateSelected, Name: "Open…"},
		{Depth: 1, Role: RoleTree, Name: "Tree"},
		{Depth: 2, Role: RoleTreeItem, State: StateFocused | StateSelected, Name: "a name with spaces"},
		{Depth: 1, Role: RoleUnknown, State: StateFocused},
	}
	enc := EncodeOutline(nodes)
	if string(enc[:len(a11yHeader)]) != a11yHeader {
		t.Fatalf("header = %q", enc[:len(a11yHeader)])
	}
	dec, ok := DecodeOutline(enc)
	if !ok || len(dec) != len(nodes) {
		t.Fatalf("round-trip ok=%v n=%d", ok, len(dec))
	}
	for i := range nodes {
		if dec[i] != nodes[i] {
			t.Fatalf("node %d = %+v want %+v", i, dec[i], nodes[i])
		}
	}
	// A header-only file is a legal empty outline; the malformed inputs
	// below are named, never a crash.
	if empty, ok := DecodeOutline([]byte(a11yHeader)); !ok || len(empty) != 0 {
		t.Fatalf("empty outline ok=%v n=%d", ok, len(empty))
	}
	for _, bad := range []string{
		"", "#a11y v2\n1 tree - x\n", "#a11y v1\n1 tree - x\n\xff",
		"#a11y v1\nx tree - x\n",
		"#a11y v1\n1 bogus - x\n",
		"#a11y v1\n1 tree ? x\n",
		"#a11y v1\n1 tree\n",
	} {
		if _, ok := DecodeOutline([]byte(bad)); ok {
			t.Fatalf("malformed decoded: %q", bad)
		}
	}
}

func TestPublishOutline(t *testing.T) {
	var gotPath string
	var gotBody []byte
	saved := a11yWrite
	a11yWrite = func(path string, b []byte) int64 {
		gotPath, gotBody = path, append([]byte(nil), b...)
		return 0
	}
	defer func() { a11yWrite = saved }()

	nodes := []Node{{Role: RoleWindow, Name: "W"}}
	if !PublishOutline(7, nodes) {
		t.Fatal("publish refused")
	}
	if gotPath != "/host/A11Y.7" {
		t.Fatalf("path = %q", gotPath)
	}
	dec, ok := DecodeOutline(gotBody)
	if !ok || len(dec) != 1 || dec[0].Name != "W" {
		t.Fatalf("published body = %q", gotBody)
	}
	// A write refusal propagates.
	a11yWrite = func(string, []byte) int64 { return -1 }
	if PublishOutline(7, nodes) {
		t.Fatal("refused write reported success")
	}
}
