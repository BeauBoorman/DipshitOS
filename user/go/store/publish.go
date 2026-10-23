package store

import (
	"encoding/hex"
	"strconv"
	"strings"

	"virelai/flint/parser"
	"virelai/sshlib"
)

// PublishArgs carries `store publish`'s argv: the two positionals plus
// the flags its own parser (main/main.go) collects — the shared flag
// loop rejects --src/--version/--stream/--row/--summary as unknown, so
// publish is dispatched before it.
type PublishArgs struct {
	Name     string // positional: the release's ELF stem
	ElfPath  string // positional: path to the guest-built ELF
	Src      string // --src=<dir>: the FLINT workspace the manifest lands in
	Version  string // --version=<v>
	Stream   string // --stream=<s>: the release stream (name or id)
	Channel  string // --channel=<dir>: drop directory (default DefaultChannel)
	Row      string // --row=<row>: the schema-v2 APPS.TXT row
	Summary  string // --summary=<s>: optional ADR 0055 ReleaseSummary
	Category string // --category=<c>: optional ADR 0055 ReleaseCategory
}

// Publish implements `store publish <NAME> <elf> --src=<dir> --version=<v>
// --stream=<s> [--channel=<dir>] [--row=<row>] [--summary=<s>]
// [--category=<c>]` — the producer half of the release lane. It renders
// release.go canonically, validates it through the same grammar install
// enforces (round-tripped through parseRelease), writes it into the FLINT
// workspace's release/ dir, execs `FLINT.ELF add` + `commit` so the
// manifest atoms land signed under agent-sign, and only then drops
// release.go and the ELF into <channel>/<stream>/ — the layout install
// fetches. A rendered manifest whose atoms already equal the stream
// head's signed set skips the commit entirely (unchanged): the drop is
// still refreshed, mirroring install's idempotent re-install.
//
// Publishing writes a directory drop only — an http:// channel refuses
// channel_malformed. `FLINT.ELF push` stays the separate, explicit step
// that sends the committed release to a server.
func Publish(fs FS, root string, a PublishArgs) int {
	ConsoleFn("store: publish " + a.Name)

	// The channel is a directory drop; the cleartext relay is fetch-only.
	chDir := strings.TrimSpace(a.Channel)
	if chDir == "" {
		chDir = DefaultChannel
	}
	if strings.Contains(chDir, "://") {
		return runErr(refuse("channel_malformed", a.Channel))
	}
	chDir = cleanMemPath(chDir)

	// Read + hash the ELF: publish_elf_missing names the absent input
	// before any manifest work, and the bound is the same MaxELFBytes
	// install fetches under (an ELF larger than exec_image_max can never
	// launch, so refusing beats shipping it).
	elf, err := fs.ReadFile(a.ElfPath, MaxELFBytes)
	if err != nil {
		if _, ok := err.(*RefuseError); ok {
			return runErr(err) // file_too_large keeps its own name
		}
		return runErr(refuse("publish_elf_missing", a.ElfPath))
	}
	sum := sshlib.SHA256Sum(elf)
	rel := &release{
		Name:        a.Name,
		Version:     a.Version,
		ELFSHA256:   sshlib.EncodeHex(sum[:]),
		ManifestRow: a.Row,
	}
	if rel.ManifestRow == "" {
		rel.ManifestRow = a.Name + ".ELF | " + a.Name + " | g | dock=false"
	}
	// The same validate install runs — publish never writes a manifest
	// install would refuse. The optional consts get parseRelease's
	// present-const grammar gate before they are rendered.
	if err := rel.validate(); err != nil {
		return runErr(err)
	}
	if a.Summary != "" {
		if !validSummary(a.Summary) {
			return runErr(refuse("summary_invalid", "ReleaseSummary"))
		}
		rel.Summary = a.Summary
	}
	if a.Category != "" {
		if !releaseCategories[a.Category] {
			return runErr(refuse("category_unknown", a.Category))
		}
		rel.Category = a.Category
	}

	// Render canonically and round-trip: the file that lands is exactly
	// the file parseRelease certifies.
	src := renderRelease(rel)
	parsed, err := parseRelease(src)
	if err != nil {
		return runErr(err)
	}
	if parsed.Name != rel.Name || parsed.Version != rel.Version ||
		parsed.ELFSHA256 != rel.ELFSHA256 || parsed.ManifestRow != rel.ManifestRow ||
		parsed.Summary != rel.Summary || parsed.Category != rel.Category {
		return runErr(refuse("release_malformed", ""))
	}

	// Resolve the release stream and fold its signed head atoms BEFORE
	// the workspace write: a bad selector refuses without leaving a
	// stray release/release.go behind.
	byName, byID, err := listStreamRecords(fs, root)
	if err != nil {
		return runErr(err)
	}
	id, err := streamID(byName, byID, a.Stream)
	if err != nil {
		return runErr(err)
	}
	st := byID[id]
	// The stream name becomes one channel path component — bound it to
	// the same grammar install's dirChannel enforces on read.
	if err := checkRelPath(st.Name); err != nil {
		return runErr(err)
	}
	logBytes, err := streamLogBytes(fs, root, id)
	if err != nil {
		return runErr(err)
	}
	signed, _, err := headReleaseOps(logBytes, st.Head)
	if err != nil {
		return runErr(err)
	}

	// Write <src>/release/release.go, keeping the previous bytes (or
	// their absence) so a refused commit restores the workspace exactly.
	if !fs.Exists(a.Src) {
		return runErr(refuse("src_missing", a.Src))
	}
	relDir := cleanMemPath(a.Src) + "/release"
	relPath := relDir + "/" + releaseFile
	var prev []byte
	if fs.Exists(relPath) {
		prev, err = fs.ReadFile(relPath, MaxReleaseBytes)
		if err != nil {
			return runErr(err)
		}
	}
	if err := ensureDirAll(fs, relDir); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(relPath, src); err != nil {
		return runErr(err)
	}
	restore := func() {
		if prev != nil {
			_ = fs.WriteFileSafe(relPath, prev)
		} else {
			_ = fs.Remove(relPath)
		}
	}

	// Commit. `add` stages the workspace, `commit` signs with agent-sign
	// inside FLINT.ELF — STORE never holds a key. Atoms already equal to
	// the stream head's signed release set make the commit a no-op, so
	// publish skips it and reports unchanged instead of minting an
	// empty Change.
	atoms, err := releaseAtomSet(src)
	if err != nil {
		restore()
		return runErr(err)
	}
	unchanged := len(atoms) == len(signed)
	if unchanged {
		for k, h := range atoms {
			if signed[k] != h {
				unchanged = false
				break
			}
		}
	}
	if !unchanged {
		if err := flint("add", a.Src); err != nil {
			restore()
			return runErr(err)
		}
		if err := flint("commit", "-m", "release "+rel.Name+" "+rel.Version); err != nil {
			restore()
			return runErr(err)
		}
	}

	// Drop — only after the commit landed (or the head already covered
	// it). release.go is byte-identical to the committed file so a
	// consumer's atom-for-atom verifyRelease passes against the signed
	// head set.
	dropDir := chDir + "/" + st.Name
	if err := ensureDirAll(fs, dropDir); err != nil {
		return runErr(err)
	}
	if err := fs.WriteFileSafe(dropDir+"/"+releaseFile, src); err != nil {
		return runErr(err)
	}
	bin := rel.Name + ".ELF"
	if err := fs.WriteFileSafe(dropDir+"/"+bin, elf); err != nil {
		return runErr(err)
	}
	line := "store: published " + rel.Name + " " + rel.Version +
		" sha256=" + rel.ELFSHA256 + " drop=" + dropDir
	if unchanged {
		line += " unchanged"
	}
	ConsoleFn(line)
	return 0
}

// renderRelease renders the canonical release.go — `package release`,
// the four required consts, then each optional const the publisher gave
// — the same byte shape testdata/release.go carries so the produced
// manifest and the pinned fixture hash identically.
func renderRelease(r *release) []byte {
	var b strings.Builder
	b.WriteString("package release\n\n")
	emit := func(name, val string) {
		b.WriteString("const " + name + " = " + strconv.Quote(val) + "\n")
	}
	emit("ReleaseName", r.Name)
	emit("ReleaseVersion", r.Version)
	emit("ReleaseELFSHA256", r.ELFSHA256)
	emit("ReleaseManifestRow", r.ManifestRow)
	if r.Summary != "" {
		emit("ReleaseSummary", r.Summary)
	}
	if r.Category != "" {
		emit("ReleaseCategory", r.Category)
	}
	return []byte(b.String())
}

// releaseAtomSet parses src's atoms into the (kind, qname) -> hash map
// headReleaseOps produces — the comparison key for publish's unchanged
// fold. The path is the src-relative name `flint add` commits under.
func releaseAtomSet(src []byte) (map[atomKey]string, error) {
	const relPath = "release/" + releaseFile
	p, ok := parser.ForPath(relPath)
	if !ok {
		return nil, refuse("release_malformed", "")
	}
	atoms, err := p.Parse(relPath, src)
	if err != nil {
		return nil, refuse("release_malformed", "")
	}
	out := make(map[atomKey]string, len(atoms))
	for _, a := range atoms {
		out[atomKey{a.Kind, a.Name}] = hex.EncodeToString(a.Hash[:])
	}
	return out, nil
}
