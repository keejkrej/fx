const std = @import("std");
const Handle = std.os.windows.HANDLE;
pub const PollFd = extern struct { fd: Handle, events: i16, revents: i16 };
pub const Poll = struct {
    pub const IN: i16 = 0x0300;
    pub const OUT: i16 = 0x0010;
    pub const ERR: i16 = 0x0001;
    pub const HUP: i16 = 0x0002;
    pub const NVAL: i16 = 0x0004;
};
extern "ws2_32" fn WSAStartup(u16, *anyopaque) callconv(.winapi) i32;
extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn socket(i32, i32, i32) callconv(.winapi) Handle;
extern "ws2_32" fn closesocket(Handle) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(Handle, i32, *u32) callconv(.winapi) i32;
pub extern "ws2_32" fn connect(Handle, *const anyopaque, i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(Handle, [*]u8, i32, i32) callconv(.winapi) i32;
extern "ws2_32" fn send(Handle, [*]const u8, i32, i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(Handle, i32, i32, *i32, *i32) callconv(.winapi) i32;
extern "ws2_32" fn setsockopt(Handle, i32, i32, *const u32, i32) callconv(.winapi) i32;
pub fn setTimeouts(fd: Handle, milliseconds: u32) void {
    _ = setsockopt(fd, 0xffff, 0x1006, &milliseconds, 4);
    _ = setsockopt(fd, 0xffff, 0x1005, &milliseconds, 4);
}
pub extern "ws2_32" fn WSAPoll([*]PollFd, u32, i32) callconv(.winapi) i32;
pub fn errno() std.posix.E {
    return mapError(WSAGetLastError());
}
fn mapError(value: i32) std.posix.E {
    return switch (value) {
        0 => .SUCCESS,
        10004 => .INTR,
        10035 => .AGAIN,
        10036 => .INPROGRESS,
        10037 => .ALREADY,
        10038 => .BADF,
        10050 => .NETDOWN,
        10051 => .NETUNREACH,
        10054 => .CONNRESET,
        10055 => .NOBUFS,
        10057 => .NOTCONN,
        10060 => .TIMEDOUT,
        10061 => .CONNREFUSED,
        10065 => .HOSTUNREACH,
        else => .IO,
    };
}
pub fn open(family: i32) !Handle {
    var data: [512]u8 align(8) = undefined;
    if (WSAStartup(0x202, &data) != 0) return error.NetworkDown;
    errdefer _ = WSACleanup();
    const fd = socket(family, 1, 6);
    if (fd == std.os.windows.INVALID_HANDLE_VALUE) return error.SocketOpenFailed;
    errdefer _ = closesocket(fd);
    var enabled: u32 = 1;
    if (ioctlsocket(fd, @bitCast(@as(u32, 0x8004667e)), &enabled) != 0) return error.SocketOptionFailed;
    return fd;
}
pub fn close(fd: Handle) void {
    _ = closesocket(fd);
    _ = WSACleanup();
}
pub fn read(fd: Handle, out: []u8) i32 {
    return recv(fd, out.ptr, @intCast(@min(out.len, 0x7fffffff)), 0);
}
pub fn write(fd: Handle, bytes: []const u8) i32 {
    return send(fd, bytes.ptr, @intCast(@min(bytes.len, 0x7fffffff)), 0);
}
pub fn socketError(fd: Handle) std.posix.E {
    var value: i32 = 0;
    var len: i32 = 4;
    if (getsockopt(fd, 0xffff, 0x1007, &value, &len) != 0) return errno();
    return mapError(value);
}

test "Windows sockets connect poll and exchange bytes on loopback" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    var listener = try (try std.Io.net.IpAddress.parseIp4("127.0.0.1", 0)).listen(io, .{});
    defer listener.deinit(io);
    const fd = try open(std.posix.AF.INET);
    defer close(fd);
    const address: std.posix.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, listener.socket.address.getPort()),
        .addr = @bitCast([4]u8{ 127, 0, 0, 1 }),
    };
    if (connect(fd, &address, @sizeOf(@TypeOf(address))) != 0) {
        const pending = errno();
        try std.testing.expect(pending == .AGAIN or pending == .INPROGRESS or pending == .ALREADY);
    }
    var poll: PollFd = .{ .fd = fd, .events = Poll.OUT, .revents = 0 };
    try std.testing.expectEqual(@as(i32, 1), WSAPoll(@ptrCast(&poll), 1, 1000));
    try std.testing.expectEqual(std.posix.E.SUCCESS, socketError(fd));
    try std.testing.expect(try @import("windows_afd.zig").readable(io, listener.socket.handle, 1000));
    const peer = try listener.accept(io);
    defer peer.close(io);
    try std.testing.expect(!try @import("windows_afd.zig").readable(io, peer.socket.handle, 1));
    try std.testing.expectEqual(@as(i32, 4), write(fd, "ping"));
    try std.testing.expect(try @import("windows_afd.zig").readable(io, peer.socket.handle, 1000));
    var bytes: [4]u8 = undefined;
    var reader = peer.reader(io, &.{});
    try reader.interface.readSliceAll(&bytes);
    try std.testing.expectEqualStrings("ping", &bytes);
    var writer = peer.writer(io, &.{});
    try writer.interface.writeAll("pong");
    poll.events = Poll.IN;
    try std.testing.expectEqual(@as(i32, 1), WSAPoll(@ptrCast(&poll), 1, 1000));
    try std.testing.expectEqual(@as(i32, 4), read(fd, &bytes));
    try std.testing.expectEqualStrings("pong", &bytes);
}
