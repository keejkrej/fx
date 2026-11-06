const std = @import("std");
const windows = std.os.windows;

/// Poll Zig's native AFD socket handles. These are not Winsock sockets.
pub fn readable(io: std.Io, handle: windows.HANDLE, milliseconds: u32) !bool {
    const Entry = extern struct { handle: windows.HANDLE, events: u32, status: windows.NTSTATUS = .SUCCESS };
    const Info = extern struct { timeout: i64, count: u32 = 1, exclusive: u32 = 0, handles: [1]Entry };
    var info: Info = .{
        .timeout = -@as(i64, milliseconds) * 10000,
        // Receive, disconnect, abort, local close, accept, connect failure.
        .handles = .{.{ .handle = handle, .events = 0x1 | 0x8 | 0x10 | 0x20 | 0x80 | 0x100 }},
    };
    const result = try io.operate(.{ .device_io_control = .{
        .file = .{ .handle = handle, .flags = .{ .nonblocking = true } },
        .code = windows.IOCTL.AFD.POLL,
        .in = std.mem.asBytes(&info),
        .out = std.mem.asBytes(&info),
    } });
    return switch (result.device_io_control.u.Status) {
        .SUCCESS => info.count != 0 and info.handles[0].events != 0,
        .TIMEOUT => false,
        else => error.SocketPollFailed,
    };
}
