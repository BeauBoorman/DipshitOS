//! M115f (#2465): the OS version label `sysinfo` reports. The value is a
//! build stamp (-Dos-version; build.zig's kernel_options) — but
//! build_options is unreachable from monitor.zig because bare
//! `zig test kernel/src/shell.zig` compiles it with no options module, so
//! the label lives here as a plain global the kernel entry sets before the
//! monitor ever runs.
//!
//! Default is "dev", matching build.zig's -Dos-version default — a kernel
//! built without the option (or a host test that never reaches the entry)
//! reports the same label either way.

pub var label: []const u8 = "dev";
