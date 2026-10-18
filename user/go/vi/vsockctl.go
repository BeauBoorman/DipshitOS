// M115d (issue #2463, ADR 0056 D5 + ADR 0007 amendment): the EL0 door to
// the virelai-ctl/1 control channel — slot 93.
//
// The kernel keeps the uid_system `vsock-ctl` credential and runs the
// whole authenticated session on the caller's behalf: connect to the
// host's --vsock-ctl-port listener, answer the HMAC challenge, send the
// request, relay the verdict. No key ever crosses this seam — the caller
// names a verb and reads back a verdict, never a byte of the exchange.
//
// `suspend` runs the guest quiesce (VLFS fsync when mounted, the
// settings re-save, the SUSPEND.MARK request receipt) between auth and
// request, and refuses by name before freezing half-prepared.
package vi

// VsockCtl runs one ctl session for `verb` (with the optional `name`
// argument the snapshot verb takes; "" sends a bare-verb request).
// Returns 0 when the reply was `ok:true` — for "suspend" that return may
// land on the far side of a host machine-state save/restore, so the
// caller's next instruction IS the resume. A refused session returns the
// refusal code's byte length and writes the ADR 0056 D4 name into `code`
// (`no_device`, `no_credential`, `unimplemented`, `unknown_verb`,
// `busy`, `io_error`, ...), truncated to len(code). Negative errno:
// EINVAL (non-process caller, verb_len outside 1..31, name_len > 31),
// EFAULT (a bad pointer). On a host build every call degrades to
// -ENOSYS like the rest of the seam.
func VsockCtl(verb, name string, code []byte) int64 {
	return svc6(SlotVsockCtl,
		strPtr(verb), uintptr(len(verb)),
		strPtr(name), uintptr(len(name)),
		bytePtr(code), uintptr(len(code)))
}
