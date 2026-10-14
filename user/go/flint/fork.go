package main

// cmdFork implements `flint fork <from> <new>`.
func cmdFork(fs FS, root string, uuidGen *UUIDGen, args []string) error {
	if len(args) != 2 || args[0] == "" || !validWorkspaceName(args[1]) {
		return refuse("usage", "")
	}
	fromName := args[0]
	newName := args[1]

	idx, err := LoadStoreIndex(fs, root)
	if err != nil {
		return err
	}
	fromSt, ok := idx.StreamsByName[fromName]
	if !ok {
		return refuse("stream_missing", fromName)
	}
	fromSt, _, err = LoadStream(fs, root, fromSt.ID)
	if err != nil {
		return err
	}
	if _, exists := idx.StreamsByName[newName]; exists {
		return refuse("stream_exists", newName)
	}
	if fromSt.Head == nil || *fromSt.Head == "" {
		return refuse("fork_empty", "")
	}

	createdMs, err := uuidGen.NowMs()
	if err != nil {
		return err
	}
	newID, err := uuidGen.New()
	if err != nil {
		return err
	}

	if err := ensureDirAll(fs, streamsDir(root)); err != nil {
		return err
	}

	head := *fromSt.Head
	st := Stream{
		ID:      newID,
		Name:    newName,
		Head:    &head,
		Created: createdMs,
		ForkedFrom: &ForkOrigin{
			Stream: fromSt.ID,
			Change: head,
		},
	}
	if err := WriteStreamRecord(fs, root, &st); err != nil {
		return err
	}

	consoleFn("flint: fork ok stream=" + newName + " head=" + head)
	return nil
}
