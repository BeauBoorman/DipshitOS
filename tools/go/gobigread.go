// Issue #2354 probe fixture: a guest read of a MULTI-MEGABYTE share file
// through the std port's growing-buffer shapes — the shapes every other
// big-read fixture avoids (GOREAD/GOSYSCALL hash a fixed 2-4 KiB buffer,
// which populates a handful of pages once). os.ReadFile's destination grows
// across the whole file, so every 4 KiB of it is demand-populated by the
// kernel's copy_out resolver — the same path an in-guest cmd/link archive
// read takes through the port's shadow pull.
//
// Phase 1 reads the whole file sequentially into a growing slice
// (os.ReadFile). Phase 2 re-opens and issues a deep ReadAt, which the port
// answers by pulling the file forward through its shadow — the archive
// reader's access pattern — then a backward ReadAt served from the shadow.
package main

import (
	"fmt"
	"os"
)

func fail(what string, err error) {
	fmt.Println("gobigread: FAIL", what, err)
	os.Exit(1)
}

func fnv(b []byte) uint64 {
	var h uint64 = 0xcbf29ce484222325
	for _, c := range b {
		h ^= uint64(c)
		h *= 0x100000001b3
	}
	return h
}

func main() {
	path := "/host/BIGREAD.BIN"
	if len(os.Args) > 1 {
		path = os.Args[1]
	}
	st, err := os.Stat(path)
	if err != nil {
		fail("stat", err)
	}
	data, err := os.ReadFile(path)
	if err != nil {
		fail("readfile", err)
	}
	fmt.Printf("gobigread: readfile bytes %d fnv 0x%016x\n", len(data), fnv(data))
	if int64(len(data)) != st.Size() {
		fmt.Println("gobigread: FAIL short readfile", len(data), "!=", st.Size())
		os.Exit(1)
	}

	f, err := os.Open(path)
	if err != nil {
		fail("open", err)
	}
	defer f.Close()
	buf := make([]byte, 4096)
	deep := st.Size() - 4096
	if deep < 0 {
		deep = 0
	}
	n, err := f.ReadAt(buf, deep)
	if err != nil {
		fail("readat-deep", err)
	}
	if int64(n) != 4096 || fnv(buf) != fnv(data[deep:]) {
		fmt.Println("gobigread: FAIL deep tail mismatch n=", n)
		os.Exit(1)
	}
	// Backward read: must come from the retained shadow, not the device.
	mid := st.Size() / 2 &^ 4095
	n, err = f.ReadAt(buf, mid)
	if err != nil {
		fail("readat-mid", err)
	}
	if int64(n) != 4096 || fnv(buf) != fnv(data[mid:mid+4096]) {
		fmt.Println("gobigread: FAIL mid mismatch n=", n)
		os.Exit(1)
	}
	fmt.Println("gobigread: readat deep+mid ok")
	fmt.Println("gobigread: BIGREAD OK")
}
