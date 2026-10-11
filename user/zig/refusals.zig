//! Signature-preserving refusals for the pinned std.Io vtable.
const std = @import("std");
pub fn result(comptime Driver: type, comptime name: []const u8, comptime R: type) R {
    Driver.diagnostic("Unsupported:" ++ name ++ "\n");
    const E = switch (@typeInfo(R)) {
        .error_union => |u| u.error_set,
        .error_set => R,
        else => Driver.fatal("Unsupported:" ++ name),
    };
    inline for (.{ "OperationUnsupported", "UnsupportedOperation", "Unexpected" }) |err| {
        inline for (@typeInfo(E).error_set.error_names.?) |candidate| {
            if (comptime std.mem.eql(u8, candidate, err)) return @field(E, err);
        }
    }
    Driver.fatal("Unsupported:" ++ name);
}
pub fn function(comptime Driver: type, comptime name: []const u8, comptime P: type) P {
    const F = @typeInfo(@typeInfo(P).pointer.child).@"fn";
    const R = F.return_type.?;
    const A = struct {
        fn T(comptime i: usize) type {
            return F.param_types[i].?;
        }
    };
    return switch (F.param_types.len) {
        1 => struct {
            fn call(_: A.T(0)) R {
                return result(Driver, name, R);
            }
        }.call,
        2 => struct {
            fn call(_: A.T(0), _: A.T(1)) R {
                return result(Driver, name, R);
            }
        }.call,
        3 => struct {
            fn call(_: A.T(0), _: A.T(1), _: A.T(2)) R {
                return result(Driver, name, R);
            }
        }.call,
        4 => struct {
            fn call(_: A.T(0), _: A.T(1), _: A.T(2), _: A.T(3)) R {
                return result(Driver, name, R);
            }
        }.call,
        5 => struct {
            fn call(_: A.T(0), _: A.T(1), _: A.T(2), _: A.T(3), _: A.T(4)) R {
                return result(Driver, name, R);
            }
        }.call,
        6 => struct {
            fn call(_: A.T(0), _: A.T(1), _: A.T(2), _: A.T(3), _: A.T(4), _: A.T(5)) R {
                return result(Driver, name, R);
            }
        }.call,
        7 => struct {
            fn call(_: A.T(0), _: A.T(1), _: A.T(2), _: A.T(3), _: A.T(4), _: A.T(5), _: A.T(6)) R {
                return result(Driver, name, R);
            }
        }.call,
        else => @compileError("UnreviewedIoSignature:" ++ name),
    };
}
