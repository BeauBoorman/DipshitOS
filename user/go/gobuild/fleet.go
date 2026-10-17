package main

// The M112a (#2413) fleet verb: `gobuild fleet` builds every ELF the pinned
// fleet list (user/go/gobuild/fleet.txt, staged as /host/FLEET.TXT) names,
// from the staged source tree (/host/SRC), and writes a source→ELF manifest
// to /host/FLEET.MF.
//
// Per ELF the manifest records: the compiled source set's sha256, the
// toolchain stamp (sha256 over the two staged toolchain images), the
// in-guest product's sha256, the host-built reference's sha256 (staged
// under /host/REF), and a NAMED verdict — match, mismatch:<why>,
// refused:<code>, or failed:<code>. Hash parity is the goal the index
// states but cannot promise (non-goal: bit-for-bit beyond the pinned
// toolchain), so a mismatch always carries its structural reason.
//
// A row whose source lives outside the stageable tree (external:) or whose
// closure needs a dep outside the M107b allowlist gets a named refusal —
// never a silently widened surface, never a skipped row.

import (
	"sort"
	"strconv"
	"strings"

	"virelai/vsys"
)

// fleetRow is one pinned fleet entry: NAME.ELF plus its program dir under
// the source root, or "external:<what>" for sources outside the stageable
// tree (GOSTALGIA is a pinned host-side repo + overlay, not share source).
type fleetRow struct {
	Name string
	Src  string
}

// parseFleet reads fleet.txt: `<NAME.ELF> <src>` rows, `#` comments, blank
// lines. A malformed row refuses by name like a malformed manifest does.
func parseFleet(text string) ([]fleetRow, Diag) {
	var rows []fleetRow
	for n, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		f := strings.Fields(line)
		if len(f) != 2 || !strings.HasSuffix(f[0], ".ELF") {
			return nil, Diag{Code: "bad_fleet", Line: n + 1,
				Msg: "fleet list: expected `<NAME.ELF> <src|external:x>`, got " + line}
		}
		rows = append(rows, fleetRow{Name: f[0], Src: f[1]})
	}
	return rows, Diag{}
}

// fleetCfg wires one `gobuild fleet` run.
type fleetCfg struct {
	List      string // default /host/FLEET.TXT
	Root      string // default /host/SRC
	OutDir    string // default /host
	RefDir    string // default /host/REF — host-built reference ELFs
	Manifest  string // default /host/FLEET.MF
	Importcfg []string
	PkgDB     []string
	Smoke     bool // exec each built product once (bounded wait + kill)
}

// fleetOutcome is one row of the manifest before it is rendered.
type fleetOutcome struct {
	name             string
	state            string // built | refused | failed
	code             string // the refusal/failure's name
	note             string
	srcSHA, guestSHA string
	hostSHA          string
	smoke            string
	ms               int64
}

// execSmoke runs a built product once and reports a one-word verdict.
// The seam is faked in host tests; the guest impl is in spawn_guest.go.
var execSmoke = execSmokeGuest

// relUnder strips the source-root prefix for manifest paths.
func relUnder(root, path string) string {
	if strings.HasPrefix(path, root+"/") {
		return path[len(root)+1:]
	}
	return path
}

// srcTreeHash is the manifest's "source-tree hash": sha256 over the sorted
// compiled source set — each file's root-relative path then its content
// hash — so the value is invariant under directory read order.
func srcTreeHash(root string, files []string) string {
	type pair struct{ rel, path string }
	pairs := make([]pair, len(files))
	for i, f := range files {
		pairs[i] = pair{relUnder(root, f), f}
	}
	sort.Slice(pairs, func(i, j int) bool { return pairs[i].rel < pairs[j].rel })
	st := sha256New()
	for _, p := range pairs {
		b, err := readFile(p.path)
		if err != nil {
			continue
		}
		st.Write([]byte(p.rel))
		st.Write([]byte{0})
		st.Write([]byte(sha256HexOf(b)))
	}
	return hexOfSum(st.Sum())
}

// toolchainStamp hashes the two staged toolchain images — the manifest's
// "toolchain stamp", so a toolchain swap is visible as a stamp change.
func toolchainStamp() string {
	st := sha256New()
	for _, img := range []string{compileImage, linkImage} {
		b, err := readFile(joinPath("/host", img))
		if err != nil {
			b, _ = readFile(img)
		}
		st.Write(b)
		st.Write([]byte{0})
	}
	return hexOfSum(st.Sum())
}

func hexOfSum(sum [32]byte) string {
	out := make([]byte, 64)
	for i, v := range sum {
		out[2*i] = sha256Hex[v>>4]
		out[2*i+1] = sha256Hex[v&15]
	}
	return string(out)
}

// hashVerdict names the guest-vs-host comparison. "mismatch" is the
// expected state — host and guest link from different file layouts
// (/host/SRC vs the build tree) and different build stamps — and the
// note says which structural cause applies.
func hashVerdict(guestSHA, hostSHA string, guestSize, hostSize int64) (verdict, note string) {
	if hostSHA == "" {
		return "host-missing", "no staged host reference"
	}
	if guestSHA == hostSHA {
		return "match", ""
	}
	delta := guestSize - hostSize
	if delta < 0 {
		delta = -delta
	}
	if hostSize > 0 && delta*100/hostSize > 15 {
		return "mismatch:size-delta", "guest and host ELFs differ in bytes and size"
	}
	return "mismatch:paths-buildid", "embedded source paths and build stamp differ by construction"
}

// runFleet builds the pinned list, smokes each product, writes FLEET.MF.
func runFleet(fc fleetCfg) int {
	body, err := readFile(fc.List)
	if err != nil {
		vsys.Println("gobuild: fleet: cannot read " + fc.List)
		return 1
	}
	rows, d := parseFleet(string(body))
	if d.Code != "" {
		vsys.Println("gobuild: fleet: " + d.String())
		return 1
	}
	tc := toolchainStamp()
	var outcomes []fleetOutcome
	built, refused, failed := 0, 0, 0

	for _, row := range rows {
		oc := fleetOutcome{name: row.Name}
		out := joinPath(fc.OutDir, row.Name)

		if strings.HasPrefix(row.Src, "external:") {
			oc.state = "refused"
			oc.code = "external_tree"
			oc.note = "sources outside the staged tree: " + row.Src[len("external:"):]
			vsys.Println("fleet: " + row.Name + " refused external_tree: " + oc.note)
			refused++
			outcomes = append(outcomes, oc)
			continue
		}
		dir := joinPath(fc.Root, row.Src)
		files, lerr := listGoFiles(dir)
		if lerr != nil || len(files) == 0 {
			oc.state = "refused"
			oc.code = "source_missing"
			oc.note = dir + " is not on the share"
			if lerr != nil {
				oc.note += " (list: " + lerr.Error() + ")"
			}
			vsys.Println("fleet: " + row.Name + " refused source_missing: " + oc.note)
			refused++
			outcomes = append(outcomes, oc)
			continue
		}

		res := Build(Config{Dir: dir, Root: fc.Root, Out: out,
			Importcfg: fc.Importcfg, PkgDB: fc.PkgDB})
		for _, st := range res.Steps {
			oc.ms += st.Ms
		}
		if res.ELF == "" {
			code := "graph"
			if len(res.Diags) > 0 {
				code = res.Diags[0].Code
			}
			if len(res.Steps) == 0 {
				oc.state, oc.code = "refused", code
				refused++
			} else {
				oc.state, oc.code = "failed", code
				failed++
			}
			msg := ""
			if len(res.Diags) > 0 {
				msg = res.Diags[0].Msg
			}
			oc.note = msg
			vsys.Println("fleet: " + row.Name + " " + oc.state + " " +
				oc.code + ": " + msg)
			// A crashed child leaves its stack in the capture; the parsed
			// head carries the signal line and the faulting goroutine —
			// bound it so a spewing child cannot flood the serial.
			if oc.state == "failed" && len(res.Diags) > 1 {
				hi := len(res.Diags)
				if hi > 8 {
					hi = 8
				}
				for _, d := range res.Diags[:hi] {
					m := d.Msg
					if len(m) > 160 {
						m = m[:160]
					}
					vsys.Println("fleet: " + row.Name + " diag: " + m)
				}
			}
			outcomes = append(outcomes, oc)
			continue
		}

		oc.state = "built"
		oc.srcSHA = srcTreeHash(fc.Root, res.SrcFiles)
		g, ok := sha256File(out)
		if ok {
			oc.guestSHA = g
		}
		h, hok := sha256File(joinPath(fc.RefDir, row.Name))
		if hok {
			oc.hostSHA = h
		}
		verdict, note := hashVerdict(oc.guestSHA, oc.hostSHA, fileSize(out), fileSize(joinPath(fc.RefDir, row.Name)))
		oc.code = verdict
		oc.note = note
		built++
		vsys.Println("fleet: " + row.Name + " built sha256=" + oc.guestSHA +
			" hash=" + verdict + " ms=" + strconv.FormatInt(oc.ms, 10))

		if fc.Smoke {
			oc.smoke = execSmoke(row.Name)
			vsys.Println("fleet: smoke " + row.Name + " " + oc.smoke)
		}
		outcomes = append(outcomes, oc)
	}

	if err := writeFile(fc.Manifest, []byte(renderManifest(tc, outcomes))); err != nil {
		vsys.Println("fleet: manifest write failed: " + err.Error())
		failed++
	} else {
		vsys.Println("fleet: manifest -> " + fc.Manifest)
	}
	if failed > 0 {
		vsys.Println("fleet: fleet INCOMPLETE built=" + strconv.Itoa(built) +
			" refused=" + strconv.Itoa(refused) + " failed=" + strconv.Itoa(failed))
		return 1
	}
	vsys.Println("fleet: fleet OK built=" + strconv.Itoa(built) +
		" refused=" + strconv.Itoa(refused))
	return 0
}

// fileSize is the byte length the manifest compares; 0 when unreadable.
func fileSize(path string) int64 {
	b, err := readFile(path)
	if err != nil {
		return 0
	}
	return int64(len(b))
}

// renderManifest writes the #v1 row format the card asks for: per ELF the
// source hash, toolchain stamp, in-guest sha256, host sha256, verdict.
func renderManifest(tc string, outcomes []fleetOutcome) string {
	var b strings.Builder
	b.WriteString("#v1 fleet manifest — M112a (#2413): the pinned fleet built in-guest\n")
	b.WriteString("# row: <NAME.ELF>\\t<built|refused|failed>\\tsrc=<sha256|->\\ttc=<sha256>" +
		"\\tguest=<sha256|->\\thost=<sha256|->\\thash=<match|mismatch:*|host-missing|->" +
		"\\tsmoke=<verdict|->\\tms=<n>[\\tcode=<name>][\\tnote=<text>]\n")
	for _, oc := range outcomes {
		or := func(s string) string {
			if s == "" {
				return "-"
			}
			return s
		}
		hash := oc.code
		if oc.state != "built" {
			hash = "" // refused/failed rows carry the name in code= instead
		}
		b.WriteString(oc.name + "\t" + oc.state +
			"\tsrc=" + or(oc.srcSHA) +
			"\ttc=" + tc +
			"\tguest=" + or(oc.guestSHA) +
			"\thost=" + or(oc.hostSHA) +
			"\thash=" + or(hash) +
			"\tsmoke=" + or(oc.smoke) +
			"\tms=" + strconv.FormatInt(oc.ms, 10))
		if oc.state != "built" && oc.code != "" {
			b.WriteString("\tcode=" + oc.code)
		}
		if oc.note != "" {
			b.WriteString("\tnote=" + oc.note)
		}
		b.WriteString("\n")
	}
	return b.String()
}
