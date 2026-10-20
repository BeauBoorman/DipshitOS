package main

import "testing"

// The formula corpus: parse-level cases. Ranges are legal only inside a
// call; '[' and ']' are the gate-typeable aliases for '(' and ')'.
func TestParse(t *testing.T) {
	good := []string{
		"1", "2.5", "-3", "+4", "a1", "A1", "dx64", "1+2*3", "(1+2)*3",
		"sum(a1:a2)", "SUM(A1:A2)", "sum[a1:a2]", "SUM[A1:A2]",
		"min(a1,b1:c3,4)", "abs(-3)", "round(2.567,2)", "round(a1)",
		"count(a1:b2,c1)", "-a1*2", "avg(a1:b2)/2",
		"sum(b2:a1)", // reversed endpoints parse; eval normalizes
	}
	for _, s := range good {
		if _, ok := parseFormula(s); !ok {
			t.Errorf("parseFormula(%q) = fail, want ok", s)
		}
	}
	bad := []string{
		"", "+", "1+", "a1:", "sum(", "sum()", "foo()", "a1 b2", "1 2",
		"abs()", "abs(1,2)", "abs(a1:b2)", "round()", "round(1,2,3)",
		"a1:b2", "(", ")", "sum(a1:)", "=", "a1+", ".", "..5",
		"sum(a1:a2", "sum a1:a2",
	}
	for _, s := range bad {
		if n, ok := parseFormula(s); ok {
			t.Errorf("parseFormula(%q) = %v, want fail", s, n)
		}
	}
}

func TestParseRef(t *testing.T) {
	cases := []struct {
		s   string
		col int
		row int
	}{
		{"a1", 0, 0}, {"A1", 0, 0}, {"b2", 1, 1},
		{"DX64", 127, 63}, {"dx64", 127, 63},
		{"z26", 25, 25}, {"aa1", 26, 0},
		// Out-of-grid addresses parse; eval answers #REF.
		{"A0", 0, -1}, {"A65", 0, 64}, {"ZZ1", 701, 0}, {"DY1", 128, 0},
	}
	for _, c := range cases {
		r, ok := parseRef(c.s)
		if !ok {
			t.Errorf("parseRef(%q) failed", c.s)
			continue
		}
		if r.col != c.col || r.row != c.row {
			t.Errorf("parseRef(%q) = %v, want col=%d row=%d", c.s, r, c.col, c.row)
		}
	}
	for _, s := range []string{"", "A", "1A", "a", "1", "a1b", "A-1"} {
		if _, ok := parseRef(s); ok {
			t.Errorf("parseRef(%q) = ok, want fail", s)
		}
	}
}

func TestColName(t *testing.T) {
	cases := map[int]string{0: "A", 25: "Z", 26: "AA", 51: "AZ", 52: "BA", 127: "DX"}
	for col, want := range cases {
		if got := colName(col); got != want {
			t.Errorf("colName(%d) = %q, want %q", col, got, want)
		}
	}
}
