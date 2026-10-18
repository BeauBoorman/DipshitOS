// Sandbox-negative battery fixture (M116e, issue #2471): the grant-row
// write attempts. One binary drives every row-write escape leg — the
// only variables are the spawn principal (plain `exec` = uid_user no
// caps; `exec -u0` = the CAP_PROC_ADMIN half of the seat-or-cap gate)
// and the op argv selects:
//
//	rowwriter batch       the unprivileged set, in-process order:
//	                      slot-89 op-0 read, another app's row write,
//	                      the caller's own row write, the file-ABI
//	                      GRANTS.TXT write — each refused EACCES.
//	rowwriter adminbatch  the CAP_PROC_ADMIN set: a row naming the
//	                      caller (self-name EACCES), a well-formed row
//	                      naming FORGED.ELF bound to a sha it does not
//	                      carry (lands as text; grant_stale refuses it
//	                      at exec), a malformed line (EINVAL), and the
//	                      op-0 read (the gate's admit half).
//
// Every attempt prints one named result —
// `rowwrite: <op> name=<image> target=<t> rc=<errno>` — then a done
// marker naming the batch and a clean exit. The kernel errno is the
// named receipt where the seam emits no `refused:` line.
package main

import (
	"virelai/vi"
	"virelai/vsys"
)

// forgedSHA is a well-formed sha256 that no staged image carries — the
// hash-bound row a cap holder may write but whose bytes can never run.
const forgedSHA = "2222222222222222222222222222222222222222222222222222222222222222"

func rcName(rc int64) string {
	if rc == 0 {
		return "OK"
	}
	switch -rc {
	case vi.ErrEACCES:
		return "EACCES"
	case vi.ErrEINVAL:
		return "EINVAL"
	case vi.ErrENOENT:
		return "ENOENT"
	case vi.ErrENOSPC:
		return "ENOSPC"
	case vi.ErrENXIO:
		return "ENXIO"
	}
	return "errno" + vsys.Itoa64(-rc)
}

func adminWrite(me, target, sha, words string) {
	rc := vi.GrantWriteLine(vi.GrantLine(vi.GrantRow{
		Name:  target,
		SHA:   sha,
		Words: words,
	}))
	vsys.Println("rowwrite: admin write name=" + me + " target=" + target + " rc=" + rcName(rc))
}

func selfWrite(me string) {
	rc := vi.GrantWriteLine(vi.GrantLine(vi.GrantRow{
		Name:  me,
		SHA:   "*",
		Words: "file,net",
	}))
	vsys.Println("rowwrite: self write name=" + me + " target=" + me + " rc=" + rcName(rc))
}

func adminRead(me string) {
	var buf [vi.GrantLineMax]byte
	n, rc := vi.GrantReadRow(0, buf[:])
	if rc < 0 {
		vsys.Println("rowwrite: admin read name=" + me + " rc=" + rcName(rc))
		return
	}
	vsys.Println("rowwrite: admin read name=" + me + " rc=OK n=" + vsys.Itoa64(int64(n)))
}

func fileWrite(me string) {
	h, rc := vi.FileOpen("GRANTS.TXT", vi.ModeWrite)
	if rc < 0 {
		vsys.Println("rowwrite: file write name=" + me + " target=GRANTS.TXT rc=" + rcName(rc))
		return
	}
	// Reached only under a privileged principal: report the honest
	// outcome rather than pretend a refusal.
	_, wrc := vi.FileWrite(uint32(h), []byte("#v1\n"))
	vi.FileClose(uint32(h))
	vsys.Println("rowwrite: file write name=" + me + " target=GRANTS.TXT rc=" + rcName(wrc))
}

func main() {
	args := vi.Args()
	me := "?"
	if len(args) > 0 {
		me = args[0]
	}
	op := "?"
	if len(args) > 1 {
		op = args[1]
	}
	switch op {
	case "batch":
		// The unprivileged set — every leg must answer EACCES.
		adminRead(me)
		adminWrite(me, "VICTIM.ELF", "*", "file,net")
		selfWrite(me) // same refusal: the gate runs first
		fileWrite(me)
	case "adminbatch":
		// The CAP_PROC_ADMIN set: only the well-formed cross-app write
		// lands — and it names a sha its target cannot carry.
		selfWrite(me) // self-name: EACCES
		adminWrite(me, "FORGED.ELF", forgedSHA, "file,net")
		adminWrite(me, "MALROW.ELF", "notasha", "file,net") // EINVAL
		adminRead(me)
	default:
		vsys.Println("rowwrite: unknown op " + op)
		vsys.Exit(2)
	}
	vsys.Println("rowwrite: done name=" + me + " op=" + op)
	vsys.Exit(0)
}
