const std = @import("std");
const w = std.os.windows;

// The upper bits carry verified access rights; the low bits are Win32 attributes.
pub const Permissions = enum(u32) {
    default_file = 0,
    _,
    pub const default_dir: @This() = .default_file;
    pub const executable_file: @This() = .default_file;
    pub const has_executable_bit = false;

    pub fn fromMode(mode: u32) @This() {
        return @fromBackingInt((mode << 16) | (if (mode & 0o222 == 0) @as(u32, 1) else 0));
    }
    pub fn toMode(self: @This()) u32 {
        const mode = @backingInt(self) >> 16;
        const access = if (mode != 0) mode else 0o777;
        return if (self.readOnly()) access & ~@as(u32, 0o222) else access;
    }
    pub fn toAttributes(self: @This()) w.FILE.ATTRIBUTE {
        return @bitCast(@backingInt(self) & 0xffff);
    }
    pub fn readOnly(self: @This()) bool {
        return @backingInt(self) & 1 != 0;
    }
    pub fn setReadOnly(self: @This(), value: bool) @This() {
        return @fromBackingInt(if (value) @backingInt(self) | 1 else @backingInt(self) & ~@as(u32, 1));
    }
};

pub extern "kernel32" fn GetConsoleMode(w.HANDLE, *u32) callconv(.winapi) i32;
pub extern "kernel32" fn SetConsoleMode(w.HANDLE, u32) callconv(.winapi) i32;
extern "kernel32" fn GetConsoleCP() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
extern "kernel32" fn SetConsoleCP(u32) callconv(.winapi) i32;
extern "kernel32" fn SetConsoleOutputCP(u32) callconv(.winapi) i32;
pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn GetConsoleScreenBufferInfo(w.HANDLE, *ScreenInfo) callconv(.winapi) i32;
extern "kernel32" fn WaitForSingleObject(w.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetFileType(w.HANDLE) callconv(.winapi) u32;
extern "kernel32" fn PeekNamedPipe(w.HANDLE, ?*anyopaque, u32, ?*u32, *u32, ?*u32) callconv(.winapi) i32;
extern "kernel32" fn PeekConsoleInputW(w.HANDLE, *InputRecord, u32, *u32) callconv(.winapi) i32;
extern "kernel32" fn ReadConsoleInputW(w.HANDLE, *InputRecord, u32, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(w.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
const Coord = extern struct { x: i16, y: i16 };
const Rect = extern struct { left: i16, top: i16, right: i16, bottom: i16 };
pub const ScreenInfo = extern struct { size: Coord, cursor: Coord, attributes: u16, window: Rect, maximum: Coord };
const KeyEvent = extern struct { down: i32, repeats: u16, key: u16, scan: u16, character: u16, modifiers: u32 };
const InputRecord = extern struct { kind: u16, event: extern union { key: KeyEvent, other: [4]u32 } };

pub fn isTerminal(handle: w.HANDLE) bool {
    var mode: u32 = 0;
    return GetConsoleMode(handle, &mode) != 0;
}
pub fn screenInfo() !ScreenInfo {
    var info: ScreenInfo = undefined;
    if (GetConsoleScreenBufferInfo(std.Io.File.stdout().handle, &info) == 0) return error.NotATerminal;
    return info;
}
pub fn poll(handle: w.HANDLE, timeout_ms: i32) !bool {
    const started = GetTickCount64();
    const console = isTerminal(handle);
    const pipe = !console and GetFileType(handle) == 3;
    while (true) {
        const elapsed = GetTickCount64() - started;
        const remaining: u32 = if (timeout_ms < 0) 0xffffffff else @intCast(@as(u64, @intCast(timeout_ms)) -| elapsed);
        if (pipe) {
            var available: u32 = 0;
            // A closed pipe must reach read(), which reports EOF.
            if (PeekNamedPipe(handle, null, 0, null, &available, null) == 0) return true;
            if (available != 0) return true;
            if (remaining == 0) return false;
            Sleep(@min(remaining, 5));
            continue;
        }
        switch (WaitForSingleObject(handle, remaining)) {
            0 => {},
            258 => return false,
            else => return error.InputOutput,
        }
        if (!console) return true;
        var record: InputRecord = undefined;
        var count: u32 = 0;
        if (PeekConsoleInputW(handle, &record, 1, &count) == 0) return error.InputOutput;
        if (count != 0) {
            if (record.kind == 1) {
                const key = record.event.key;
                if (key.down != 0 and (key.character != 0 or
                    (key.key >= 0x21 and key.key <= 0x28) or key.key == 0x2d or key.key == 0x2e or
                    (key.key >= 0x70 and key.key <= 0x87))) return true;
                // Alt-numpad input delivers its character when Alt is released.
                if (key.key == 0x12 and key.character != 0) return true;
            }
            // Focus, resize and key-up records wake the handle without giving
            // ReadFile bytes. Consume them so an idle UI never blocks on read.
            if (ReadConsoleInputW(handle, &record, 1, &count) == 0) return error.InputOutput;
        }
        if (remaining == 0) return false;
    }
}
pub fn handlePathAlloc(alloc: std.mem.Allocator, handle: w.HANDLE) ![]u8 {
    var buffer: [32768]u16 = undefined;
    const len = GetFinalPathNameByHandleW(handle, &buffer, buffer.len, 0);
    if (len == 0 or len >= buffer.len) return error.HandlePathUnavailable;
    const path = try std.unicode.wtf16LeToWtf8Alloc(alloc, buffer[0..len]);
    defer alloc.free(path);
    if (std.mem.startsWith(u8, path, "\\\\?\\UNC\\")) return alloc.print("\\\\{s}", .{path[8..]});
    return alloc.dupe(u8, if (std.mem.startsWith(u8, path, "\\\\?\\")) path[4..] else path);
}

pub const ConsoleMode = struct {
    input: u32,
    output: u32,
    input_cp: u32,
    output_cp: u32,
    pub fn capture() !ConsoleMode {
        var result: ConsoleMode = undefined;
        if (GetConsoleMode(std.Io.File.stdin().handle, &result.input) == 0 or
            GetConsoleMode(std.Io.File.stdout().handle, &result.output) == 0) return error.NotATerminal;
        result.input_cp = GetConsoleCP();
        result.output_cp = GetConsoleOutputCP();
        return result;
    }
    pub fn enable(self: ConsoleMode) !void {
        if (SetConsoleCP(65001) == 0) return error.NotATerminal;
        errdefer _ = SetConsoleCP(self.input_cp);
        if (SetConsoleOutputCP(65001) == 0) return error.NotATerminal;
        errdefer _ = SetConsoleOutputCP(self.output_cp);
        if (SetConsoleMode(std.Io.File.stdout().handle, self.output | 0x0004) == 0) return error.NotATerminal;
        errdefer _ = SetConsoleMode(std.Io.File.stdout().handle, self.output);
        if (SetConsoleMode(std.Io.File.stdin().handle, (self.input & ~@as(u32, 0x0047)) | 0x0280) == 0) return error.NotATerminal;
    }
    pub fn restore(self: ConsoleMode) void {
        _ = SetConsoleMode(std.Io.File.stdin().handle, self.input);
        _ = SetConsoleMode(std.Io.File.stdout().handle, self.output);
        _ = SetConsoleCP(self.input_cp);
        _ = SetConsoleOutputCP(self.output_cp);
    }
};
