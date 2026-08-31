//! Opens a local filesystem path in the platform default handler.
//! Used by image-chip clicks so `[Image N]` launches Preview / xdg-open /
//! `cmd start` even when the terminal ignores OSC 8 `file://` links.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const LaunchResult = struct {
    term: std.process.Child.Term,
};

const LaunchFn = *const fn (*anyopaque, Allocator, []const []const u8) anyerror!LaunchResult;

const Launcher = struct {
    ctx: *anyopaque = undefined,
    launch: LaunchFn = launchActual,
};

const LaunchOutcome = enum {
    opened,
    failed,
    unsupported,
};

fn launchActual(_: *anyopaque, _: Allocator, argv: []const []const u8) anyerror!LaunchResult {
    var child = try std.process.spawn(io_mod.getIo(), .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    const term = try child.wait(io_mod.getIo());
    return .{ .term = term };
}

fn launchPath(
    alloc: Allocator,
    path: []const u8,
    os_tag: std.Target.Os.Tag,
    launcher: Launcher,
) LaunchOutcome {
    if (path.len == 0) return .failed;

    var macos_argv = [_][]const u8{ "open", path };
    var linux_argv = [_][]const u8{ "xdg-open", path };
    var windows_argv = [_][]const u8{ "cmd.exe", "/c", "start", "", path };
    const argv: []const []const u8 = switch (os_tag) {
        .macos => &macos_argv,
        .linux => &linux_argv,
        .windows => &windows_argv,
        else => return .unsupported,
    };

    const result = launcher.launch(launcher.ctx, alloc, argv) catch |err| {
        debug_trace.logf("core", "file opener launcher failed err={s}", .{@errorName(err)});
        return .failed;
    };
    switch (result.term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }

    logUnsuccessfulTerm(result.term);
    return .failed;
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("core", "file opener unsuccessful term=exited exit_code={d}", .{code}),
        .signal => |sig| debug_trace.logf("core", "file opener unsuccessful term=signal signal={d}", .{@intFromEnum(sig)}),
        .stopped => |sig| debug_trace.logf("core", "file opener unsuccessful term=stopped signal={d}", .{@intFromEnum(sig)}),
        .unknown => |code| debug_trace.logf("core", "file opener unsuccessful term=unknown status={d}", .{code}),
    }
}

/// Launch `path` with the platform default handler. Returns false when the
/// host cannot spawn a viewer so the click is a no-op instead of a crash.
pub fn openPath(alloc: Allocator, path: []const u8) bool {
    return launchPath(alloc, path, builtin.os.tag, .{}) == .opened;
}

const MockLauncher = struct {
    argv_joined: std.ArrayList(u8) = .empty,
    result: anyerror!LaunchResult = .{ .term = .{ .exited = 0 } },

    fn launch(raw: *anyopaque, alloc: Allocator, argv: []const []const u8) anyerror!LaunchResult {
        const self: *MockLauncher = @ptrCast(@alignCast(raw));
        for (argv, 0..) |arg, i| {
            if (i > 0) try self.argv_joined.append(alloc, ' ');
            try self.argv_joined.appendSlice(alloc, arg);
        }
        return self.result;
    }

    fn launcher(self: *MockLauncher) Launcher {
        return .{ .ctx = self, .launch = launch };
    }

    fn deinit(self: *MockLauncher, alloc: Allocator) void {
        self.argv_joined.deinit(alloc);
    }
};

test "file opener selects the platform launcher argv" {
    const alloc = std.testing.allocator;

    var macos = MockLauncher{};
    defer macos.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchPath(alloc, "/tmp/pic.png", .macos, macos.launcher()));
    try std.testing.expectEqualStrings("open /tmp/pic.png", macos.argv_joined.items);

    var linux = MockLauncher{};
    defer linux.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchPath(alloc, "/tmp/pic.png", .linux, linux.launcher()));
    try std.testing.expectEqualStrings("xdg-open /tmp/pic.png", linux.argv_joined.items);

    var windows = MockLauncher{};
    defer windows.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchPath(alloc, "C:\\tmp\\pic.png", .windows, windows.launcher()));
    try std.testing.expectEqualStrings("cmd.exe /c start  C:\\tmp\\pic.png", windows.argv_joined.items);
}

test "file opener reports unsupported platforms without launching" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, launchPath(alloc, "/tmp/x", .wasi, mock.launcher()));
    try std.testing.expectEqualStrings("", mock.argv_joined.items);
}

test "file opener treats empty path, nonzero exit, and launch errors as failed" {
    const alloc = std.testing.allocator;

    var empty = MockLauncher{};
    defer empty.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchPath(alloc, "", .linux, empty.launcher()));
    try std.testing.expectEqualStrings("", empty.argv_joined.items);

    var nonzero = MockLauncher{ .result = .{ .term = .{ .exited = 3 } } };
    defer nonzero.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchPath(alloc, "/tmp/x", .macos, nonzero.launcher()));

    var erroring = MockLauncher{ .result = error.SpawnFailed };
    defer erroring.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchPath(alloc, "/tmp/x", .linux, erroring.launcher()));
}
