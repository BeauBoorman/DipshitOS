package vsys

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"testing"
)

// fakeKern installs an injected syscall for the duration of a test.
func fakeKern(t *testing.T, fn func(num uintptr, a0, a1, a2, a3 uintptr) int64) {
	t.Helper()
	prev := syscallFn
	syscallFn = fn
	t.Cleanup(func() { syscallFn = prev })
}

func TestValidatePath_RejectsEmpty(t *testing.T) {
	if err := ValidatePath(""); err != ErrInvalidPath {
		t.Fatalf("ValidatePath(\"\") = %v, want ErrInvalidPath", err)
	}
}

func TestValidatePath_RejectsTraversalComponent(t *testing.T) {
	for _, bad := range []string{"..", "../x", "a/../b", "/host/..", "x/.."} {
		if err := ValidatePath(bad); err != ErrInvalidPath {
			t.Fatalf("ValidatePath(%q) = %v, want ErrInvalidPath", bad, err)
		}
	}
	// "a..b" is a legal FILE NAME, not a traversal component.
	for _, ok := range []string{"a..b", "/host/FM/KNOWN.TXT", "..hidden"} {
		if err := ValidatePath(ok); err != nil {
			t.Fatalf("ValidatePath(%q) = %v, want nil", ok, err)
		}
	}
}

func TestValidatePath_RejectsOverlong(t *testing.T) {
	short := strings.Repeat("a", MaxPathLen)
	if err := ValidatePath(short); err != nil {
		t.Fatalf("ValidatePath(64 bytes) = %v, want nil", err)
	}
	long := strings.Repeat("a", MaxPathLen+1)
	if err := ValidatePath(long); err != ErrNameTooLong {
		t.Fatalf("ValidatePath(65 bytes) = %v, want ErrNameTooLong", err)
	}
}

func TestOpen_InvalidPathDoesNotSyscall(t *testing.T) {
	called := false
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		called = true
		return -ErrEINVAL
	})
	if _, err := Open("", 0); err != ErrInvalidPath {
		t.Fatalf("Open(\"\") err = %v, want ErrInvalidPath", err)
	}
	if called {
		t.Fatal("Open must reject an invalid path before any syscall")
	}
}

func TestOpen_MapsKernelErrno(t *testing.T) {
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num != SlotFileOpen {
			t.Fatalf("unexpected slot %d", num)
		}
		return -ErrENOENT
	})
	_, err := Open("/host/FM/MISSING.TXT", 0)
	var e Errno
	if !errors.As(err, &e) || int64(e) != ErrENOENT {
		t.Fatalf("Open err = %v, want Errno(ENOENT)", err)
	}
}

func TestFile_ReadAfterCloseIsEBADF(t *testing.T) {
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 5 })
	f, err := Open("/host/FM/KNOWN.TXT", ModeRead)
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := f.Read(make([]byte, 8)); !errors.Is(err, error(Errno(ErrEBADF))) {
		t.Fatalf("Read after Close = %v, want Errno(EBADF)", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("second Close must be a local no-op, got %v", err)
	}
}

func TestReadFile_AccumulatesChunksUntilZero(t *testing.T) {
	chunks := []int64{7, 6, 0}
	i := 0
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotFileOpen:
			return 3
		case SlotFileClose:
			return 0
		case SlotFileRead:
			n := chunks[i]
			if i < len(chunks)-1 {
				i++
			}
			return n
		}
		return -ErrEINVAL
	})
	got, err := ReadFile("/host/FM/KNOWN.TXT")
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if len(got) != 13 {
		t.Fatalf("ReadFile len = %d, want 13 (7+6+0)", len(got))
	}
}

func TestFile_WriteOverlimitIsENOSPC(t *testing.T) {
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 { return 1 })
	f, _ := Open("/host/FM/OUT.TXT", ModeWrite)
	if _, err := f.Write(make([]byte, MaxFileIOBytes+1)); !errors.Is(err, error(Errno(ErrENOSPC))) {
		t.Fatalf("Write(MaxFileIOBytes+1) = %v, want Errno(ENOSPC)", err)
	}
}

func TestFile_WriteMapsKernelErrno(t *testing.T) {
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotFileWrite {
			return -ErrEACCES
		}
		return 1
	})
	f, _ := Open("/host/FM/OUT.TXT", ModeWrite)
	if _, err := f.Write([]byte("x")); !errors.Is(err, error(Errno(ErrEACCES))) {
		t.Fatalf("Write = %v, want Errno(EACCES)", err)
	}
}

// TestOpen_ConcurrentOpensShareNoStaging hammers Open from many goroutines
// with distinct paths through the injected kernel. Issue #2519 (sibling of
// #2495/#2518): the old package-global virPathStaging had no serialization
// between the stage-copy and the svc, so two Ms could interleave them and
// the kernel would validate a spliced path — `go test -race` flags the old
// code's concurrent writes to the shared buffer; per-call stack staging
// has no shared state to race on.
func TestOpen_ConcurrentOpensShareNoStaging(t *testing.T) {
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		switch num {
		case SlotFileOpen:
			return 3
		case SlotFileClose:
			return 0
		}
		return -ErrEINVAL
	})
	const goroutines = 32
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			path := fmt.Sprintf("/host/FM/F%02d.TXT", g)
			for i := 0; i < 64; i++ {
				f, err := Open(path, ModeRead)
				if err != nil {
					t.Errorf("Open(%q) = %v", path, err)
					return
				}
				if err := f.Close(); err != nil {
					t.Errorf("Close(%q) = %v", path, err)
					return
				}
			}
		}(g)
	}
	wg.Wait()
}

func TestOpen_ReadFileAsksForModeRead(t *testing.T) {
	var gotFlags uintptr
	fakeKern(t, func(num uintptr, a0, a1, a2, a3 uintptr) int64 {
		if num == SlotFileOpen {
			gotFlags = a2
			return -ErrENOENT
		}
		return 0
	})
	_, _ = ReadFile("/host/GONET.SHARE")
	if gotFlags != uintptr(ModeRead) {
		t.Fatalf("Open flags = %#x, want ModeRead (%#x) — flags 0 is EINVAL on target", gotFlags, ModeRead)
	}
}
