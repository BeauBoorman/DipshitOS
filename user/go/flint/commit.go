package main

import (
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

// cmdLog implements `flint log [--stream=<name>] [--ws=<name>]`.
func cmdLog(fs FS, root string, args []string) error {
	var streamFlag, wsFlag string
	for _, a := range args {
		switch {
		case strings.HasPrefix(a, "--stream="):
			streamFlag = a[len("--stream="):]
		case strings.HasPrefix(a, "--ws="):
			wsFlag = a[len("--ws="):]
		default:
			return refuse("usage", "")
		}
	}

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
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

	_, changes, err := LoadStream(fs, root, streamID)
	if err != nil {
		return err
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

// cmdVerify implements `flint verify <id> | --all | --file=<log>`.
func cmdVerify(fs FS, root string, args []string) int {
	if len(args) != 1 || args[0] == "" {
		return runErr(refuse("usage", ""))
	}
	arg := args[0]

	if strings.HasPrefix(arg, "--file=") {
		logPath := cleanMemPath(arg[len("--file="):])
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
		return verifyChangeList(changes)
	}

	if arg == "--all" {
		idx, err := LoadStoreIndex(fs, root)
		if err != nil {
			return runErr(err)
		}
		changes, err := LoadAllStreamChanges(fs, root, idx)
		if err != nil {
			return runErr(err)
		}
		return verifyChangeList(changes)
	}

	if strings.HasPrefix(arg, "-") {
		return runErr(refuse("usage", ""))
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
		if c.ID == arg {
			return verifyChangeList([]Change{c})
		}
	}
	return runErr(refuse("change_missing", arg))
}

func verifyChangeList(changes []Change) int {
	rc := 0
	for i := range changes {
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
