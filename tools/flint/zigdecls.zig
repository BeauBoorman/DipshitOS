//! FLINT oracle (M103a, host-only — never compiled into the guest or
//! build.zig). Parses each .zig file named on argv with std.zig.Ast and
//! prints one line per top-level declaration:
//!
//!   <file>\t<kind>\t<name>\t<start>\t<end>\n
//!
//! kind/name/span conventions match user/go/flint/parser's Zig scanner:
//! kind is fn|const|var|struct|enum|union|test, name is the qualified
//! name (<stem>.<local>, tests <stem>.test:<label>), start is the first
//! qualifier token and end is the last token of the declaration
//! including a trailing `;`. @import consts, `_` names, anonymous
//! test{}, top-level comptime{} and usingnamespace are ignored.

const std = @import("std");
const Ast = std.zig.Ast;

pub fn main(init: std.process.Init) !void {
    var buffer: [1 << 16]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const w = &output.interface;
    var stderr_buf: [1024]u8 = undefined;
    var err_out = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const ew = &err_out.interface;
    defer ew.flush() catch {};

    const argv = init.minimal.args.vector;
    var failed = false;
    for (argv[1..]) |arg| {
        const path = std.mem.span(arg);
        const source = std.Io.Dir.cwd().readFileAllocOptions(init.io, path, init.gpa, .limited(64 << 20), .of(u8), 0) catch |e| {
            try ew.print("{s}\tREAD_ERROR {s}\n", .{ path, @errorName(e) });
            failed = true;
            continue;
        };
        defer init.gpa.free(source);
        var tree = try Ast.parse(init.gpa, source, .{});
        defer tree.deinit(init.gpa);
        if (tree.errors.len != 0) {
            try ew.print("{s}\tPARSE_ERROR {s}\n", .{ path, @tagName(tree.errors[0].tag) });
            failed = true;
            continue;
        }
        const stem = fileStem(path);
        for (tree.rootDecls()) |decl| {
            emit(w, &tree, stem, path, decl) catch |e| {
                try ew.print("{s}\tEMIT_ERROR {s}\n", .{ path, @errorName(e) });
                failed = true;
            };
        }
    }
    try w.flush();
    if (failed) return error.OracleFailed;
}

fn fileStem(path: []const u8) []const u8 {
    var base = path;
    if (std.mem.lastIndexOfScalar(u8, base, '/')) |i| base = base[i + 1 ..];
    if (std.mem.endsWith(u8, base, ".zig")) return base[0 .. base.len - 4];
    return base;
}

fn emit(w: *std.Io.Writer, tree: *const Ast, stem: []const u8, path: []const u8, decl: Ast.Node.Index) !void {
    switch (tree.nodeTag(decl)) {
        .fn_decl => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto_node = tree.nodeData(decl).node_and_node[0];
            const proto = tree.fullFnProto(&buf, proto_node).?;
            const name = declName(tree, proto.name_token orelse return);
            try line(w, path, "fn", stem, name, spanStart(tree, decl), spanEnd(tree, decl));
        },
        .fn_proto, .fn_proto_multi, .fn_proto_one, .fn_proto_simple => {
            var buf: [1]Ast.Node.Index = undefined;
            const proto = tree.fullFnProto(&buf, decl).?;
            const name = declName(tree, proto.name_token orelse return);
            try line(w, path, "fn", stem, name, spanStart(tree, decl), spanEnd(tree, decl));
        },
        .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
            const vd = tree.fullVarDecl(decl).?;
            const mut_tag = tree.tokenTag(vd.ast.mut_token);
            const kind: []const u8 = switch (mut_tag) {
                .keyword_const => "const",
                .keyword_var => "var",
                else => return,
            };
            const name_tok = vd.ast.mut_token + 1;
            const name = declName(tree, name_tok);
            if (std.mem.eql(u8, name, "_")) return;
            if (vd.ast.init_node.unwrap()) |init_node| {
                const tag = tree.nodeTag(init_node);
                switch (tag) {
                    .container_decl,
                    .container_decl_trailing,
                    .container_decl_two,
                    .container_decl_two_trailing,
                    .container_decl_arg,
                    .container_decl_arg_trailing,
                    .tagged_union,
                    .tagged_union_trailing,
                    .tagged_union_two,
                    .tagged_union_two_trailing,
                    .tagged_union_enum_tag,
                    .tagged_union_enum_tag_trailing,
                    => {
                        var cbuf: [2]Ast.Node.Index = undefined;
                        const cd = tree.fullContainerDecl(&cbuf, init_node).?;
                        const ckind: []const u8 = switch (tree.tokenTag(cd.ast.main_token)) {
                            .keyword_struct => "struct",
                            .keyword_enum => "enum",
                            .keyword_union => "union",
                            else => return,
                        };
                        try line(w, path, ckind, stem, name, spanStart(tree, decl), spanEnd(tree, decl));
                        return;
                    },
                    .builtin_call,
                    .builtin_call_comma,
                    .builtin_call_two,
                    .builtin_call_two_comma,
                    => {
                        if (std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(init_node)), "@import")) return;
                    },
                    else => {},
                }
            }
            try line(w, path, kind, stem, name, spanStart(tree, decl), spanEnd(tree, decl));
        },
        .test_decl => {
            const name_token = tree.nodeData(decl).opt_token_and_node[0].unwrap() orelse return; // anonymous test {}
            const tag = tree.tokenTag(name_token);
            const raw = tree.tokenSlice(name_token);
            const label = switch (tag) {
                .string_literal => raw[1 .. raw.len - 1],
                .identifier => raw,
                else => return,
            };
            var name_buf: [256]u8 = undefined;
            const name = std.fmt.bufPrint(&name_buf, "{s}.test:{s}", .{ stem, label }) catch return;
            try lineBare(w, path, "test", name, spanStart(tree, decl), spanEnd(tree, decl));
        },
        .@"comptime" => return, // ignored top-level block
        else => {},
    }
}

fn declName(tree: *const Ast, tok: Ast.TokenIndex) []const u8 {
    const raw = tree.tokenSlice(tok);
    if (std.mem.startsWith(u8, raw, "@\"")) return raw[2 .. raw.len - 1];
    return raw;
}

// Span = first qualifier token .. last declaration token. Ast's
// lastToken excludes the terminating `;` for var/proto decls, so extend
// over it when present — matching the Go scanner's inclusive-`;` rule.
fn spanStart(tree: *const Ast, decl: Ast.Node.Index) u32 {
    return @intCast(tree.tokenStart(tree.firstToken(decl)));
}

fn spanEnd(tree: *const Ast, decl: Ast.Node.Index) u32 {
    var last = tree.lastToken(decl);
    if (last + 1 < tree.tokens.len and tree.tokenTag(last + 1) == .semicolon) last += 1;
    return @intCast(tree.tokenStart(last) + tree.tokenSlice(last).len);
}

fn line(w: *std.Io.Writer, path: []const u8, kind: []const u8, stem: []const u8, name: []const u8, start: u32, end: u32) !void {
    try w.print("{s}\t{s}\t{s}.{s}\t{d}\t{d}\n", .{ path, kind, stem, name, start, end });
}

fn lineBare(w: *std.Io.Writer, path: []const u8, kind: []const u8, name: []const u8, start: u32, end: u32) !void {
    try w.print("{s}\t{s}\t{s}\t{d}\t{d}\n", .{ path, kind, name, start, end });
}
