// Code generated from kernel/src/syscall_abi.zig by go generate ./vi; DO NOT EDIT.
package vi

const (
	SlotPing               uintptr = 0
	SlotWait               uintptr = 8
	SlotWinMove            uintptr = 16
	SlotWinGet             uintptr = 18
	SlotWinSetVisible      uintptr = 20
	SlotFileFree           uintptr = 37
	SlotClipboardSet       uintptr = 38
	SlotClipboardGet       uintptr = 39
	SlotTimerSet           uintptr = 40
	SlotTimerCancel        uintptr = 41
	SlotDragStart          uintptr = 48
	SlotWinRaiseFront      uintptr = 49
	SlotWinLowerBack       uintptr = 50
	SlotNotify             uintptr = 51
	SlotWinMoveToWorkspace uintptr = 52
	SlotWinSetUnsaved      uintptr = 53
	SlotSetrlimit          uintptr = 54
	SlotDragRead           uintptr = 55
	SlotFontSize           uintptr = 58
	SlotMunmap             uintptr = 64
	SlotThread             uintptr = 73
	SlotFutex              uintptr = 74
	SlotExnotify           uintptr = 75
	SlotFsMetadata         uintptr = 79
	SlotSocket             uintptr = 80
	SlotTrace              uintptr = 81
	SlotProfile            uintptr = 82
	SlotMemstat            uintptr = 83
	SlotUDPSendFrom        uintptr = 84
	SlotUDPRecvFrom        uintptr = 85
	SlotUDPClose           uintptr = 86
	SlotGetpid             uintptr = 87
	SlotScanoutRead        uintptr = 88
	SlotGrantAdmin         uintptr = 89
	SlotGpucomp            uintptr = 90
	SlotAudioRecInfo       uintptr = 91
	SlotAudioRec           uintptr = 92
	SlotVsockCtl           uintptr = 93
	SlotSleepNs            uintptr = 94
	SlotTimerSetNs         uintptr = 95
)

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
	Kind       SyscallArgKind
	LengthArg  uint8
	LengthMask uint64
}
type SyscallSlot struct {
	Number   uintptr
	Name     string
	ArgCount uint8
	Args     [6]SyscallArg
}
type SyscallVariant struct {
	Number   uintptr
	Selector uint8
	Op       uint64
	ArgCount uint8
	Args     [6]SyscallArg
}

var SyscallSlots = [...]SyscallSlot{
	{SlotPing, "sys_ping", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotWrite, "sys_write", 3, [6]SyscallArg{{Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotYield, "sys_yield", 0, [6]SyscallArg{}},
	{SlotExit, "sys_exit", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotSleep, "sys_sleep", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotIPCSend, "sys_ipc_send", 3, [6]SyscallArg{{Kind: ArgPID}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotIPCRecv, "sys_ipc_recv", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotProcs, "sys_procs", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotWait, "sys_wait", 1, [6]SyscallArg{{Kind: ArgPID}}},
	{SlotUDPListen, "sys_udp_listen", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotUDPSend, "sys_udp_send", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotUDPRecv, "sys_udp_recv", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotWinOpen, "sys_win_open", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotWinFill, "sys_win_fill", 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotWinPresent, "sys_win_present", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotWinClose, "sys_win_close", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotWinMove, "sys_win_move", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotWinRaise, "sys_win_raise", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotWinGet, "sys_win_get", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}}},
	{SlotWinQuery, "sys_win_query", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}}},
	{SlotWinSetVisible, "sys_win_set_visible", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFlags}}},
	{SlotPollEvent, "sys_poll_event", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotWaitEvent, "sys_wait_event", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotFileOpen, "sys_file_open", 3, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgFlags}}},
	{SlotFileRead, "sys_file_read", 3, [6]SyscallArg{{Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotFileWrite, "sys_file_write", 3, [6]SyscallArg{{Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotFileClose, "sys_file_close", 1, [6]SyscallArg{{Kind: ArgFD}}},
	{SlotDirList, "sys_dir_list", 5, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgFlags}, {Kind: ArgInt}}},
	{SlotExec, "sys_exec", 6, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgFlags}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotKill, "sys_kill", 1, [6]SyscallArg{{Kind: ArgPID}}},
	{SlotTCPConnect, "sys_tcp_connect", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotTCPSend, "sys_tcp_send", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotTCPRecv, "sys_tcp_recv", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotTCPClose, "sys_tcp_close", 0, [6]SyscallArg{}},
	{SlotFileDelete, "sys_file_delete", 2, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{SlotFileRename, "sys_file_rename", 4, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: uint64(1)<<63 - 1}, {Kind: ArgFlags}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{SlotFileTruncate, "sys_file_truncate", 2, [6]SyscallArg{{Kind: ArgFD}, {Kind: ArgInt}}},
	{SlotFileFree, "sys_file_free", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotClipboardSet, "sys_clipboard_set", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotClipboardGet, "sys_clipboard_get", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotTimerSet, "sys_timer_set", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotTimerCancel, "sys_timer_cancel", 0, [6]SyscallArg{}},
	{SlotAudioInfo, "sys_audio_info", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotAudioPlay, "sys_audio_play", 4, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgFlags}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotAudioVolume, "sys_audio_volume", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotAudioMute, "sys_audio_mute", 1, [6]SyscallArg{{Kind: ArgFlags}}},
	{SlotWinFillBatch, "sys_win_fill_batch", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotWinResize, "sys_win_resize", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotDragStart, "sys_drag_start", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotWinRaiseFront, "sys_win_raise_front", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotWinLowerBack, "sys_win_lower_back", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotNotify, "sys_notify", 3, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotWinMoveToWorkspace, "sys_win_move_to_workspace", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotWinSetUnsaved, "sys_win_set_unsaved", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFlags}}},
	{SlotSetrlimit, "sys_setrlimit", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotDragRead, "sys_drag_read", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotPipeRead, "sys_pipe_read", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotPipeWrite, "sys_pipe_write", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotFontSize, "sys_font_size", 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotPingSend, "sys_ping_send", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotPingPoll, "sys_ping_poll", 0, [6]SyscallArg{}},
	{SlotWinSetTitle, "sys_win_set_title", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{SlotNetStats, "sys_net_stats", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotMmap, "sys_mmap", 4, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}, {Kind: ArgFlags}, {Kind: ArgFlags}}},
	{SlotMunmap, "sys_munmap", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotWmctl, "sys_wmctl", 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotTime, "sys_time", 0, [6]SyscallArg{}},
	{SlotTtyAttach, "sys_tty_attach", 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotPrincipal, "sys_principal", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotFileMode, "sys_file_mode", 3, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgFlags}}},
	{SlotSecretGet, "sys_secret_get", 6, [6]SyscallArg{{Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}}},
	{SlotTtyNetAuth, "sys_tty_net_auth", 6, [6]SyscallArg{{Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}, {Kind: ArgRedacted}}},
	{SlotGetRandom, "sys_getrandom", 2, [6]SyscallArg{{Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotThread, "sys_thread", 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgPtr}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{SlotFutex, "sys_futex", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{SlotExnotify, "sys_exnotify", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotSockReady, "sys_sock_ready", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFlags}, {Kind: ArgInt}}},
	{SlotFileSync, "sys_file_sync", 1, [6]SyscallArg{{Kind: ArgFD}}},
	{SlotTimeSet, "sys_time_set", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotFsMetadata, "sys_fs_metadata", 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{SlotSocket, "sys_socket", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotTrace, "sys_trace", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotProfile, "sys_profile", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotMemstat, "sys_memstat", 3, [6]SyscallArg{{Kind: ArgPID}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotUDPSendFrom, "sys_udp_send_from", 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotUDPRecvFrom, "sys_udp_recv_from", 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotUDPClose, "sys_udp_close", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotGetpid, "sys_getpid", 0, [6]SyscallArg{}},
	{SlotScanoutRead, "sys_scanout_read", 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotGrantAdmin, "sys_grant_admin", 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotGpucomp, "sys_gpucomp", 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotAudioRecInfo, "sys_audio_rec_info", 1, [6]SyscallArg{{Kind: ArgPtr}}},
	{SlotAudioRec, "sys_audio_rec", 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotVsockCtl, "sys_vsock_ctl", 6, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{SlotSleepNs, "sys_sleep_ns", 1, [6]SyscallArg{{Kind: ArgInt}}},
	{SlotTimerSetNs, "sys_timer_set_ns", 1, [6]SyscallArg{{Kind: ArgInt}}},
}

var SyscallVariants = [...]SyscallVariant{
	{59, 0, 148283745894406, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}}},
	{60, 0, 148283745894406, 1, [6]SyscallArg{{Kind: ArgInt}}},
	{80, 1, 148283745894406, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{27, 3, 9223372036854775809, 4, [6]SyscallArg{{Kind: ArgString, LengthArg: 1, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgFlags}}},
	{27, 3, 9223372036854775810, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgFlags}, {Kind: ArgInt}}},
	{27, 3, 9223372036854775811, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgFlags}}},
	{65, 0, 8, 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 5, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{73, 0, 1, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{73, 0, 2, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{73, 0, 3, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}}},
	{74, 0, 1, 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{79, 0, 0, 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{79, 0, 1, 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{79, 0, 2, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 3, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 4, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 5, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{79, 0, 6, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{79, 0, 7, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgString, LengthArg: 2, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 4, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 8, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 9, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}}},
	{79, 0, 10, 6, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}}},
	{79, 0, 11, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 12, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}}},
	{79, 0, 13, 5, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgString, LengthArg: 3, LengthMask: ^uint64(0)}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{80, 0, 0, 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{80, 0, 1, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}}},
	{80, 0, 2, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{80, 0, 3, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{80, 0, 4, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}}},
	{80, 0, 5, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}}},
	{80, 0, 6, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}}},
	{80, 0, 7, 2, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}}},
	{80, 0, 8, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{80, 0, 9, 4, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgFD}, {Kind: ArgPtr}, {Kind: ArgInt}}},
	{80, 0, 10, 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgInt}, {Kind: ArgInt}}},
	{80, 0, 11, 1, [6]SyscallArg{{Kind: ArgInt}}},
	{80, 0, 12, 3, [6]SyscallArg{{Kind: ArgInt}, {Kind: ArgPtr}, {Kind: ArgInt}}},
}
