package main

import (
	"sort"
	"strings"
	"unicode/utf8"

	"virelai/sshlib"
	"virelai/vi"
)

// beforeCommitAppend is an optional test hook invoked after the Change is
// built and signed, immediately before AppendStreamChange re-reads the Stream
// record for stale_head.
var beforeCommitAppend func()

func validateCommitMessage(msg string) error {
	if len(msg) < 1 || len(msg) > 512 || !utf8.ValidString(msg) {
		return refuse("message_invalid", "")
	}
	return nil
}

// cmdCommit implements `flint commit [--ws=<name>] -m <msg>`.
func cmdCommit(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	var wsFlag string
	var msg string
	hasMsg := false
	for i := 0; i < len(args); i++ {
		a := args[i]
		switch {
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		case a == "-m":
			if i+1 >= len(args) {
				return refuse("usage", "")
			}
			i++
			msg = args[i]
			hasMsg = true
		case strings.HasPrefix(a, "-m="):
			msg = a[len("-m="):]
			hasMsg = true
		case strings.HasPrefix(a, "--message="):
			msg = a[len("--message="):]
			hasMsg = true
		default:
			return refuse("usage", "")
		}
	}
	if !hasMsg {
		return refuse("usage", "")
	}
	if err := validateCommitMessage(msg); err != nil {
		return err
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	ws, err := resolveWorkspace(fs, idx, wsFlag, nil)
	if err != nil {
		return err
	}
	stage, err := LoadWorkspaceStage(fs, root, ws.Name)
	if err != nil {
		return err
	}
	if len(stage) == 0 {
		return refuse("nothing_to_commit", "")
	}
	if idx.ChangeCount+1 > MaxChanges {
		return refuse("store_too_large", "changes")
	}

	// ADR 0049 / #2252: load the signing key BEFORE any write so a missing
	// or malformed secret leaves the store byte-identical.
	seed, err := loadSeed()
	if err != nil {
		return err
	}
	defer sshlib.Wipe(seed[:])

	st, _, err := LoadStream(fs, root, ws.Stream)
	if err != nil {
		return err
	}
	expectedHead := copyStrPtr(st.Head)

	ts, err := uuidGen.NowMs()
	if err != nil {
		return err
	}
	changeID, err := uuidGen.New()
	if err != nil {
		return err
	}

	c := Change{
		ID:      changeID,
		Parent:  copyStrPtr(expectedHead),
		Stream:  st.ID,
		TS:      ts,
		Message: msg,
		Ops:     stage,
		Merged:  nil,
	}
	if err := signChangeWithSeed(&c, seed[:]); err != nil {
		return err
	}

	if beforeCommitAppend != nil {
		beforeCommitAppend()
	}

	// Commit order: (1) append Change + FileSync, (2) rewrite Stream record,
	// (3) remove STAGE.jsonl.
	if _, err := AppendStreamChange(fs, root, st.ID, expectedHead, c); err != nil {
		return err
	}
	if err := fs.Remove(workspaceStagePath(root, ws.Name)); err != nil {
		return err
	}

	parentStr := "none"
	if c.Parent != nil {
		parentStr = *c.Parent
	}
	consoleFn("flint: commit ok id=" + c.ID +
		" ops=" + vi.Itoa64(int64(len(c.Ops))) +
		" parent=" + parentStr)
	return nil
}

func firstMessageLine(msg string) string {
	if i := strings.IndexByte(msg, '\n'); i >= 0 {
		msg = msg[:i]
	}
	return strings.TrimSuffix(msg, "\r")
}

// cmdLog implements `flint log [--stream=<name>] [--ws=<name>] [--graph]
// [--all]`. `--graph` renders the Change DAG as ASCII lanes (M138c #2777);
// `--all` seeds the walk at every stream head instead of the resolved one.
func cmdLog(fs FS, root string, args []string) error {
	var streamFlag, wsFlag string
	graph, all := false, false
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		case a == "--graph":
			graph = true
		case a == "--all":
			all = true
		default:
			return refuse("usage", "")
		}
	}
	if all && streamFlag != "" {
		return refuse("usage", "")
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}

	if all {
		ids := make([]string, 0, len(idx.StreamsByID))
		for id := range idx.StreamsByID {
			ids = append(ids, id)
		}
		sort.Strings(ids)
		var seeds []string
		for _, id := range ids {
			st, _, err := LoadStream(fs, root, id)
			if err != nil {
				return err
			}
			if st.Head != nil && *st.Head != "" {
				seeds = append(seeds, *st.Head)
			}
		}
		return logGraph(fs, root, idx, seeds)
	}

	var streamID string
	if streamFlag != "" {
		st, ok := idx.StreamsByName[streamFlag]
		if !ok {
			return refuse("stream_missing", streamFlag)
		}
		streamID = st.ID
	} else {
		ws, err := resolveWorkspace(fs, idx, wsFlag, nil)
		if err != nil {
			return err
		}
		streamID = ws.Stream
	}

	st, changes, err := LoadStream(fs, root, streamID)
	if err != nil {
		return err
	}
	if graph {
		var seeds []string
		if st.Head != nil && *st.Head != "" {
			seeds = append(seeds, *st.Head)
		}
		return logGraph(fs, root, idx, seeds)
	}

	const logCap = 64
	printed := 0
	for i := len(changes) - 1; i >= 0 && printed < logCap; i-- {
		c := changes[i]
		parentStr := "none"
		if c.Parent != nil && *c.Parent != "" {
			parentStr = *c.Parent
		}
		authorPrefix := c.Author
		if len(authorPrefix) > 8 {
			authorPrefix = authorPrefix[:8]
		}
		consoleFn("flint: change " + c.ID +
			" parent=" + parentStr +
			" ops=" + vi.Itoa64(int64(len(c.Ops))) +
			" author=" + authorPrefix +
			" msg=" + firstMessageLine(c.Message))
		printed++
	}
	return nil
}

// cmdVerify implements `flint verify <id> | --all [--trusted]
// [--expect=<stream>:<sha256>] | --file=<log>` locally, or `--remote`
// (with optional --remote=<url>/--stream=<s>) against the publisher
// keyring — the M101b verify-before-materialize gate.
//
// --trusted adds the publisher-keyring leg to the local gate: every
// verified Change's author key must be pinned in TRUSTED.TXT and not
// revoked — the same CheckAuthor clone/pull/`verify --remote` run on
// fetched bytes. STORE uses `verify --all --trusted` before
// materialization so a Change a share writer appended to the local
// replica (self-signed by an arbitrary key) is refused instead of
// folded. --expect=<stream>:<sha256> binds one stream's log bytes:
// streams/<id>.jsonl is re-read after the verify pass, its sha256
// printed for evidence, and a difference from the caller-hashed bytes
// refuses log_changed — closing the window between the log the gate
// verified and the log the caller folds.
func cmdVerify(fs FS, root string, args []string) int {
	for _, a := range args {
		if a == "--remote" || strings.HasPrefix(a, "--remote=") ||
			strings.HasPrefix(a, "--stream=") {
			return cmdVerifyRemote(fs, root, args)
		}
	}
	var sel, expect string
	trusted := false
	for _, a := range args {
		switch {
		case a == "--all" || strings.HasPrefix(a, "--file="):
			if sel != "" {
				return runErr(refuse("usage", ""))
			}
			sel = a
		case a == "--trusted":
			trusted = true
		case strings.HasPrefix(a, "--expect="):
			if expect != "" {
				return runErr(refuse("usage", ""))
			}
			expect = a[len("--expect="):]
		case strings.HasPrefix(a, "-"):
			return runErr(refuse("usage", ""))
		default:
			if sel != "" {
				return runErr(refuse("usage", ""))
			}
			sel = a
		}
	}
	if sel == "" || (expect != "" && sel != "--all") {
		return runErr(refuse("usage", ""))
	}

	var kr *Keyring
	if trusted {
		var err error
		kr, err = LoadKeyring(fs, root)
		if err != nil {
			return runErr(err)
		}
	}

	if strings.HasPrefix(sel, "--file=") {
		logPath := cleanMemPath(sel[len("--file="):])
		if logPath == "" {
			return runErr(refuse("usage", ""))
		}
		b, err := fs.ReadFile(logPath, MaxFileReadBytes)
		if err != nil {
			return runErr(err)
		}
		lines, err := ReadJSONLLines(b)
		if err != nil {
			return runErr(err)
		}
		if len(lines) == 0 {
			return runErr(refuse("change_malformed", ""))
		}
		changes := make([]Change, 0, len(lines))
		for _, line := range lines {
			c, err := ParseChange(line)
			if err != nil {
				return runErr(err)
			}
			changes = append(changes, c)
		}
		return verifyChangeList(changes, kr)
	}

	if sel == "--all" {
		idx, err := LoadStoreIndex(fs, root)
		if err != nil {
			return runErr(err)
		}
		changes, err := LoadAllStreamChanges(fs, root, idx)
		if err != nil {
			return runErr(err)
		}
		if rc := verifyChangeList(changes, kr); rc != 0 {
			return rc
		}
		if expect != "" {
			return checkExpectedLog(fs, root, expect)
		}
		return 0
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return runErr(err)
	}
	changes, err := LoadAllStreamChanges(fs, root, idx)
	if err != nil {
		return runErr(err)
	}
	for _, c := range changes {
		if c.ID == sel {
			return verifyChangeList([]Change{c}, kr)
		}
	}
	return runErr(refuse("change_missing", sel))
}

// checkExpectedLog re-reads streams/<id>.jsonl and binds it to the
// caller's hash: the printed sha256 is evidence of the log this gate
// verified, and a mismatch refuses log_changed so the caller's fold
// provably covers the same bytes.
func checkExpectedLog(fs FS, root, expect string) int {
	sid, wantHex, ok := strings.Cut(expect, ":")
	if !ok || sid == "" || !isLowerHexN(wantHex, 64) {
		return runErr(refuse("usage", ""))
	}
	p := streamLogPath(root, sid)
	if !fs.Exists(p) {
		return runErr(refuse("log_changed", sid))
	}
	b, err := fs.ReadFile(p, MaxFileReadBytes)
	if err != nil {
		return runErr(err)
	}
	sum := sshlib.SHA256Sum(b)
	got := sshlib.EncodeHex(sum[:])
	consoleFn("flint: log " + sid + " sha256=" + got)
	if got != wantHex {
		return runErr(refuse("log_changed", sid))
	}
	return 0
}

func verifyChangeList(changes []Change, kr *Keyring) int {
	rc := 0
	for i := range changes {
		if kr != nil {
			if err := kr.CheckAuthor(changes[i].Author); err != nil {
				return runErr(err)
			}
		}
		ok, err := VerifyChange(&changes[i])
		if err != nil {
			return runErr(err)
		}
		if ok {
			consoleFn("flint: verify " + changes[i].ID + " sig: verified")
		} else {
			consoleFn("flint: verify " + changes[i].ID + " sig_invalid")
			rc = 1
		}
	}
	return rc
}
