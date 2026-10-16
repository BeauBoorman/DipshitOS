package main

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
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
// The canonical-bytes port below mirrors user/go/flint/change.go +
// store.go (sigMsg / opsHash / opBytes / sortOps). Keep them in
// lockstep: a drifted generator mints a change that fails `verify`.

const (
	genDomainChange = "FLINT-CHANGE/1\x00"
	genDomainOps    = "FLINT-OPS/1\x00"
	genStreamID     = "0199de2d-dc00-7000-8000-00000000b010" // `rel`
	genChangeID     = "0199de2d-dc00-7000-8000-00000000c001"
	genSeedFile     = "../flint/testdata/sig/seed.hex"
)

var genAtomIDs = []string{
	"0199de2d-dc00-7000-8000-00000000d001",
	"0199de2d-dc00-7000-8000-00000000d002",
	"0199de2d-dc00-7000-8000-00000000d003",
	"0199de2d-dc00-7000-8000-00000000d004",
}

func TestGenReleaseFixture(t *testing.T) {
	if os.Getenv("STORE_GEN_FIXTURE") == "" {
		t.Skip("fixture generation is env-gated (the gate setup hook sets STORE_GEN_FIXTURE)")
	}
	elfPath := os.Getenv("STORE_FIXTURE_ELF")
	if elfPath == "" {
		elfPath = filepath.Join("..", "..", "..", ".build", "go", "GOHELLO.ELF")
	}
	elf, err := os.ReadFile(elfPath)
	if err != nil {
		t.Fatalf("read ELF %s: %v", elfPath, err)
	}
	sum := sshlib.SHA256Sum(elf)
	relText := genReleaseGo(sshlib.EncodeHex(sum[:]))

	// Parse the manifest through the real parser — the atom hashes the
	// ops carry are exactly what verifyRelease recomputes consumer-side.
	p, ok := parser.ForPath("release.go")
	if !ok {
		t.Fatal("no parser for release.go")
	}
	atoms, err := p.Parse("release.go", []byte(relText))
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(atoms) != 4 {
		t.Fatalf("expected 4 release atoms, got %d", len(atoms))
	}

	// Build the ops (atom ids fixed so the fixture is stable text; ops
	// must sort by atom id — sortOps mirrors flint's comparator).
	ops := make([]Op, 0, len(atoms))
	for i, a := range atoms {
		span := Span{File: a.File, Start: a.Start, End: a.End}
		ops = append(ops, Op{
			Type:       "add",
			AtomID:     genAtomIDs[i],
			Kind:       a.Kind,
			NewName:    a.Name,
			NewSpan:    &span,
			NewHash:    hex.EncodeToString(a.Hash[:]),
			NewSigHash: hex.EncodeToString(a.SigHash[:]),
		})
	}
	sort.Slice(ops, func(i, j int) bool { return ops[i].AtomID < ops[j].AtomID })

	seedHex, err := os.ReadFile(genSeedFile)
	if err != nil {
		t.Fatalf("read signing seed: %v", err)
	}
	seedHexB, err := hexDec(strings.TrimSpace(string(seedHex)))
	if err != nil || len(seedHexB) != 32 {
		t.Fatalf("seed hex")
	}
	var seed [32]byte
	copy(seed[:], seedHexB)
	defer sshlib.Wipe(seed[:])

	pub := sshlib.EdDerivePublic(seed)
	change := Change{
		ID:      genChangeID,
		Stream:  genStreamID,
		TS:      1760000000000,
		Author:  sshlib.EncodeHex(pub[:]),
		Message: "release",
		Ops:     ops,
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
	if err := os.MkdirAll("testdata", 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile("testdata/release-stream.jsonl", append(line, '\n'), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile("testdata/release.go", []byte(relText), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Logf("generated release fixture: change %s, elf sha %s", change.ID, change.Ops[0].NewName)
}

// genReleaseGo renders the release manifest text — the same shape the
// gate stages (DO NOT change the const names: verifyRelease keys on
// them).
func genReleaseGo(elfSHA string) string {
	return "package release\n\n" +
		"const ReleaseName = \"GOHELLO\"\n" +
		"const ReleaseVersion = \"1.0.0\"\n" +
		"const ReleaseELFSHA256 = \"" + elfSHA + "\"\n" +
		"const ReleaseManifestRow = \"GOHELLO.ELF | Go Hello | g | dock=false\"\n"
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

func genOpBytes(op Op) []byte {
	var buf bytes.Buffer
	buf.WriteByte(0x01) // "add"
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
	buf.WriteByte(0x00) // parent: none
	buf.Write(mustUUID(c.Stream))
	genWriteU64LE(&buf, uint64(c.TS))
	author, _ := hexDec(c.Author)
	buf.Write(author)
	genWriteStr(&buf, c.Message)
	buf.WriteByte(0x00) // merged: none
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
