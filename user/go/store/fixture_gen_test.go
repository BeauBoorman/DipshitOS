package store

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"testing"

	"virelai/flint/parser"
	"virelai/sshlib"
)

// TestGenReleaseFixture regenerates testdata/release-stream.jsonl (the
// signed release Change the go-flint gate publishes onto flintd's `rel`
// stream and the consumer's replica) plus testdata/release.go (the
// manifest text the atoms hash against). Skipped unless
// STORE_GEN_FIXTURE=1 — the gate's setup hook runs it so the fixture
// always tracks the CURRENT GOHELLO.ELF (the build is not bit-reproducible
// across toolchains/paths, so a frozen fixture would go stale).
//
// M101e (#2317) made it a small fixture factory: the same env knobs mint
// the v2 release (a parented Change carrying modify ops against the v1
// atoms, for the update/rollback leg) and the empty-ops Changes the
// key_unknown/key_revoked negatives serve from flintd.
//
//	STORE_FIXTURE_ELF          ELF whose sha256 the manifest pins (default .build/go/GOHELLO.ELF)
//	STORE_FIXTURE_NAME         ReleaseName                     (default "GOHELLO")
//	STORE_FIXTURE_VERSION      ReleaseVersion                  (default "1.0.0")
//	STORE_FIXTURE_ROW          ReleaseManifestRow              (default derived from NAME)
//	STORE_FIXTURE_SUMMARY      ReleaseSummary                  (ADR 0055 optional; "" omits the const)
//	STORE_FIXTURE_DESCRIPTION  ReleaseDescription              (optional)
//	STORE_FIXTURE_CATEGORY     ReleaseCategory                 (optional)
//	STORE_FIXTURE_ICON_SHA256  ReleaseIconSHA256               (optional)
//	STORE_FIXTURE_CAPS         ReleaseCaps                     (ADR 0054 D10 optional;
//	                           "" omits the const)
//	STORE_FIXTURE_DEPENDS      ReleaseDepends                  (ADR 0055 D8 optional;
//	                           "" omits the const)
//	STORE_FIXTURE_PREV_CAPS    parent's ReleaseCaps            (default: same as
//	                           STORE_FIXTURE_CAPS — the widening-update leg sets
//	                           a different parent ask; "-" = parent omitted it,
//	                           which emits an `add` op for the const)
//	STORE_FIXTURE_PREV_DEPS    parent's ReleaseDepends         (default: same as
//	                           STORE_FIXTURE_DEPENDS; "-" = parent omitted it)
//	STORE_FIXTURE_STREAM       stream uuid                     (default `rel`)
//	STORE_FIXTURE_CHANGE       change id                       (default genChangeID)
//	STORE_FIXTURE_PARENT       parent change id                (default none)
//	STORE_FIXTURE_TS           unix ms                         (default 1760000000000)
//	STORE_FIXTURE_MSG          commit message                  (default "release")
//	STORE_FIXTURE_SEED         file holding a 64-hex seed      (default genSeedFile)
//	STORE_FIXTURE_SEED_HEX     inline 64-hex seed              (wins over _SEED)
//	STORE_FIXTURE_PREV_ELF     ELF of the parent release       (modify ops' old_hash)
//	STORE_FIXTURE_PREV_VERSION parent's version                (default "1.0.0")
//	STORE_FIXTURE_DIR          output dir                      (default testdata)
//	STORE_FIXTURE_TAG          name tag                        ("" -> release-stream.jsonl/release.go;
//	                           nonempty -> release-<tag>-stream.jsonl/release-<tag>.go)
//	STORE_FIXTURE_EMPTY=1      empty-ops change only — no ELF read, no release.go
//
// A parented Change diffs against a parent release.go reconstructed with
// the SAME optional-const set — the generator emits add/modify ops only,
// so a child that drops a const would leave the parent's atom signed at
// head. Atom ids derive from the const's qualified name, so a const
// keeps its id across releases regardless of declaration order.
//
// The canonical-bytes port below mirrors user/go/flint/change.go +
// store.go (sigMsg / opsHash / opBytes / sortOps). Keep them in
// lockstep: a drifted generator mints a change that fails `verify`.

const (
	genDomainChange = "FLINT-CHANGE/1\x00"
	genDomainOps    = "FLINT-OPS/1\x00"
	genStreamID     = "0199de2d-dc00-7000-8000-00000000b010" // `rel`
	genChangeID     = "0199de2d-dc00-7000-8000-00000000c001"
	genSeedFile     = "../flint/testdata/sig/seed.hex"
	genRelRow       = "GOHELLO.ELF | Go Hello | g | dock=false"
)

// genAtomID derives the atom id for a manifest const from its qualified
// name — the same const keeps the same id across successive releases, so
// a regenerated parented Change diffs into modify ops on the SAME atoms
// instead of adds that would leave the parent's atoms signed at head.
// The tail is name-hash-derived; the fixed groups keep UUIDv7 shape.
func genAtomID(name string) string {
	sum := sshlib.SHA256Sum([]byte(name))
	return "0199de2d-dc00-7000-8000-" + hex.EncodeToString(sum[26:32])
}

type genSpec struct {
	elfPath, name, version, row, streamID, changeID, parent, msg string
	summary, description, category, iconSHA, caps, prevCaps      string
	deps, prevDeps                                               string
	seedFile, seedHex, prevElf, prevVersion, dir, tag            string
	ts                                                           int64
	empty                                                        bool
}

func genSpecFromEnv(t *testing.T) genSpec {
	t.Helper()
	s := genSpec{
		elfPath:     os.Getenv("STORE_FIXTURE_ELF"),
		name:        "GOHELLO",
		version:     "1.0.0",
		streamID:    genStreamID,
		changeID:    genChangeID,
		parent:      os.Getenv("STORE_FIXTURE_PARENT"),
		msg:         "release",
		seedFile:    genSeedFile,
		seedHex:     os.Getenv("STORE_FIXTURE_SEED_HEX"),
		prevElf:     os.Getenv("STORE_FIXTURE_PREV_ELF"),
		prevVersion: "1.0.0",
		dir:         "testdata",
		tag:         os.Getenv("STORE_FIXTURE_TAG"),
		empty:       os.Getenv("STORE_FIXTURE_EMPTY") == "1",
	}
	if s.elfPath == "" {
		s.elfPath = filepath.Join("..", "..", "..", ".build", "go", "GOHELLO.ELF")
	}
	for env, dst := range map[string]*string{
		"STORE_FIXTURE_NAME":         &s.name,
		"STORE_FIXTURE_VERSION":      &s.version,
		"STORE_FIXTURE_ROW":          &s.row,
		"STORE_FIXTURE_SUMMARY":      &s.summary,
		"STORE_FIXTURE_DESCRIPTION":  &s.description,
		"STORE_FIXTURE_CATEGORY":     &s.category,
		"STORE_FIXTURE_ICON_SHA256":  &s.iconSHA,
		"STORE_FIXTURE_CAPS":         &s.caps,
		"STORE_FIXTURE_PREV_CAPS":    &s.prevCaps,
		"STORE_FIXTURE_DEPENDS":      &s.deps,
		"STORE_FIXTURE_PREV_DEPS":    &s.prevDeps,
		"STORE_FIXTURE_STREAM":       &s.streamID,
		"STORE_FIXTURE_CHANGE":       &s.changeID,
		"STORE_FIXTURE_MSG":          &s.msg,
		"STORE_FIXTURE_SEED":         &s.seedFile,
		"STORE_FIXTURE_PREV_VERSION": &s.prevVersion,
		"STORE_FIXTURE_DIR":          &s.dir,
	} {
		if v := os.Getenv(env); v != "" {
			*dst = v
		}
	}
	if s.row == "" {
		if s.name == "GOHELLO" {
			s.row = genRelRow
		} else {
			s.row = s.name + ".ELF | " + s.name + " | g | dock=false"
		}
	}
	tsText := os.Getenv("STORE_FIXTURE_TS")
	if tsText == "" {
		s.ts = 1760000000000
	} else {
		var err error
		s.ts, err = strconv.ParseInt(tsText, 10, 64)
		if err != nil || s.ts < 0 {
			t.Fatalf("STORE_FIXTURE_TS %q", tsText)
		}
	}
	return s
}

func TestGenReleaseFixture(t *testing.T) {
	if os.Getenv("STORE_GEN_FIXTURE") == "" {
		t.Skip("fixture generation is env-gated (the gate setup hook sets STORE_GEN_FIXTURE)")
	}
	spec := genSpecFromEnv(t)

	seedHexText := spec.seedHex
	if seedHexText == "" {
		b, err := os.ReadFile(spec.seedFile)
		if err != nil {
			t.Fatalf("read signing seed: %v", err)
		}
		seedHexText = strings.TrimSpace(string(b))
	}
	seedHexB, err := hexDec(seedHexText)
	if err != nil || len(seedHexB) != 32 {
		t.Fatalf("seed hex")
	}
	var seed [32]byte
	copy(seed[:], seedHexB)
	defer sshlib.Wipe(seed[:])
	pub := sshlib.EdDerivePublic(seed)

	ops := []Op{}
	var relText string
	if !spec.empty {
		elf, err := os.ReadFile(spec.elfPath)
		if err != nil {
			t.Fatalf("read ELF %s: %v", spec.elfPath, err)
		}
		sum := sshlib.SHA256Sum(elf)
		relText = spec.releaseGo(sshlib.EncodeHex(sum[:]), spec.version)

		// Parse the manifest through the real parser — the atom hashes
		// the ops carry are exactly what verifyRelease recomputes
		// consumer-side.
		p, ok := parser.ForPath("release.go")
		if !ok {
			t.Fatal("no parser for release.go")
		}
		atoms, err := p.Parse("release.go", []byte(relText))
		if err != nil {
			t.Fatalf("parse: %v", err)
		}
		wantAtoms := len(requiredConsts)
		for _, opt := range []string{spec.summary, spec.description, spec.category, spec.iconSHA, spec.caps, spec.deps} {
			if opt != "" {
				wantAtoms++
			}
		}
		if len(atoms) != wantAtoms {
			t.Fatalf("expected %d release atoms, got %d", wantAtoms, len(atoms))
		}

		// A parented Change diffs against the parent release: atoms whose
		// hash moved become modify ops (old_hash = the parent's hash);
		// untouched atoms emit no op — a real commit's diff shape. The
		// parent manifest carries the same optional-const set — see the
		// env-knob comment.
		prevHash := map[string]string(nil)
		if spec.prevElf != "" {
			pElf, err := os.ReadFile(spec.prevElf)
			if err != nil {
				t.Fatalf("read prev ELF %s: %v", spec.prevElf, err)
			}
			pSum := sshlib.SHA256Sum(pElf)
			// The parent's ReleaseCaps defaults to the child's (the
			// non-widening keep leg); STORE_FIXTURE_PREV_CAPS overrides
			// it for a changed ask, and "-" omits the const on the
			// parent entirely (the child then carries an `add` op).
			prevSpec := spec
			prevSpec.caps = spec.caps
			if spec.prevCaps != "" {
				prevSpec.caps = spec.prevCaps
				if prevSpec.caps == "-" {
					prevSpec.caps = ""
				}
			}
			prevSpec.deps = spec.deps
			if spec.prevDeps != "" {
				prevSpec.deps = spec.prevDeps
				if prevSpec.deps == "-" {
					prevSpec.deps = ""
				}
			}
			prevAtoms, err := p.Parse("release.go",
				[]byte(prevSpec.releaseGo(sshlib.EncodeHex(pSum[:]), spec.prevVersion)))
			if err != nil {
				t.Fatalf("parse prev: %v", err)
			}
			prevHash = map[string]string{}
			for _, a := range prevAtoms {
				prevHash[a.Name] = hex.EncodeToString(a.Hash[:])
			}
		}

		for _, a := range atoms {
			span := Span{File: a.File, Start: a.Start, End: a.End}
			op := Op{
				AtomID:     genAtomID(a.Name),
				Kind:       a.Kind,
				NewName:    a.Name,
				NewSpan:    &span,
				NewHash:    hex.EncodeToString(a.Hash[:]),
				NewSigHash: hex.EncodeToString(a.SigHash[:]),
			}
			if ph, ok := prevHash[a.Name]; ok {
				if ph == op.NewHash {
					continue
				}
				op.Type, op.OldHash = "modify", ph
			} else {
				op.Type = "add"
			}
			ops = append(ops, op)
		}
		// Ops must sort by atom id — sortOps mirrors flint's comparator.
		sort.Slice(ops, func(i, j int) bool { return ops[i].AtomID < ops[j].AtomID })
	}

	change := Change{
		ID:      spec.changeID,
		Stream:  spec.streamID,
		TS:      spec.ts,
		Author:  sshlib.EncodeHex(pub[:]),
		Message: spec.msg,
		Ops:     ops,
	}
	if spec.parent != "" {
		change.Parent = &spec.parent
	}
	msg, err := genSigMsg(&change)
	if err != nil {
		t.Fatalf("sigMsg: %v", err)
	}
	sig := sshlib.EdSign(msg, seed)
	change.Sig = sshlib.EncodeHex(sig[:])

	line, err := json.Marshal(change)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(spec.dir, 0o755); err != nil {
		t.Fatal(err)
	}
	prefix := "release"
	if spec.tag != "" {
		prefix += "-" + spec.tag
	}
	if err := os.WriteFile(filepath.Join(spec.dir, prefix+"-stream.jsonl"), append(line, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	if !spec.empty {
		if err := os.WriteFile(filepath.Join(spec.dir, prefix+".go"), []byte(relText), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("generated release fixture: change %s, ops=%d", change.ID, len(change.Ops))
}

// releaseGo renders the release manifest text — the same shape the gate
// stages (DO NOT change the const names: verifyRelease keys on them).
// The optional ADR 0055 catalog consts are emitted only when the spec
// declares them; strconv.Quote keeps multi-line descriptions inside one
// literal.
func (s genSpec) releaseGo(elfSHA, version string) string {
	var b strings.Builder
	b.WriteString("package release\n\n")
	emit := func(name, val string) {
		b.WriteString("const " + name + " = " + strconv.Quote(val) + "\n")
	}
	emit("ReleaseName", s.name)
	emit("ReleaseVersion", version)
	emit("ReleaseELFSHA256", elfSHA)
	emit("ReleaseManifestRow", s.row)
	if s.summary != "" {
		emit("ReleaseSummary", s.summary)
	}
	if s.description != "" {
		emit("ReleaseDescription", s.description)
	}
	if s.category != "" {
		emit("ReleaseCategory", s.category)
	}
	if s.iconSHA != "" {
		emit("ReleaseIconSHA256", s.iconSHA)
	}
	if s.caps != "" {
		emit("ReleaseCaps", s.caps)
	}
	if s.deps != "" {
		emit("ReleaseDepends", s.deps)
	}
	return b.String()
}

// ---- canonical-bytes port (mirrors user/go/flint/change.go) -----------

func genWriteU32LE(buf *bytes.Buffer, v uint32) {
	var b [4]byte
	binary.LittleEndian.PutUint32(b[:], v)
	buf.Write(b[:])
}

func genWriteU64LE(buf *bytes.Buffer, v uint64) {
	var b [8]byte
	binary.LittleEndian.PutUint64(b[:], v)
	buf.Write(b[:])
}

func genWriteStr(buf *bytes.Buffer, s string) {
	genWriteU32LE(buf, uint32(len(s)))
	buf.WriteString(s)
}

func genWriteOptStr(buf *bytes.Buffer, s string) {
	if s == "" {
		buf.WriteByte(0x00)
		return
	}
	buf.WriteByte(0x01)
	genWriteStr(buf, s)
}

func genWriteOptSpan(buf *bytes.Buffer, sp *Span) {
	if sp == nil {
		buf.WriteByte(0x00)
		return
	}
	buf.WriteByte(0x01)
	genWriteStr(buf, sp.File)
	genWriteU32LE(buf, sp.Start)
	genWriteU32LE(buf, sp.End)
}

func genWriteOptHash32(buf *bytes.Buffer, hexStr string) {
	if hexStr == "" {
		buf.WriteByte(0x00)
		return
	}
	h, err := hexDec(hexStr)
	if err != nil || len(h) != 32 {
		buf.WriteByte(0x00)
		return
	}
	buf.WriteByte(0x01)
	buf.Write(h)
}

func genWriteOptUUID(buf *bytes.Buffer, u *string) {
	if u == nil {
		buf.WriteByte(0x00)
		return
	}
	buf.WriteByte(0x01)
	buf.Write(mustUUID(*u))
}

// genOpTypeCode mirrors flint's opTypeCode (store.go).
func genOpTypeCode(t string) uint8 {
	switch t {
	case "add":
		return 1
	case "modify":
		return 2
	case "delete":
		return 3
	case "move":
		return 4
	case "rename":
		return 5
	default:
		return 0
	}
}

func genOpBytes(op Op) []byte {
	code := genOpTypeCode(op.Type)
	if code == 0 {
		panic("gen: bad op type " + op.Type)
	}
	var buf bytes.Buffer
	buf.WriteByte(code)
	buf.Write(mustUUID(op.AtomID))
	genWriteOptStr(&buf, op.Kind)
	genWriteOptStr(&buf, op.NewName)
	genWriteOptSpan(&buf, op.NewSpan)
	genWriteOptHash32(&buf, op.NewHash)
	genWriteOptHash32(&buf, op.NewSigHash)
	genWriteOptHash32(&buf, op.OldHash)
	return buf.Bytes()
}

func genOpsHash(ops []Op) [32]byte {
	sorted := make([]Op, len(ops))
	copy(sorted, ops)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].AtomID < sorted[j].AtomID })
	var buf bytes.Buffer
	buf.WriteString(genDomainOps)
	genWriteU32LE(&buf, uint32(len(sorted)))
	for _, op := range sorted {
		buf.Write(genOpBytes(op))
	}
	return sshlib.SHA256Sum(buf.Bytes())
}

func genSigMsg(c *Change) ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteString(genDomainChange)
	buf.Write(mustUUID(c.ID))
	genWriteOptUUID(&buf, c.Parent)
	buf.Write(mustUUID(c.Stream))
	genWriteU64LE(&buf, uint64(c.TS))
	author, _ := hexDec(c.Author)
	buf.Write(author)
	genWriteStr(&buf, c.Message)
	genWriteOptUUID(&buf, c.Merged)
	oh := genOpsHash(c.Ops)
	buf.Write(oh[:])
	return buf.Bytes(), nil
}

func mustUUID(s string) []byte {
	var out [16]byte
	h := strings.ReplaceAll(s, "-", "")
	b, err := hexDec(h)
	if err != nil || len(b) != 16 {
		panic("bad uuid")
	}
	copy(out[:], b)
	return out[:]
}

func hexDec(s string) ([]byte, error) {
	return hex.DecodeString(s)
}
