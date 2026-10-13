package vi

import (
	"bytes"
	"flag"
	"fmt"
	"go/format"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"
	"unsafe"
)

var updateSyscallSlots = flag.Bool("update-syscall-slots", false, "regenerate slots_gen.go from the kernel ABI")

// Run: go generate ./vi. Use go test -count=1 ./vi/ for kernel-only changes:
// Go's result cache does not track inputs outside this Go module.
// Keep the generator in the host test, not in a guest binary or a new tool.
func TestSyscallSlotsMirrorKernel(t *testing.T) {
	path := filepath.Join("..", "..", "..", "kernel", "src", "syscall_abi.zig")
	source, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	want, err := generateSyscallSlots(source)
	if err != nil {
		t.Fatal(err)
	}
	if *updateSyscallSlots {
		if err := os.WriteFile("slots_gen.go", want, 0644); err != nil {
			t.Fatal(err)
		}
		return
	}
	got, err := os.ReadFile("slots_gen.go")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("slots_gen.go disagrees with kernel/src/syscall_abi.zig; run go generate ./vi")
	}
	for index, slot := range SyscallSlots {
		if slot.Number != uintptr(index) {
			t.Fatalf("%s constant=%d, kernel=%d", slot.Name, slot.Number, index)
		}
	}
}

func TestObserveWireLayoutsAndStubGateways(t *testing.T) {
	for name, pair := range map[string][2]uintptr{
		"trace record":       {unsafe.Sizeof(TraceRecord{}), TraceRecordBytes},
		"trace config":       {unsafe.Sizeof(TraceConfig{}), 88},
		"trace exec request": {unsafe.Sizeof(TraceExecRequest{}), 32},
		"sample record":      {unsafe.Sizeof(SampleRecord{}), ProfileRecordBytes},
		"profile config":     {unsafe.Sizeof(ProfileConfig{}), 72},
		"memstat record":     {unsafe.Sizeof(MemstatRecord{}), MemstatRecordBytes},
		"read header":        {unsafe.Sizeof(ObserveReadHeader{}), ObserveReadHeaderBytes},
	} {
		if pair[0] != pair[1] {
			t.Fatalf("%s: bytes=%d, want=%d", name, pair[0], pair[1])
		}
	}
	old := SetSyscallHookForTest(nil)
	defer SetSyscallHookForTest(old)
	for _, call := range []func() int64{
		func() int64 { return Trace(TraceArm, 0, nil) },
		func() int64 { return Trace(99, 99, []byte{1}) },
		func() int64 { return Profile(ProfileArm, 0, nil) },
		func() int64 { return Profile(99, 99, []byte{1}) },
		func() int64 { return Memstat(0, nil) },
		func() int64 { return Memstat(99, []byte{1}) },
	} {
		if got := call(); got != -ErrENOSYS {
			t.Fatalf("unimplemented observation returned %d, want -ENOSYS", got)
		}
	}
}

func TestObserveGatewaysMarshalFrozenArguments(t *testing.T) {
	var got [5]uintptr
	old := SetSyscallHookForTest(func(num, a0, a1, a2, a3 uintptr) int64 {
		got = [5]uintptr{num, a0, a1, a2, a3}
		return -ErrENOSYS
	})
	defer SetSyscallHookForTest(old)
	buffer := make([]byte, 240)
	ptr := uintptr(unsafe.Pointer(&buffer[0]))
	Trace(TraceRead, 17, buffer)
	if want := ([5]uintptr{SlotTrace, TraceRead, 17, ptr, 240}); got != want {
		t.Fatalf("trace args=%v, want=%v", got, want)
	}
	Profile(ProfileRead, 18, buffer)
	if want := ([5]uintptr{SlotProfile, ProfileRead, 18, ptr, 240}); got != want {
		t.Fatalf("profile args=%v, want=%v", got, want)
	}
	Memstat(19, buffer)
	if want := ([5]uintptr{SlotMemstat, 19, ptr, 240, 0}); got != want {
		t.Fatalf("memstat args=%v, want=%v", got, want)
	}
}

func generateSyscallSlots(source []byte) ([]byte, error) {
	rows := regexp.MustCompile(`(?m)^\s*row\((\d+), "(sys_[a-z0-9_]+)", \.\{(.*?)\}\),$`).FindAllSubmatch(source, -1)
	if len(rows) != 88 {
		return nil, fmt.Errorf("kernel ABI has %d rows, want frozen slots 0–87", len(rows))
	}
	// These predate this generated mirror and live outside M94a's Touches.
	existing := map[string]bool{"SlotTimeSet": true, "SlotWinSetTitle": true, "SlotWmctl": true}
	vi, err := os.ReadFile("vi.go")
	if err != nil {
		return nil, err
	}
	for _, m := range regexp.MustCompile(`\b(Slot\w+)\s+uintptr\s*=`).FindAllSubmatch(vi, -1) {
		existing[string(m[1])] = true
	}
	var out bytes.Buffer
	fmt.Fprintln(&out, "// Code generated from kernel/src/syscall_abi.zig by go generate ./vi; DO NOT EDIT.")
	fmt.Fprintln(&out, "package vi\n\nconst (")
	for index, row := range rows {
		number, _ := strconv.Atoi(string(row[1]))
		if number != index {
			return nil, fmt.Errorf("kernel ABI row %d has number %d", index, number)
		}
		if name := goSlotName(string(row[2])); !existing[name] {
			fmt.Fprintf(&out, "%s uintptr = %d\n", name, number)
		}
	}
	fmt.Fprintln(&out, ")")
	fmt.Fprintln(&out, `
type SyscallArgKind uint8
const (
	ArgInt SyscallArgKind = iota
	ArgFD
	ArgPID
	ArgPtr
	ArgString
	ArgFlags
	ArgRedacted
)
type SyscallArg struct {
	Kind SyscallArgKind
	LengthArg uint8
	LengthMask uint64
}
type SyscallSlot struct {
	Number uintptr
	Name string
	ArgCount uint8
	Args [6]SyscallArg
}
type SyscallVariant struct {
	Number uintptr
	Selector uint8
	Op uint64
	ArgCount uint8
	Args [6]SyscallArg
}
var SyscallSlots = [...]SyscallSlot{`)
	for _, row := range rows {
		args, count, err := goArgs(string(row[3]))
		if err != nil {
			return nil, err
		}
		fmt.Fprintf(&out, "{%s, %q, %d, [6]SyscallArg{%s}},\n", goSlotName(string(row[2])), row[2], count, args)
	}
	fmt.Fprintln(&out, "}\n\nvar SyscallVariants = [...]SyscallVariant{")
	variants := regexp.MustCompile(`(?m)^\s*variant\((\d+), (\d+), (\d+), \.\{(.*?)\}\),$`).FindAllSubmatch(source, -1)
	for _, row := range variants {
		args, count, err := goArgs(string(row[4]))
		if err != nil {
			return nil, err
		}
		fmt.Fprintf(&out, "{%s, %s, %s, %d, [6]SyscallArg{%s}},\n", row[1], row[2], row[3], count, args)
	}
	fmt.Fprintln(&out, "}")
	return format.Source(out.Bytes())
}

func goSlotName(name string) string {
	words := strings.Split(strings.TrimPrefix(name, "sys_"), "_")
	acronyms := map[string]string{"ipc": "IPC", "udp": "UDP", "tcp": "TCP", "getrandom": "GetRandom"}
	for i, word := range words {
		if acronym, ok := acronyms[word]; ok {
			words[i] = acronym
		} else {
			words[i] = strings.ToUpper(word[:1]) + word[1:]
		}
	}
	return "Slot" + strings.Join(words, "")
}

func goArgs(text string) (string, int, error) {
	var out strings.Builder
	kinds := map[string]string{".int": "ArgInt", ".fd": "ArgFD", ".pid": "ArgPID", ".ptr": "ArgPtr", ".flags": "ArgFlags", ".redacted": "ArgRedacted"}
	count := 0
	for _, token := range strings.Split(text, ",") {
		token = strings.TrimSpace(token)
		if token == "" {
			continue
		}
		if kind, ok := kinds[token]; ok {
			fmt.Fprintf(&out, "{Kind: %s},", kind)
		} else {
			m := regexp.MustCompile(`^str(_flags)?\(([0-5])\)$`).FindStringSubmatch(token)
			if m == nil {
				return "", 0, fmt.Errorf("unknown kernel arg kind %q", token)
			}
			mask := "^uint64(0)"
			if m[1] != "" {
				mask = "uint64(1)<<63-1"
			}
			fmt.Fprintf(&out, "{Kind: ArgString, LengthArg: %s, LengthMask: %s},", m[2], mask)
		}
		count++
	}
	if count > 6 {
		return "", 0, fmt.Errorf("too many kernel args: %d", count)
	}
	return out.String(), count, nil
}
