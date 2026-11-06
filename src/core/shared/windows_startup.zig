const std = @import("std");

pub const Arguments = struct {
    argv: []const [*:0]const u8,
    env: [:null]const ?[*:0]const u8,

    // All returned memory belongs to the caller's process-lifetime arena.
    pub fn init(arena: std.mem.Allocator) !Arguments {
        const command = std.os.windows.peb().ProcessParameters.CommandLine;
        const args: std.process.Args = .{ .vector = command.Buffer.?[0 .. command.Length / 2] };
        const slices = try args.toSlice(arena);
        const argv = try arena.alloc([*:0]const u8, slices.len);
        for (slices, argv) |slice, *ptr| ptr.* = slice.ptr;
        var env = try (std.process.Environ{ .block = .global }).createMap(arena);
        const block = try env.createPosixBlock(arena, .{});
        return .{ .argv = argv, .env = block.slice };
    }
};
