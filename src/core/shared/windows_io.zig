const std = @import("std");
const w = std.os.windows;
const Io = std.Io;

test {
    _ = @import("windows_socket.zig");
}

extern "advapi32" fn OpenProcessToken(w.HANDLE, u32, *w.HANDLE) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(w.HANDLE, u32, *anyopaque, u32, *u32) callconv(.winapi) i32;
extern "advapi32" fn ConvertSidToStringSidW(*anyopaque, *[*:0]u16) callconv(.winapi) i32;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW([*:0]const u16, u32, *?*anyopaque, ?*u32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorDacl(*anyopaque, *i32, *?*Acl, *i32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorOwner(*anyopaque, *?*anyopaque, *i32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityInfo(w.HANDLE, u32, u32, ?*?*anyopaque, ?*?*anyopaque, ?*?*Acl, ?*?*anyopaque, *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn SetSecurityInfo(w.HANDLE, u32, u32, ?*anyopaque, ?*anyopaque, ?*Acl, ?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetAce(*Acl, u32, *?*anyopaque) callconv(.winapi) i32;
extern "advapi32" fn EqualSid(*anyopaque, *anyopaque) callconv(.winapi) i32;
extern "advapi32" fn IsWellKnownSid(*anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn LocalFree(?*anyopaque) callconv(.winapi) ?*anyopaque;
const Acl = extern struct { revision: u8, reserved: u8, size: u16, count: u16, reserved2: u16 };
const Ace = extern struct { kind: u8, flags: u8, size: u16, mask: u32, sid: u32 };
const TokenUser = extern struct { sid: *anyopaque, attributes: u32 };

var original: *const Io.VTable = undefined;
var wrapped: Io.VTable = undefined;
var initialized = false;

pub fn wrap(io: Io) Io {
    if (!initialized) {
        original = io.vtable;
        wrapped = original.*;
        wrapped.dirCreateFile = createFile;
        wrapped.dirCreateDir = createDir;
        wrapped.dirCreateDirPath = createDirPath;
        wrapped.fileStat = fileStat;
        wrapped.dirStat = dirStat;
        wrapped.dirStatFile = statFile;
        wrapped.fileSetPermissions = setFilePermissions;
        wrapped.dirSetPermissions = setDirPermissions;
        wrapped.dirSetFilePermissions = setPathPermissions;
        wrapped.dirRename = rename;
        initialized = true;
    }
    return .{ .userdata = io.userdata, .vtable = &wrapped };
}
fn rawIo(context: ?*anyopaque) Io {
    return .{ .userdata = context, .vtable = original };
}
fn currentSid(buffer: *[512]u8) !*anyopaque {
    var token: w.HANDLE = undefined;
    if (OpenProcessToken(w.GetCurrentProcess(), 8, &token) == 0) return error.AccessDenied;
    defer w.CloseHandle(token);
    var length: u32 = 0;
    if (GetTokenInformation(token, 1, buffer, buffer.len, &length) == 0) return error.AccessDenied;
    const user: *align(1) const TokenUser = @ptrCast(buffer);
    return user.sid;
}
fn descriptor(mode: u32) !*anyopaque {
    var token: [512]u8 align(8) = undefined;
    const sid = try currentSid(&token);
    var sid_text: [*:0]u16 = undefined;
    if (ConvertSidToStringSidW(sid, &sid_text) == 0) return error.AccessDenied;
    defer _ = LocalFree(sid_text);
    var buffer: [512]u16 = undefined;
    var used: usize = 0;
    const sid_slice = std.mem.span(sid_text);
    // Elevated tokens may default to Administrators as the object owner.
    // Private storage must belong to the user even with such a token.
    const owner_prefix = std.unicode.utf8ToUtf16LeStringLiteral("O:");
    @memcpy(buffer[0..owner_prefix.len], owner_prefix);
    used += owner_prefix.len;
    if (used + sid_slice.len > buffer.len) return error.AccessDenied;
    @memcpy(buffer[used..][0..sid_slice.len], sid_slice);
    used += sid_slice.len;
    const prefix = if (mode & 0o200 != 0) std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;") else std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FR;;;");
    if (used + prefix.len > buffer.len) return error.AccessDenied;
    @memcpy(buffer[used..][0..prefix.len], prefix);
    used += prefix.len;
    if (used + sid_slice.len + 2 > buffer.len) return error.AccessDenied;
    @memcpy(buffer[used..][0..sid_slice.len], sid_slice);
    used += sid_slice.len;
    buffer[used] = ')';
    buffer[used + 1] = 0;
    var sd: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(@ptrCast(&buffer), 1, &sd, null) == 0) return error.AccessDenied;
    return sd.?;
}
fn verifiedMode(handle: w.HANDLE, directory: bool) u32 {
    var token: [512]u8 align(8) = undefined;
    const user = currentSid(&token) catch return 0o777;
    var sd: ?*anyopaque = null;
    var owner: ?*anyopaque = null;
    var acl: ?*Acl = null;
    if (GetSecurityInfo(handle, 1, 5, &owner, null, &acl, null, &sd) != 0) return 0o777;
    defer _ = LocalFree(sd);
    if (owner == null or acl == null or EqualSid(owner.?, user) == 0) return 0o777;
    var access: u32 = 0;
    for (0..acl.?.count) |index| {
        var raw_ace: ?*anyopaque = null;
        if (GetAce(acl.?, @intCast(index), &raw_ace) == 0) return 0o777;
        const ace: *Ace = @ptrCast(@alignCast(raw_ace.?));
        if (ace.flags & 8 != 0) continue;
        // A deny ACE can remove owner access; do not report stronger rights.
        if (ace.kind == 1) return 0o777;
        if (ace.kind != 0) return 0o777;
        const sid: *anyopaque = @ptrCast(&ace.sid);
        if (EqualSid(sid, user) != 0) access |= ace.mask else if (IsWellKnownSid(sid, 22) == 0 and IsWellKnownSid(sid, 26) == 0) return 0o777;
    }
    return (if (access & 1 != 0) @as(u32, 0o400) else 0) |
        (if (access & 2 != 0) @as(u32, 0o200) else 0) |
        (if (directory and access & 0x20 != 0) @as(u32, 0o100) else 0);
}
fn setMode(handle: w.HANDLE, mode: u32) !void {
    const sd = try descriptor(mode);
    defer _ = LocalFree(sd);
    try installDescriptor(handle, sd);
}

fn installDescriptor(handle: w.HANDLE, sd: *anyopaque) !void {
    var present: i32 = 0;
    var defaulted: i32 = 0;
    var acl: ?*Acl = null;
    if (GetSecurityDescriptorDacl(sd, &present, &acl, &defaulted) == 0 or present == 0) return error.AccessDenied;
    var writable: w.HANDLE = undefined;
    var status: w.IO_STATUS_BLOCK = undefined;
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = handle, .ObjectName = @constCast(&w.UNICODE_STRING.init(&.{})) };
    if (w.ntdll.NtCreateFile(&writable, @bitCast(@as(u32, 0x00060000)), &attributes, &status, null, .{}, .VALID_FLAGS, .OPEN, .{ .IO = .ASYNCHRONOUS, .OPEN_REPARSE_POINT = true, .OPEN_FOR_BACKUP_INTENT = true }, null, 0) != .SUCCESS) return error.AccessDenied;
    defer w.CloseHandle(writable);
    if (SetSecurityInfo(writable, 1, 0x80000004, null, null, acl, null) != 0) return error.AccessDenied;
}
fn fileStat(context: ?*anyopaque, file: Io.File) Io.File.StatError!Io.File.Stat {
    var result = try original.fileStat(context, file);
    if (result.kind == .file or result.kind == .directory) {
        const read_only = result.permissions.readOnly();
        result.permissions = Io.File.Permissions.fromMode(verifiedMode(file.handle, result.kind == .directory)).setReadOnly(read_only);
    }
    return result;
}
fn dirStat(context: ?*anyopaque, dir: Io.Dir) Io.Dir.StatError!Io.Dir.Stat {
    return fileStat(context, .{ .handle = dir.handle, .flags = .{ .nonblocking = false } });
}
fn statFile(context: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.StatFileOptions) Io.Dir.StatFileError!Io.File.Stat {
    var result = try original.dirStatFile(context, dir, path, options);
    if (result.kind == .file or result.kind == .directory) {
        const file = original.dirOpenFile(context, dir, path, .{ .allow_directory = true, .follow_symlinks = options.follow_symlinks }) catch return result;
        defer file.close(rawIo(context));
        const read_only = result.permissions.readOnly();
        result.permissions = Io.File.Permissions.fromMode(verifiedMode(file.handle, result.kind == .directory)).setReadOnly(read_only);
    }
    return result;
}
fn setFilePermissions(context: ?*anyopaque, file: Io.File, permissions: Io.File.Permissions) Io.File.SetPermissionsError!void {
    if (permissions.toMode() & 0o077 != 0) return original.fileSetPermissions(context, file, permissions);
    setMode(file.handle, permissions.toMode()) catch return error.AccessDenied;
}
fn setDirPermissions(context: ?*anyopaque, dir: Io.Dir, permissions: Io.Dir.Permissions) Io.Dir.SetPermissionsError!void {
    if (permissions.toMode() & 0o077 != 0) return original.dirSetPermissions(context, dir, permissions);
    setMode(dir.handle, permissions.toMode()) catch return error.AccessDenied;
}
fn setPathPermissions(context: ?*anyopaque, dir: Io.Dir, path: []const u8, permissions: Io.File.Permissions, options: Io.Dir.SetFilePermissionsOptions) Io.Dir.SetFilePermissionsError!void {
    if (permissions.toMode() & 0o077 != 0) return original.dirSetFilePermissions(context, dir, path, permissions, options);
    const file = original.dirOpenFile(context, dir, path, .{ .allow_directory = true, .follow_symlinks = options.follow_symlinks }) catch return error.AccessDenied;
    defer file.close(rawIo(context));
    setMode(file.handle, permissions.toMode()) catch return error.AccessDenied;
}
fn createFile(context: ?*anyopaque, dir: Io.Dir, path: []const u8, options: Io.Dir.CreateFileOptions) Io.File.OpenError!Io.File {
    if (options.permissions.toMode() & 0o077 == 0) {
        const handle = try createPrivate(dir, path, options.permissions.toMode(), false, options.exclusive, options.read);
        const file: Io.File = .{ .handle = handle, .flags = .{ .nonblocking = false } };
        errdefer file.close(rawIo(context));
        const stat = original.fileStat(context, file) catch return error.AccessDenied;
        if (stat.kind != .file or stat.nlink != 1) return error.AccessDenied;
        if (verifiedMode(handle, false) & 0o077 != 0) return error.AccessDenied;
        if (options.truncate) file.setLength(rawIo(context), 0) catch return error.AccessDenied;
        return file;
    }
    return original.dirCreateFile(context, dir, path, options);
}
fn createDir(context: ?*anyopaque, dir: Io.Dir, path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirError!void {
    if (permissions.toMode() & 0o077 == 0) {
        const handle = createPrivate(dir, path, permissions.toMode(), true, true, true) catch |err| return switch (err) {
            error.PathAlreadyExists => error.PathAlreadyExists,
            error.FileNotFound => error.FileNotFound,
            else => error.AccessDenied,
        };
        w.CloseHandle(handle);
        return;
    }
    try original.dirCreateDir(context, dir, path, permissions);
}

fn createPrivate(dir: Io.Dir, path: []const u8, mode: u32, directory: bool, exclusive: bool, read: bool) Io.File.OpenError!w.HANDLE {
    var utf16: [32768]u16 = undefined;
    const absolute = Io.Dir.path.isAbsolute(path);
    var offset: usize = 0;
    var rest = path;
    if (absolute) {
        const prefix = if (std.mem.startsWith(u8, path, "\\\\")) "\\??\\UNC\\" else "\\??\\";
        for (prefix) |byte| {
            utf16[offset] = byte;
            offset += 1;
        }
        if (std.mem.startsWith(u8, path, "\\\\")) rest = path[2..];
    }
    const count = w.wtf8ToWtf16Le(utf16[offset..], rest) catch return error.BadPathName;
    const name = utf16[0 .. offset + count];
    for (name) |*unit| if (unit.* == '/') {
        unit.* = '\\';
    };
    if (name.len > 32766) return error.NameTooLong;
    const sd = descriptor(mode) catch return error.AccessDenied;
    defer _ = LocalFree(sd);
    const attributes: w.OBJECT.ATTRIBUTES = .{
        .RootDirectory = if (absolute) null else dir.handle,
        .ObjectName = @constCast(&w.UNICODE_STRING.init(name)),
        .Attributes = .{ .CASE_INSENSITIVE = true },
        .SecurityDescriptor = @ptrCast(@alignCast(sd)),
    };
    var handle: w.HANDLE = undefined;
    var status: w.IO_STATUS_BLOCK = undefined;
    const result = w.ntdll.NtCreateFile(&handle, .{
        .GENERIC = .{ .READ = read or directory, .WRITE = !directory },
        .STANDARD = .{ .SYNCHRONIZE = true, .RIGHTS = .{ .READ_CONTROL = true } },
    }, &attributes, &status, null, .{ .NORMAL = true }, .VALID_FLAGS, if (exclusive) .CREATE else .OPEN_IF, .{ .DIRECTORY_FILE = directory, .NON_DIRECTORY_FILE = !directory, .IO = .SYNCHRONOUS_NONALERT, .OPEN_REPARSE_POINT = true }, null, 0);
    return switch (result) {
        .SUCCESS => handle,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .NOT_A_DIRECTORY => error.NotDir,
        .FILE_IS_A_DIRECTORY => error.IsDir,
        .SHARING_VIOLATION => error.FileBusy,
        else => error.AccessDenied,
    };
}
fn createDirPath(context: ?*anyopaque, dir: Io.Dir, path: []const u8, permissions: Io.Dir.Permissions) Io.Dir.CreateDirPathError!Io.Dir.CreatePathStatus {
    var components = Io.Dir.path.componentIterator(path);
    var status: Io.Dir.CreatePathStatus = .existed;
    while (components.next()) |component| {
        createDir(context, dir, component.path, permissions) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return err,
        };
        status = .created;
    }
    return status;
}

fn rename(context: ?*anyopaque, old_dir: Io.Dir, old_path: []const u8, new_dir: Io.Dir, new_path: []const u8) Io.Dir.RenameError!void {
    const source = original.dirOpenFile(context, old_dir, old_path, .{ .allow_directory = true, .follow_symlinks = false }) catch |err| return switch (err) {
        error.FileNotFound => error.FileNotFound,
        else => error.AccessDenied,
    };
    defer source.close(rawIo(context));
    var handle: w.HANDLE = undefined;
    var status: w.IO_STATUS_BLOCK = undefined;
    const attributes: w.OBJECT.ATTRIBUTES = .{ .RootDirectory = source.handle, .ObjectName = @constCast(&w.UNICODE_STRING.init(&.{})) };
    if (w.ntdll.NtCreateFile(&handle, @bitCast(@as(u32, 0x00010000)), &attributes, &status, null, .{}, .VALID_FLAGS, .OPEN, .{ .IO = .ASYNCHRONOUS, .OPEN_REPARSE_POINT = true, .OPEN_FOR_BACKUP_INTENT = true }, null, 0) != .SUCCESS) return error.AccessDenied;
    defer w.CloseHandle(handle);
    var utf16: [32768]u16 = undefined;
    const absolute = Io.Dir.path.isAbsolute(new_path);
    var offset: usize = 0;
    var rest = new_path;
    if (absolute) {
        const prefix = if (std.mem.startsWith(u8, new_path, "\\\\")) "\\??\\UNC\\" else "\\??\\";
        for (prefix) |byte| {
            utf16[offset] = byte;
            offset += 1;
        }
        if (std.mem.startsWith(u8, new_path, "\\\\")) rest = new_path[2..];
    }
    const count = w.wtf8ToWtf16Le(utf16[offset..], rest) catch return error.BadPathName;
    const name = utf16[0 .. offset + count];
    for (name) |*unit| if (unit.* == '/') {
        unit.* = '\\';
    };
    var information: w.FILE.RENAME_INFORMATION = .init(.{
        .Flags = .{ .REPLACE_IF_EXISTS = true, .POSIX_SEMANTICS = true, .IGNORE_READONLY_ATTRIBUTE = true },
        .RootDirectory = if (absolute) null else new_dir.handle,
        .FileName = name,
    });
    const bytes = information.toBuffer();
    const result = w.ntdll.NtSetInformationFile(handle, &status, bytes.ptr, @intCast(bytes.len), .RenameEx);
    return switch (result) {
        .SUCCESS => {},
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .DIRECTORY_NOT_EMPTY => error.DirNotEmpty,
        .NOT_SAME_DEVICE => error.CrossDevice,
        else => error.AccessDenied,
    };
}

test "Windows private descriptors explicitly name the user as owner" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    var token: [512]u8 align(8) = undefined;
    const user = try currentSid(&token);
    for ([_]u32{ 0o400, 0o600, 0o700 }) |mode| {
        const sd = try descriptor(mode);
        defer _ = LocalFree(sd);
        var owner: ?*anyopaque = null;
        var defaulted: i32 = 0;
        try std.testing.expect(GetSecurityDescriptorOwner(sd, &owner, &defaulted) != 0);
        try std.testing.expect(owner != null);
        try std.testing.expect(EqualSid(owner.?, user) != 0);
        try std.testing.expectEqual(@as(i32, 0), defaulted);
    }
}

test "Windows private storage creates and verifies owner-only ACLs" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const io = wrap(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "profile", .fromMode(0o700));
    var dir = try temporary.dir.openDir(io, "profile", .{ .iterate = true, .follow_symlinks = false });
    defer dir.close(io);
    try std.testing.expectEqual(@as(u32, 0o700), (try dir.stat(io)).permissions.toMode());
    try dir.setPermissions(io, .fromMode(0o700));
    var file = try dir.createFile(io, "settings.json", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, "{}\n");
    try file.sync(io);
    try std.testing.expectEqual(@as(u32, 0o600), (try file.stat(io)).permissions.toMode());
    try std.testing.expectEqual(@as(u32, 0o600), (try dir.statFile(io, "settings.json", .{})).permissions.toMode());
    var blob = try dir.createFile(io, "blob", .{ .read = true, .exclusive = true, .permissions = .fromMode(0o400) });
    defer blob.close(io);
    try blob.writeStreamingAll(io, "immutable");
    try std.testing.expectEqual(@as(u32, 0o400), (try blob.stat(io)).permissions.toMode());
    try dir.rename("blob", dir, "sealed-blob", io);
}

test "Windows private writes reject broad ACLs before truncating" {
    if (@import("builtin").target.os.tag != .windows) return error.SkipZigTest;
    const io = wrap(std.testing.io);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "existing", .{ .read = true, .permissions = .fromMode(0o600) });
    defer file.close(io);
    try file.writeStreamingAll(io, "keep");
    var sd: ?*anyopaque = null;
    try std.testing.expect(ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;;FA;;;WD)"), 1, &sd, null) != 0);
    defer _ = LocalFree(sd);
    try installDescriptor(file.handle, sd.?);
    try std.testing.expect((try file.stat(io)).permissions.toMode() & 0o077 != 0);
    try std.testing.expectError(error.AccessDenied, temporary.dir.createFile(io, "existing", .{ .permissions = .fromMode(0o600), .truncate = true }));
    try std.testing.expectEqual(@as(u64, 4), (try file.stat(io)).size);
}
