const std = @import("std");
const builtin = @import("builtin");
pub const std_options_FilePermissions = @import("windows_platform.zig").Permissions;

pub fn main(init: std.process.Init) !void {
    var failures: usize = 0;
    for (builtin.test_functions) |test_fn| {
        std.testing.allocator_instance = .init(std.heap.page_allocator, .{ .canary = 0xc3a701ba, .check_write_after_free = true });
        std.testing.io_instance = .init(std.testing.allocator, .{ .argv0 = .init(init.minimal.args), .environ = init.minimal.environ });
        std.testing.environ = init.minimal.environ;
        std.debug.print("{s}... ", .{test_fn.name});
        if (test_fn.func()) |_| {
            std.debug.print("OK\n", .{});
        } else |err| {
            if (err != error.SkipZigTest) failures += 1;
            std.debug.print("{t}\n", .{err});
            if (@errorReturnTrace()) |trace| std.debug.dumpErrorReturnTrace(trace);
        }
        std.testing.io_instance.deinit();
        if (std.testing.allocator_instance.deinit() != 0) failures += 1;
    }
    if (failures != 0) std.process.exit(1);
}
