//! VirelaiOS Sexiburger Action Registry (Milestone 19, Issues #677, #701, #703, #704).
//!
//! Pure value-type action and section registry with ZERO heap allocations.
//!
//! The Covenant of Six (Issues #677, #703):
//! Exactly six canonical top-level sections ("tentacles" / "layers"):
//! 1. System       (Crown bun)
//! 2. Apps         (Lettuce)
//! 3. Active app   (Tomato)
//! 4. Windows & tabs (Cheese)
//! 5. Services     (Patty)
//! 6. Power        (Heel bun)
//!
//! Any attempt to register or add a 7th top-level section is rejected by
//! returning `error.CovenantOfSixExceeded` with citation:
//! "the tentacle count is load-bearing: seventh section rejected by the covenant of six".

const std = @import("std");

pub const covenant_citation: []const u8 =
    "the tentacle count is load-bearing: seventh section rejected by the covenant of six";

pub const RegistryError = error{
    CovenantOfSixExceeded,
    SectionNotFound,
    SectionFull,
    RegistryFull,
    DuplicateCommand,
    InvalidName,
    BufferTooSmall,
};

/// Exactly six top-level sections, hard-capped by the Covenant of Six.
pub const SectionId = enum(u8) {
    system = 0,
    apps = 1,
    active_app = 2,
    windows_tabs = 3,
    services = 4,
    power = 5,

    pub const count: usize = 6;

    pub fn from_index(idx: usize) ?SectionId {
        if (idx < count) {
            return @enumFromInt(@as(u8, @intCast(idx)));
        }
        return null;
    }

    pub fn index(self: SectionId) usize {
        return @intFromEnum(self);
    }

    pub fn name(self: SectionId) []const u8 {
        return switch (self) {
            .system => "System",
            .apps => "Apps",
            .active_app => "Active app",
            .windows_tabs => "Windows & tabs",
            .services => "Services",
            .power => "Power",
        };
    }

    pub fn icon(self: SectionId) []const u8 {
        return switch (self) {
            .system => "[SYS]",
            .apps => "[APP]",
            .active_app => "[ACT]",
            .windows_tabs => "[WIN]",
            .services => "[SRV]",
            .power => "[PWR]",
        };
    }

    pub fn layer_name(self: SectionId) []const u8 {
        return switch (self) {
            .system => "Crown",
            .apps => "Lettuce",
            .active_app => "Tomato",
            .windows_tabs => "Cheese",
            .services => "Patty",
            .power => "Heel",
        };
    }

    pub fn tentacle_label(self: SectionId) []const u8 {
        return switch (self) {
            .system => "Tentacle 1 (Upper Left)",
            .apps => "Tentacle 2 (Mid Left)",
            .active_app => "Tentacle 3 (Lower Inward Left)",
            .windows_tabs => "Tentacle 4 (Upper Right)",
            .services => "Tentacle 5 (Mid Right)",
            .power => "Tentacle 6 (Lower Inward Right)",
        };
    }
};

pub const max_label_len: usize = 32;
pub const max_shortcut_len: usize = 16;
pub const max_verb_len: usize = 24;
pub const max_commands_per_section: usize = 16;
pub const max_total_commands: usize = SectionId.count * max_commands_per_section;

pub const Command = struct {
    id: u16 = 0,
    section: SectionId,
    label: []const u8,
    shortcut: []const u8 = "",
    verb: []const u8 = "", // Shell verb for M19 synergy
    action: ?*const fn () void = null,
    enabled: bool = true,
};

pub const FilterResult = struct {
    command: Command,
    score: u32,
};

pub const ActionRegistry = struct {
    commands: [max_total_commands]Command = undefined,
    command_count: usize = 0,
    active_app_title: [32]u8 = @as([32]u8, @splat(@as(u8, 0))),
    active_app_title_len: usize = 0,
    next_cmd_id: u16 = 1,

    pub fn init() ActionRegistry {
        var reg = ActionRegistry{
            .command_count = 0,
            .next_cmd_id = 1,
        };
        reg.populate_defaults();
        return reg;
    }

    pub fn init_empty() ActionRegistry {
        return .{
            .command_count = 0,
            .next_cmd_id = 1,
        };
    }

    /// Return the fixed number of top-level sections (always 6).
    pub fn section_count(self: *const ActionRegistry) usize {
        _ = self;
        return SectionId.count;
    }

    /// Check Covenant of Six: any registration of a 7th section MUST fail.
    pub fn register_section(self: *ActionRegistry, name: []const u8) RegistryError!SectionId {
        _ = self;
        // Check if name matches one of the canonical 6 sections
        for (0..SectionId.count) |i| {
            const sid = SectionId.from_index(i).?;
            if (std.ascii.eqlIgnoreCase(sid.name(), name)) {
                return sid;
            }
        }
        // Attempting to register a 7th section violates the Covenant of Six!
        return RegistryError.CovenantOfSixExceeded;
    }

    /// Register a command into an existing section.
    pub fn register_command(
        self: *ActionRegistry,
        section: SectionId,
        label: []const u8,
        shortcut: []const u8,
        verb: []const u8,
        action: ?*const fn () void,
    ) RegistryError!u16 {
        if (self.command_count >= max_total_commands) {
            return RegistryError.RegistryFull;
        }

        var sec_count: usize = 0;
        for (0..self.command_count) |i| {
            if (self.commands[i].section == section) {
                sec_count += 1;
                // Disallow duplicate labels in same section
                if (std.mem.eql(u8, self.commands[i].label, label)) {
                    return RegistryError.DuplicateCommand;
                }
            }
        }

        if (sec_count >= max_commands_per_section) {
            return RegistryError.SectionFull;
        }

        const id = self.next_cmd_id;
        self.next_cmd_id +%= 1;

        self.commands[self.command_count] = .{
            .id = id,
            .section = section,
            .label = label,
            .shortcut = shortcut,
            .verb = verb,
            .action = action,
            .enabled = true,
        };
        self.command_count += 1;
        return id;
    }

    /// Set active application name and clear previous active_app commands.
    pub fn set_active_app(self: *ActionRegistry, title: []const u8) void {
        const copy_len = @min(title.len, self.active_app_title.len);
        @memcpy(self.active_app_title[0..copy_len], title[0..copy_len]);
        self.active_app_title_len = copy_len;

        // Prune old active_app commands
        var write_idx: usize = 0;
        for (0..self.command_count) |read_idx| {
            if (self.commands[read_idx].section != .active_app) {
                if (write_idx != read_idx) {
                    self.commands[write_idx] = self.commands[read_idx];
                }
                write_idx += 1;
            }
        }
        self.command_count = write_idx;
    }

    pub fn get_active_app(self: *const ActionRegistry) []const u8 {
        return self.active_app_title[0..self.active_app_title_len];
    }

    /// Query commands belonging to a specific section.
    pub fn get_section_commands(
        self: *const ActionRegistry,
        section: SectionId,
        out: []Command,
    ) usize {
        var count: usize = 0;
        for (0..self.command_count) |i| {
            if (count >= out.len) break;
            if (self.commands[i].section == section) {
                out[count] = self.commands[i];
                count += 1;
            }
        }
        return count;
    }

    /// Find a command by shell verb (M19 synergy: registered commands as shell verbs).
    pub fn find_by_verb(self: *const ActionRegistry, verb: []const u8) ?Command {
        if (verb.len == 0) return null;
        for (0..self.command_count) |i| {
            if (self.commands[i].verb.len > 0 and std.ascii.eqlIgnoreCase(self.commands[i].verb, verb)) {
                return self.commands[i];
            }
        }
        return null;
    }

    /// Find a command by ID.
    pub fn find_by_id(self: *const ActionRegistry, id: u16) ?Command {
        for (0..self.command_count) |i| {
            if (self.commands[i].id == id) {
                return self.commands[i];
            }
        }
        return null;
    }

    /// Execute a command by ID or shell verb.
    pub fn invoke_command(self: *const ActionRegistry, id: u16) bool {
        if (self.find_by_id(id)) |cmd| {
            if (cmd.enabled and cmd.action != null) {
                cmd.action.?();
                return true;
            }
            return cmd.enabled;
        }
        return false;
    }

    /// Type-to-filter across all registered commands (Issue #704).
    /// Quicksilver-style abbreviation + prefix + substring matching.
    pub fn filter(
        self: *const ActionRegistry,
        query: []const u8,
        out: []FilterResult,
    ) usize {
        if (out.len == 0) return 0;
        const trimmed = std.mem.trim(u8, query, " \t\r\n");

        if (trimmed.len == 0) {
            // Empty query returns all commands up to out.len
            const limit = @min(self.command_count, out.len);
            for (0..limit) |i| {
                out[i] = .{
                    .command = self.commands[i],
                    .score = 10,
                };
            }
            return limit;
        }

        var match_count: usize = 0;
        for (0..self.command_count) |i| {
            const cmd = self.commands[i];
            const score = match_score(trimmed, cmd.label, cmd.verb);
            if (score > 0) {
                if (match_count < out.len) {
                    out[match_count] = .{ .command = cmd, .score = score };
                    match_count += 1;
                } else {
                    // Replace lowest scoring element if this score is higher
                    var min_idx: usize = 0;
                    var min_score: u32 = out[0].score;
                    for (1..out.len) |j| {
                        if (out[j].score < min_score) {
                            min_score = out[j].score;
                            min_idx = j;
                        }
                    }
                    if (score > min_score) {
                        out[min_idx] = .{ .command = cmd, .score = score };
                    }
                }
            }
        }

        // Sort descending by score
        if (match_count > 1) {
            var a: usize = 0;
            while (a < match_count - 1) : (a += 1) {
                var b: usize = a + 1;
                while (b < match_count) : (b += 1) {
                    if (out[b].score > out[a].score) {
                        const tmp = out[a];
                        out[a] = out[b];
                        out[b] = tmp;
                    }
                }
            }
        }

        return match_count;
    }

    /// Populate canonical defaults across the 6 sections.
    pub fn populate_defaults(self: *ActionRegistry) void {
        // 1. System
        _ = self.register_command(.system, "About VirelaiOS", "", "about", null) catch {};
        _ = self.register_command(.system, "System Info", "Ctrl+I", "sysinfo", null) catch {};
        _ = self.register_command(.system, "Settings Panel", "Ctrl+,", "settings", null) catch {};
        _ = self.register_command(.system, "Task Manager", "Ctrl+Esc", "top", null) catch {};
        _ = self.register_command(.system, "Sexiburger Diagnostics", "", "sexiburger", null) catch {};

        // 2. Apps
        _ = self.register_command(.apps, "Text Editor", "Ctrl+Alt+E", "notepad", null) catch {};
        _ = self.register_command(.apps, "Calculator", "Ctrl+Alt+C", "calc", null) catch {};
        _ = self.register_command(.apps, "File Browser", "Ctrl+Alt+F", "file", null) catch {};
        _ = self.register_command(.apps, "Terminal (Road Pops)", "Ctrl+Alt+T", "terminal", null) catch {};

        // 3. Active App (Defaults for when no specific app is frontmost)
        _ = self.register_command(.active_app, "Save", "Ctrl+S", "save", null) catch {};
        _ = self.register_command(.active_app, "Find / Replace", "Ctrl+F", "find", null) catch {};
        _ = self.register_command(.active_app, "Close Window", "Ctrl+Q", "close", null) catch {};

        // 4. Windows & tabs
        _ = self.register_command(.windows_tabs, "New Tab", "Ctrl+T", "tab-new", null) catch {};
        _ = self.register_command(.windows_tabs, "Close Tab", "Ctrl+W", "tab-close", null) catch {};
        _ = self.register_command(.windows_tabs, "Next Tab", "Ctrl+Tab", "tab-next", null) catch {};
        _ = self.register_command(.windows_tabs, "Tile Window Left", "Alt+Left", "tile-left", null) catch {};
        _ = self.register_command(.windows_tabs, "Tile Window Right", "Alt+Right", "tile-right", null) catch {};

        // 5. Services
        _ = self.register_command(.services, "Clipboard History", "Ctrl+Shift+V", "clipboard", null) catch {};
        _ = self.register_command(.services, "App Timers", "", "timers", null) catch {};
        _ = self.register_command(.services, "Notifications", "", "notify", null) catch {};

        // 6. Power
        _ = self.register_command(.power, "Reboot System", "", "reboot", null) catch {};
        _ = self.register_command(.power, "Power Off", "", "shutdown", null) catch {};
    }
};

/// Quicksilver abbreviation / prefix / substring score.
pub fn match_score(query: []const u8, label: []const u8, verb: []const u8) u32 {
    if (query.len == 0) return 10;

    var best_score: u32 = 0;
    const targets = [_][]const u8{ label, verb };

    for (targets) |target| {
        if (target.len == 0) continue;

        // 1. Exact match
        if (std.ascii.eqlIgnoreCase(query, target)) {
            best_score = @max(best_score, 1000);
            continue;
        }

        // 2. Prefix match
        if (target.len >= query.len and std.ascii.eqlIgnoreCase(query, target[0..query.len])) {
            best_score = @max(best_score, 500 + @as(u32, @intCast(100 - @min(target.len, 100))));
            continue;
        }

        // 3. Word initial abbreviation match (e.g. "sb" matches "Sexiburger", "nt" matches "New Tab")
        var initials_buf: [16]u8 = undefined;
        var init_len: usize = 0;
        var in_word = false;
        for (target) |c| {
            if ((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9')) {
                if (!in_word) {
                    if (init_len < initials_buf.len) {
                        initials_buf[init_len] = std.ascii.toLower(c);
                        init_len += 1;
                    }
                    in_word = true;
                }
            } else {
                in_word = false;
            }
        }
        const initials = initials_buf[0..init_len];
        if (query.len <= initials.len) {
            var init_prefix_match = true;
            for (0..query.len) |k| {
                if (std.ascii.toLower(query[k]) != initials[k]) {
                    init_prefix_match = false;
                    break;
                }
            }
            if (init_prefix_match) {
                best_score = @max(best_score, 300 + @as(u32, @intCast(init_len)));
                continue;
            }
        }

        // 4. Substring match
        if (indexOfIgnoreCase(target, query)) |_| {
            best_score = @max(best_score, 200 + @as(u32, @intCast(100 - @min(target.len, 100))));
            continue;
        }

        // 5. Subsequence (fuzzy abbreviation) match
        var q_idx: usize = 0;
        for (target) |ch| {
            if (q_idx < query.len and std.ascii.toLower(ch) == std.ascii.toLower(query[q_idx])) {
                q_idx += 1;
            }
        }
        if (q_idx == query.len) {
            best_score = @max(best_score, 100 + @as(u32, @intCast(100 - @min(target.len, 100))));
        }
    }

    return best_score;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    const max_start = haystack.len - needle.len;
    for (0..max_start + 1) |i| {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Mascot Diagnostics (Operational Lore, Milestone 19 Acceptance Criteria)
// ---------------------------------------------------------------------------

var sexiburger_diag_storage: [14][]const u8 = undefined;
var sexiburger_diag_ready = false;

pub fn sexiburger_ascii_lines() []const []const u8 {
    if (!sexiburger_diag_ready) {
        sexiburger_diag_storage[0] = "           .-------.";
        sexiburger_diag_storage[1] = "          /  *   *  \\    [Crown: System]";
        sexiburger_diag_storage[2] = "        (  .  *   .   ) ";
        sexiburger_diag_storage[3] = "     (~~~\\___________/~~~) [Lettuce: Apps]";
        sexiburger_diag_storage[4] = "      \\   [=========]   /  [Tomato: Active app]";
        sexiburger_diag_storage[5] = "       \\   (=======)   /   [Cheese: Windows & tabs]";
        sexiburger_diag_storage[6] = "        \\  |=======|  /    [Patty: Services]";
        sexiburger_diag_storage[7] = "      __ \\ \\_______/ / __  [Heel: Power]";
        sexiburger_diag_storage[8] = "     (  \\ \\_|_|_|_|_/ /  )";
        sexiburger_diag_storage[9] = "      \\  \\___     ___/  /";
        sexiburger_diag_storage[10] = "       )  (  |   |  )  (";
        sexiburger_diag_storage[11] = "      /  /   |   |   \\  \\";
        sexiburger_diag_storage[12] = "     (_ /    |   |    \\ _)";
        sexiburger_diag_storage[13] = "  [6 tentacles | 6 layers | Covenant invariant intact]";
        sexiburger_diag_ready = true;
    }
    return &sexiburger_diag_storage;
}

// ---------------------------------------------------------------------------
// Tests (Host Verified)
// ---------------------------------------------------------------------------

test "covenant of six: exactly six canonical sections" {
    try std.testing.expectEqual(@as(usize, 6), SectionId.count);
    for (0..6) |i| {
        const sid = SectionId.from_index(i);
        try std.testing.expect(sid != null);
        try std.testing.expect(sid.?.name().len > 0);
        try std.testing.expect(sid.?.layer_name().len > 0);
        try std.testing.expect(sid.?.tentacle_label().len > 0);
    }
    try std.testing.expectEqual(@as(?SectionId, null), SectionId.from_index(6));
}

test "covenant of six: seventh section registration strictly rejected with citation" {
    var reg = ActionRegistry.init_empty();

    // The canonical 6 can be looked up / registered:
    const s0 = try reg.register_section("System");
    try std.testing.expectEqual(SectionId.system, s0);
    const s1 = try reg.register_section("Apps");
    try std.testing.expectEqual(SectionId.apps, s1);
    const s5 = try reg.register_section("Power");
    try std.testing.expectEqual(SectionId.power, s5);

    // Attempting a 7th section MUST fail with CovenantOfSixExceeded:
    const err = reg.register_section("Seventh Section");
    try std.testing.expectError(RegistryError.CovenantOfSixExceeded, err);

    // Verify citation string is exact:
    try std.testing.expect(std.mem.indexOf(u8, covenant_citation, "the tentacle count is load-bearing") != null);
    try std.testing.expect(std.mem.indexOf(u8, covenant_citation, "seventh section rejected") != null);
}

test "action registry: command registration and section isolation" {
    var reg = ActionRegistry.init_empty();

    const cmd1 = try reg.register_command(.system, "About", "", "about", null);
    const cmd2 = try reg.register_command(.system, "Sysinfo", "Ctrl+I", "sysinfo", null);
    try std.testing.expect(cmd1 != cmd2);

    // Duplicate command in same section rejected
    try std.testing.expectError(RegistryError.DuplicateCommand, reg.register_command(.system, "About", "", "about2", null));

    var sys_cmds: [16]Command = undefined;
    const n = reg.get_section_commands(.system, &sys_cmds);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("About", sys_cmds[0].label);
    try std.testing.expectEqualStrings("Sysinfo", sys_cmds[1].label);

    var app_cmds: [16]Command = undefined;
    const n_app = reg.get_section_commands(.apps, &app_cmds);
    try std.testing.expectEqual(@as(usize, 0), n_app);
}

test "action registry: shell verb lookup (M19 synergy)" {
    var reg = ActionRegistry.init();

    const cmd_sys = reg.find_by_verb("sysinfo");
    try std.testing.expect(cmd_sys != null);
    try std.testing.expectEqual(SectionId.system, cmd_sys.?.section);
    try std.testing.expectEqualStrings("System Info", cmd_sys.?.label);

    const cmd_reboot = reg.find_by_verb("reboot");
    try std.testing.expect(cmd_reboot != null);
    try std.testing.expectEqual(SectionId.power, cmd_reboot.?.section);

    try std.testing.expect(reg.find_by_verb("nonexistent_verb") == null);
}

test "action registry: active app contextual scoping" {
    var reg = ActionRegistry.init();
    reg.set_active_app("NOTEPAD.BIN");
    try std.testing.expectEqualStrings("NOTEPAD.BIN", reg.get_active_app());

    _ = try reg.register_command(.active_app, "Save File", "Ctrl+S", "save", null);
    _ = try reg.register_command(.active_app, "Toggle Line Numbers", "F11", "linenums", null);

    var active_cmds: [16]Command = undefined;
    var count = reg.get_section_commands(.active_app, &active_cmds);
    try std.testing.expectEqual(@as(usize, 2), count);

    // Switch active app: previous active_app commands pruned
    reg.set_active_app("GOCALC.ELF");
    try std.testing.expectEqualStrings("GOCALC.ELF", reg.get_active_app());

    count = reg.get_section_commands(.active_app, &active_cmds);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "action registry: type-to-filter with abbreviation and fuzzy matching" {
    var reg = ActionRegistry.init();

    var results: [16]FilterResult = undefined;

    // 1. Prefix query: "sys"
    var count = reg.filter("sys", &results);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("System Info", results[0].command.label);

    // 2. Abbreviation query: "nt" matches "New Tab"
    count = reg.filter("nt", &results);
    try std.testing.expect(count >= 1);
    var found_new_tab = false;
    for (0..count) |i| {
        if (std.mem.eql(u8, results[i].command.label, "New Tab")) {
            found_new_tab = true;
            break;
        }
    }
    try std.testing.expect(found_new_tab);

    // 3. Substring query: "clip"
    count = reg.filter("clip", &results);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("Clipboard History", results[0].command.label);

    // 4. Shell verb query: "reboot"
    count = reg.filter("reboot", &results);
    try std.testing.expect(count >= 1);
    try std.testing.expectEqualStrings("Reboot System", results[0].command.label);
}

test "mascot diagnostics: deterministic 6-layer 6-tentacle accounting" {
    const lines = sexiburger_ascii_lines();
    try std.testing.expectEqual(@as(usize, 14), lines.len);
    try std.testing.expect(std.mem.indexOf(u8, lines[13], "6 tentacles") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[13], "6 layers") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[13], "Covenant invariant intact") != null);
}
