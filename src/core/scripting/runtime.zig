const std = @import("std");
const builtin = @import("builtin");
const command_specs = @import("../slash_commands/command_specs.zig");
const hooks = @import("../hooks/hooks.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const SlashSpec = command_specs.SlashSpec;
const SlashRegistry = command_specs.SlashRegistry;

pub const enabled = !host_target.is_wasm;

const lua = if (enabled) @import("lua.zig") else struct {
    pub const State = opaque {};
    pub const CFunction = *const fn (L: ?*State) callconv(.c) c_int;
};

pub const Notice = struct {
    tone: types.NoticeTone,
    body: []u8,
};

pub const LspStartSpec = struct {
    name: []const u8,
    argv: []const []const u8,
    root: []const u8,
};

pub const DiffFile = struct {
    path: []const u8,
    old_text: []const u8,
    new_text: []const u8,
};

pub const DiffReview = struct {
    files: []const DiffFile,
    line: ?u32 = null,
    side_by_side: bool = true,
};

pub const Host = struct {
    ctx: *anyopaque = undefined,
    notify: *const fn (ctx: *anyopaque, message: []const u8, tone: types.NoticeTone) void = silentNotify,
    model: *const fn (ctx: *anyopaque) []const u8 = emptyString,
    provider: *const fn (ctx: *anyopaque) []const u8 = emptyString,
    get_opt: *const fn (ctx: *anyopaque, alloc: Allocator, key: []const u8) anyerror!?[]u8 = missingOpt,
    set_opt: *const fn (ctx: *anyopaque, key: []const u8, value: []const u8) anyerror!void = rejectOpt,
    open_view: *const fn (ctx: *anyopaque, path: []const u8, line: ?u32) anyerror!void = rejectView,
    open_diff: *const fn (
        ctx: *anyopaque,
        path: []const u8,
        old_text: []const u8,
        new_text: []const u8,
        line: ?u32,
    ) anyerror!void = rejectDiff,
    open_review: *const fn (ctx: *anyopaque, review: DiffReview) anyerror!void = rejectReview,
    append_input: *const fn (ctx: *anyopaque, text: []const u8) anyerror!void = rejectInput,
    clipboard_image_path: *const fn (ctx: *anyopaque, alloc: Allocator) anyerror!?[]u8 = missingClipboardImage,
    attach_image: *const fn (ctx: *anyopaque, path: []const u8) anyerror!void = rejectImage,
    allow_process: *const fn (ctx: *anyopaque) bool = denyProcess,
    start_lsp: *const fn (ctx: *anyopaque, spec: LspStartSpec) anyerror!void = rejectLsp,
    stop_lsp: *const fn (ctx: *anyopaque, name: []const u8) anyerror!void = rejectLspStop,
};

const RegisteredCommand = struct {
    slash: []u8,
    description: []u8,
    lua_ref: c_int,
};

const RegisteredKeymap = struct {
    byte: u8,
    lua_ref: c_int,
};

const RegisteredHook = struct {
    kind: hooks.HookKind,
    lua_ref: c_int,
};

const RegisteredPasteHook = struct {
    lua_ref: c_int,
};

pub const Runtime = struct {
    alloc: Allocator = std.heap.page_allocator,
    host: Host = .{},
    mutex: std.Io.Mutex = .init,
    state: ?*lua.State = null,
    home: []u8 = &.{},
    workspace_root: []u8 = &.{},
    builtin_specs: []const SlashSpec = &.{},
    combined_specs: []SlashSpec = &.{},
    loaded_files: std.ArrayList([]u8) = .empty,
    commands: std.ArrayList(RegisteredCommand) = .empty,
    keymaps: std.ArrayList(RegisteredKeymap) = .empty,
    lua_hooks: std.ArrayList(RegisteredHook) = .empty,
    paste_hooks: std.ArrayList(RegisteredPasteHook) = .empty,
    notices: std.ArrayList(Notice) = .empty,
    hook_text: std.ArrayList(u8) = .empty,

    pub fn init(alloc: Allocator) Runtime {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Runtime) void {
        self.closeState();
        self.freeOwned();
        self.* = .{ .alloc = self.alloc };
    }

    pub fn setBuiltinSlashSpecs(self: *Runtime, specs: []const SlashSpec) void {
        self.builtin_specs = specs;
    }

    pub fn slashRegistry(self: *const Runtime, builtins: SlashRegistry) SlashRegistry {
        if (self.combined_specs.len == 0) return builtins;
        return .{ .commands = self.combined_specs };
    }

    pub fn bindHost(self: *Runtime, host: Host) void {
        self.host = host;
    }

    pub fn loadInit(self: *Runtime, home: ?[]const u8, workspace_root: []const u8) void {
        if (comptime !enabled) return;
        if (workspace_root.len == 0) return;
        self.lock();
        defer self.unlock();
        self.resetSession(home, workspace_root);
        self.ensureState() catch |err| {
            self.addNotice(.@"error", "Lua runtime failed to start ({s}).", .{@errorName(err)}) catch {};
            return;
        };
        if (home) |home_dir| {
            if (profile_paths.initLuaPath(self.alloc, home_dir)) |path| {
                defer self.alloc.free(path);
                self.loadFile(path);
            } else |_| {}
        }
        if (profile_paths.workspaceInitLuaPath(self.alloc, workspace_root)) |path| {
            defer self.alloc.free(path);
            self.loadFile(path);
        } else |_| {}
        self.rebuildCombinedSpecs() catch {};
    }

    pub fn reload(self: *Runtime) void {
        if (comptime !enabled) return;
        const home = if (self.home.len == 0) null else self.home;
        const workspace = self.alloc.dupe(u8, self.workspace_root) catch {
            self.addNotice(.@"error", "Lua reload failed (OutOfMemory).", .{}) catch {};
            return;
        };
        defer self.alloc.free(workspace);
        var home_copy: ?[]u8 = null;
        defer if (home_copy) |value| self.alloc.free(value);
        if (home) |dir| {
            home_copy = self.alloc.dupe(u8, dir) catch {
                self.addNotice(.@"error", "Lua reload failed (OutOfMemory).", .{}) catch {};
                return;
            };
        }
        self.loadInit(if (home_copy) |dir| dir else null, workspace);
    }

    pub fn statusText(self: *const Runtime, alloc: Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(alloc);
        defer out.deinit();
        if (comptime !enabled) {
            try out.writer.writeAll("Lua is not available on this host.");
            return out.toOwnedSlice();
        }
        if (self.state == null) {
            try out.writer.writeAll("Lua is not loaded.");
            return out.toOwnedSlice();
        }
        try out.writer.writeAll("Loaded:");
        if (self.loaded_files.items.len == 0) {
            try out.writer.writeAll("\n  (none)");
        } else {
            for (self.loaded_files.items) |path| {
                try out.writer.writeAll("\n  ");
                try out.writer.writeAll(path);
            }
        }
        try out.writer.writeAll("\nCommands:");
        if (self.commands.items.len == 0) {
            try out.writer.writeAll("\n  (none)");
        } else {
            for (self.commands.items) |command| {
                try out.writer.writeAll("\n  ");
                try out.writer.writeAll(command.slash);
                if (command.description.len > 0) {
                    try out.writer.writeAll("  ");
                    try out.writer.writeAll(command.description);
                }
            }
        }
        return out.toOwnedSlice();
    }

    pub fn takeNotices(self: *Runtime) []Notice {
        const items = self.notices.toOwnedSlice(self.alloc) catch return &.{};
        self.notices = .empty;
        return items;
    }

    pub fn freeNotices(self: *Runtime, items: []Notice) void {
        for (items) |notice| self.alloc.free(notice.body);
        if (items.len > 0) self.alloc.free(items);
    }

    pub fn hasCommand(self: *const Runtime, slash: []const u8) bool {
        return self.findCommand(slash) != null;
    }

    pub fn invokeCommand(self: *Runtime, slash: []const u8, payload: []const u8) void {
        if (comptime !enabled) return;
        const command = self.findCommand(slash) orelse {
            self.addNotice(.@"error", "Unknown Lua command {s}.", .{slash}) catch {};
            return;
        };
        const L = self.state orelse return;
        self.lock();
        defer self.unlock();
        if (!lua.checkstack(L, 4)) {
            self.addNotice(.@"error", "Lua stack overflow while running {s}.", .{slash}) catch {};
            return;
        }
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, command.lua_ref);
        lua.pushslice(L, payload);
        if (lua.pcall(L, 1, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua command failed";
            self.addNotice(.@"error", "{s}: {s}", .{ slash, err }) catch {};
            lua.pop(L, 1);
        }
    }

    pub fn dispatchKeymap(self: *Runtime, byte: u8) bool {
        if (comptime !enabled) return false;
        const keymap = self.findKeymap(byte) orelse return false;
        const L = self.state orelse return false;
        self.lock();
        defer self.unlock();
        if (!lua.checkstack(L, 2)) return false;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, keymap.lua_ref);
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua keymap failed";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
        }
        return true;
    }

    pub fn dispatchPaste(self: *Runtime, source: []const u8, text: ?[]const u8) bool {
        if (comptime !enabled) return false;
        if (self.paste_hooks.items.len == 0) return false;
        const L = self.state orelse return false;
        self.lock();
        defer self.unlock();
        var consumed = false;
        for (self.paste_hooks.items) |hook| {
            if (!lua.checkstack(L, 4)) {
                self.addNotice(.@"error", "Lua stack overflow while running a paste hook.", .{}) catch {};
                continue;
            }
            _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
            lua.newtable(L);
            lua.pushslice(L, source);
            lua.lua_setfield(L, -2, "source");
            if (text) |value| {
                lua.pushslice(L, value);
                lua.lua_setfield(L, -2, "text");
            }
            if (lua.pcall(L, 1, 1, 0) != lua.OK) {
                const err = lua.tostring(L, -1) orelse "Lua paste hook failed";
                self.addNotice(.@"error", "{s}", .{err}) catch {};
                lua.pop(L, 1);
                continue;
            }
            if (lua.lua_toboolean(L, -1) != 0) consumed = true;
            lua.pop(L, 1);
            if (consumed) break;
        }
        return consumed;
    }

    pub fn registerLifecycleHooks(self: *Runtime, lifecycle: *hooks.Runtime) !void {
        if (comptime !enabled) return;
        try lifecycle.registerPreToolUse(.{
            .name = "fx.lua.pre_tool_use",
            .ctx = self,
            .run = preToolUseTrampoline,
        });
        try lifecycle.registerStop(.{
            .name = "fx.lua.stop",
            .ctx = self,
            .run = stopTrampoline,
        });
        try lifecycle.registerPostTurnEnd(.{
            .name = "fx.lua.post_turn_end",
            .ctx = self,
            .run = postTurnEndTrampoline,
        });
        try lifecycle.registerAttentionRequired(.{
            .name = "fx.lua.attention_required",
            .ctx = self,
            .run = attentionRequiredTrampoline,
        });
    }

    fn resetSession(self: *Runtime, home: ?[]const u8, workspace_root: []const u8) void {
        self.closeState();
        self.clearRegistrations();
        if (self.home.len > 0) {
            self.alloc.free(self.home);
            self.home = &.{};
        }
        if (self.workspace_root.len > 0) {
            self.alloc.free(self.workspace_root);
            self.workspace_root = &.{};
        }
        if (home) |dir| {
            self.home = self.alloc.dupe(u8, dir) catch &.{};
        }
        self.workspace_root = self.alloc.dupe(u8, workspace_root) catch &.{};
    }

    fn ensureState(self: *Runtime) !void {
        if (comptime !enabled) return;
        if (self.state != null) return;
        const L = lua.luaL_newstate() orelse return error.LuaInitFailed;
        errdefer lua.lua_close(L);
        lua.extraspace(L).* = self;
        lua.luaL_openlibs(L);
        self.installSandbox(L);
        self.installApi(L);
        self.state = L;
    }

    fn closeState(self: *Runtime) void {
        if (comptime !enabled) return;
        if (self.state) |L| {
            lua.lua_close(L);
            self.state = null;
        }
    }

    fn clearRegistrations(self: *Runtime) void {
        for (self.loaded_files.items) |path| self.alloc.free(path);
        self.loaded_files.clearRetainingCapacity();
        for (self.commands.items) |command| {
            self.alloc.free(command.slash);
            self.alloc.free(command.description);
        }
        self.commands.clearRetainingCapacity();
        self.keymaps.clearRetainingCapacity();
        self.lua_hooks.clearRetainingCapacity();
        self.paste_hooks.clearRetainingCapacity();
        if (self.combined_specs.len > 0) {
            self.alloc.free(self.combined_specs);
            self.combined_specs = &.{};
        }
    }

    fn freeOwned(self: *Runtime) void {
        self.clearRegistrations();
        self.loaded_files.deinit(self.alloc);
        self.commands.deinit(self.alloc);
        self.keymaps.deinit(self.alloc);
        self.lua_hooks.deinit(self.alloc);
        self.paste_hooks.deinit(self.alloc);
        self.hook_text.deinit(self.alloc);
        self.freeNotices(self.takeNotices());
        self.notices.deinit(self.alloc);
        if (self.home.len > 0) self.alloc.free(self.home);
        if (self.workspace_root.len > 0) self.alloc.free(self.workspace_root);
        self.home = &.{};
        self.workspace_root = &.{};
    }

    fn loadFile(self: *Runtime, path: []const u8) void {
        if (comptime !enabled) return;
        const L = self.state orelse return;
        std.Io.Dir.accessAbsolute(io_mod.getIo(), path, .{}) catch return;
        const path_z = self.alloc.dupeZ(u8, path) catch {
            self.addNotice(.@"error", "Lua failed to load {s} (OutOfMemory).", .{path}) catch {};
            return;
        };
        defer self.alloc.free(path_z);
        if (lua.luaL_loadfilex(L, path_z, null) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "failed to load Lua file";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
            return;
        }
        if (lua.pcall(L, 0, 0, 0) != lua.OK) {
            const err = lua.tostring(L, -1) orelse "Lua file failed";
            self.addNotice(.@"error", "{s}", .{err}) catch {};
            lua.pop(L, 1);
            return;
        }
        const copied = self.alloc.dupe(u8, path) catch return;
        self.loaded_files.append(self.alloc, copied) catch {
            self.alloc.free(copied);
        };
    }

    fn rebuildCombinedSpecs(self: *Runtime) !void {
        if (self.combined_specs.len > 0) {
            self.alloc.free(self.combined_specs);
            self.combined_specs = &.{};
        }
        if (self.commands.items.len == 0) return;
        const builtins = self.builtin_specs;
        const next = try self.alloc.alloc(SlashSpec, builtins.len + self.commands.items.len);
        if (builtins.len > 0) @memcpy(next[0..builtins.len], builtins);
        for (self.commands.items, 0..) |command, i| {
            next[builtins.len + i] = .{
                .kind = .lua,
                .command = command.slash,
                .help_entry = command.slash,
                .completion_description = if (command.description.len == 0)
                    "Lua command"
                else
                    command.description,
                .presentation_category = .extensions,
                .has_args = true,
                .accepts_payload = true,
            };
        }
        self.combined_specs = next;
    }

    fn findCommand(self: *const Runtime, slash: []const u8) ?*const RegisteredCommand {
        for (self.commands.items) |*command| {
            if (std.mem.eql(u8, command.slash, slash)) return command;
        }
        return null;
    }

    fn findKeymap(self: *const Runtime, byte: u8) ?*const RegisteredKeymap {
        var i = self.keymaps.items.len;
        while (i > 0) {
            i -= 1;
            if (self.keymaps.items[i].byte == byte) return &self.keymaps.items[i];
        }
        return null;
    }

    fn addNotice(self: *Runtime, tone: types.NoticeTone, comptime fmt: []const u8, args: anytype) !void {
        const body = try std.fmt.allocPrint(self.alloc, fmt, args);
        errdefer self.alloc.free(body);
        try self.notices.append(self.alloc, .{ .tone = tone, .body = body });
    }

    fn lock(self: *Runtime) void {
        self.mutex.lockUncancelable(io_mod.getIo());
    }

    fn unlock(self: *Runtime) void {
        self.mutex.unlock(io_mod.getIo());
    }

    fn current(L: ?*lua.State) ?*Runtime {
        if (comptime !enabled) return null;
        const state = L orelse return null;
        const extra = lua.extraspace(state).*;
        return @ptrCast(@alignCast(extra orelse return null));
    }

    fn installSandbox(self: *Runtime, L: *lua.State) void {
        if (comptime !enabled) return;
        _ = lua.lua_getglobal(L, "os");
        if (lua.istable(L, -1)) {
            wrapField(L, "execute", sandboxedExecute);
            wrapField(L, "remove", sandboxedDenied);
            wrapField(L, "rename", sandboxedDenied);
        }
        lua.pop(L, 1);

        _ = lua.lua_getglobal(L, "io");
        if (lua.istable(L, -1)) {
            wrapField(L, "popen", sandboxedPopen);
            wrapField(L, "open", sandboxedOpen);
        }
        lua.pop(L, 1);

        lua.pushcfunction(L, sandboxedLoadfile);
        lua.lua_setglobal(L, "loadfile");
        lua.pushcfunction(L, sandboxedDofile);
        lua.lua_setglobal(L, "dofile");

        _ = lua.lua_getglobal(L, "package");
        if (lua.istable(L, -1)) {
            const path = self.packagePath() catch "";
            defer if (path.len > 0) self.alloc.free(path);
            lua.pushslice(L, path);
            lua.lua_setfield(L, -2, "path");
            _ = lua.lua_pushstring(L, "");
            lua.lua_setfield(L, -2, "cpath");
            lua.pushcfunction(L, sandboxedLoadlib);
            lua.lua_setfield(L, -2, "loadlib");
            _ = lua.lua_getfield(L, -1, "searchers");
            if (lua.istable(L, -1)) {
                lua.lua_pushnil(L);
                lua.lua_rawseti(L, -2, 3);
                lua.lua_pushnil(L);
                lua.lua_rawseti(L, -2, 4);
            }
            lua.pop(L, 1);
        }
        lua.pop(L, 1);
    }

    fn wrapField(L: *lua.State, name: [*:0]const u8, replacement: lua.CFunction) void {
        _ = lua.lua_getfield(L, -1, name);
        lua.lua_pushcclosure(L, replacement, 1);
        lua.lua_setfield(L, -2, name);
    }

    fn packagePath(self: *Runtime) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.alloc);
        defer out.deinit();
        var first = true;
        if (self.home.len > 0) {
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/lua/?/init.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/pack/?/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.home, ".fx/pack/?/lua/?/init.lua");
        }
        if (self.workspace_root.len > 0) {
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/lua/?/init.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, ".fx/?/init.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, "lua/?.lua");
            try appendPackageEntry(&out.writer, &first, self.workspace_root, "lua/?/init.lua");
        }
        return out.toOwnedSlice();
    }

    fn installApi(self: *Runtime, L: *lua.State) void {
        _ = self;
        if (comptime !enabled) return;
        lua.newtable(L);
        lua.pushcfunction(L, apiCommand);
        lua.lua_setfield(L, -2, "command");
        lua.pushcfunction(L, apiKeymap);
        lua.lua_setfield(L, -2, "keymap");
        lua.pushcfunction(L, apiHook);
        lua.lua_setfield(L, -2, "hook");
        lua.pushcfunction(L, apiNotify);
        lua.lua_setfield(L, -2, "notify");
        lua.pushcfunction(L, apiModel);
        lua.lua_setfield(L, -2, "model");
        lua.pushcfunction(L, apiProvider);
        lua.lua_setfield(L, -2, "provider");

        lua.newtable(L);
        lua.newtable(L);
        lua.pushcfunction(L, apiOptIndex);
        lua.lua_setfield(L, -2, "__index");
        lua.pushcfunction(L, apiOptNewindex);
        lua.lua_setfield(L, -2, "__newindex");
        _ = lua.lua_setmetatable(L, -2);
        lua.lua_setfield(L, -2, "opt");

        lua.newtable(L);
        lua.pushcfunction(L, apiViewOpen);
        lua.lua_setfield(L, -2, "open");
        lua.pushcfunction(L, apiViewDiff);
        lua.lua_setfield(L, -2, "diff");
        lua.lua_setfield(L, -2, "view");

        lua.newtable(L);
        lua.pushcfunction(L, apiInputAppend);
        lua.lua_setfield(L, -2, "append");
        lua.lua_setfield(L, -2, "input");

        lua.newtable(L);
        lua.pushcfunction(L, apiPasteHook);
        lua.lua_setfield(L, -2, "hook");
        lua.lua_setfield(L, -2, "paste");

        lua.newtable(L);
        lua.pushcfunction(L, apiClipboardImagePath);
        lua.lua_setfield(L, -2, "image_path");
        lua.lua_setfield(L, -2, "clipboard");

        lua.newtable(L);
        lua.pushcfunction(L, apiImageAttach);
        lua.lua_setfield(L, -2, "attach");
        lua.lua_setfield(L, -2, "image");

        lua.newtable(L);
        lua.pushcfunction(L, apiLspStart);
        lua.lua_setfield(L, -2, "start");
        lua.pushcfunction(L, apiLspStop);
        lua.lua_setfield(L, -2, "stop");
        lua.lua_setfield(L, -2, "lsp");

        lua.newtable(L);
        lua.newtable(L);
        lua.pushcfunction(L, apiWorkspaceIndex);
        lua.lua_setfield(L, -2, "__index");
        _ = lua.lua_setmetatable(L, -2);
        lua.lua_setfield(L, -2, "workspace");

        lua.lua_setglobal(L, "fx");
    }

    fn pathAllowed(self: *const Runtime, path: []const u8) bool {
        if (path.len == 0 or std.mem.findScalar(u8, path, 0) != null) return false;
        if (io_mod.realpathAlloc(self.alloc, path)) |resolved| {
            defer self.alloc.free(resolved);
            return self.absoluteAllowed(resolved);
        } else |_| {}
        return self.lexicalAllowed(path);
    }

    fn absoluteAllowed(self: *const Runtime, path: []const u8) bool {
        if (self.home.len > 0) {
            if (underJoin(self.alloc, self.home, ".fx/lua", path)) return true;
            if (underJoin(self.alloc, self.home, ".fx/pack", path)) return true;
        }
        if (self.workspace_root.len > 0) {
            if (underJoin(self.alloc, self.workspace_root, ".fx", path)) return true;
            if (underJoin(self.alloc, self.workspace_root, "lua", path)) return true;
        }
        return false;
    }

    fn lexicalAllowed(self: *const Runtime, path: []const u8) bool {
        if (std.fs.path.isAbsolute(path)) return self.absoluteAllowed(path);
        var roots: [3][]const u8 = undefined;
        var count: usize = 0;
        if (self.home.len > 0) {
            roots[count] = self.home;
            count += 1;
        }
        if (self.workspace_root.len > 0) {
            roots[count] = self.workspace_root;
            count += 1;
        }
        for (roots[0..count]) |root| {
            const joined = std.fs.path.join(self.alloc, &.{ root, path }) catch continue;
            defer self.alloc.free(joined);
            if (self.absoluteAllowed(joined)) return true;
        }
        return false;
    }
};

fn appendPackageEntry(writer: *std.Io.Writer, first: *bool, root: []const u8, rel: []const u8) !void {
    if (!first.*) try writer.writeByte(';');
    first.* = false;
    try writer.writeAll(root);
    if (root.len > 0 and root[root.len - 1] != std.fs.path.sep) try writer.writeByte(std.fs.path.sep);
    try writer.writeAll(rel);
}

fn underJoin(alloc: Allocator, root: []const u8, rel: []const u8, path: []const u8) bool {
    const prefix = std.fs.path.join(alloc, &.{ root, rel }) catch return false;
    defer alloc.free(prefix);
    return isUnder(path, prefix);
}

fn isUnder(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == std.fs.path.sep;
}

fn silentNotify(_: *anyopaque, _: []const u8, _: types.NoticeTone) void {}
fn emptyString(_: *anyopaque) []const u8 {
    return "";
}
fn denyProcess(_: *anyopaque) bool {
    return false;
}
fn missingOpt(_: *anyopaque, _: Allocator, _: []const u8) anyerror!?[]u8 {
    return null;
}
fn rejectOpt(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {
    return error.Unsupported;
}
fn rejectView(_: *anyopaque, _: []const u8, _: ?u32) anyerror!void {
    return error.Unsupported;
}
fn rejectDiff(_: *anyopaque, _: []const u8, _: []const u8, _: []const u8, _: ?u32) anyerror!void {
    return error.Unsupported;
}
fn rejectReview(_: *anyopaque, _: DiffReview) anyerror!void {
    return error.Unsupported;
}
fn rejectInput(_: *anyopaque, _: []const u8) anyerror!void {
    return error.Unsupported;
}
fn missingClipboardImage(_: *anyopaque, _: Allocator) anyerror!?[]u8 {
    return null;
}
fn rejectImage(_: *anyopaque, _: []const u8) anyerror!void {
    return error.Unsupported;
}
fn rejectLsp(_: *anyopaque, _: LspStartSpec) anyerror!void {
    return error.LspUnavailable;
}
fn rejectLspStop(_: *anyopaque, _: []const u8) anyerror!void {
    return error.LspUnavailable;
}

fn sandboxedDenied(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    return lua.raise(L, "this Lua function is not permitted");
}

fn sandboxedExecute(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (!rt.host.allow_process(rt.host.ctx)) {
        return lua.raise(L, "os.execute is not permitted");
    }
    return callUpvalue(L);
}

fn sandboxedPopen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (!rt.host.allow_process(rt.host.ctx)) {
        return lua.raise(L, "io.popen is not permitted");
    }
    return callUpvalue(L);
}

fn sandboxedOpen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "io.open requires a path");
    if (!rt.pathAllowed(path)) {
        return lua.raise(L, "file is outside the Lua sandbox");
    }
    return callUpvalue(L);
}

fn sandboxedLoadfile(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (lua.isnoneornil(L, 1)) return lua.raise(L, "loadfile requires a path");
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "loadfile requires a path");
    if (!rt.pathAllowed(path)) {
        return lua.raise(L, "file is outside the Lua sandbox");
    }
    const path_z = rt.alloc.dupeZ(u8, path) catch return lua.raise(L, "OutOfMemory");
    defer rt.alloc.free(path_z);
    const mode: ?[*:0]const u8 = if (lua.isnoneornil(L, 2)) null else blk: {
        const text = lua.tostring(L, 2) orelse break :blk null;
        break :blk @ptrCast(text.ptr);
    };
    const status = lua.luaL_loadfilex(L, path_z, mode);
    if (status != lua.OK) return 1;
    return 1;
}

fn sandboxedDofile(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const top = lua.lua_gettop(L);
    lua.lua_settop(L, 1);
    _ = sandboxedLoadfile(L);
    if (lua.lua_type(L, -1) != lua.TFUNCTION) return 1;
    const status = lua.pcall(L, 0, lua.MULTRET, 0);
    if (status != lua.OK) return lua.lua_error(L);
    return lua.lua_gettop(L) - top + 1;
}

fn sandboxedLoadlib(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    return lua.raise(L, "package.loadlib is not permitted");
}

fn callUpvalue(L: ?*lua.State) c_int {
    const nargs = lua.lua_gettop(L);
    lua.lua_pushvalue(L, lua.upvalue(1));
    lua.insert(L, 1);
    lua.lua_callk(L, nargs, lua.MULTRET, 0, null);
    return lua.lua_gettop(L);
}

fn apiCommand(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const name = lua.tostring(L, 1) orelse return lua.raise(L, "command name required");
    const slash = normalizeCommandName(rt.alloc, name) catch |err| switch (err) {
        error.InvalidCommandName => return lua.raise(L, "invalid Lua command name"),
        error.OutOfMemory => return lua.raise(L, "OutOfMemory"),
    };
    errdefer rt.alloc.free(slash);
    if (rt.findCommand(slash) != null or builtinHasCommand(rt.builtin_specs, slash)) {
        rt.alloc.free(slash);
        return lua.raise(L, "command is already registered");
    }
    var description: []u8 = &.{};
    if (lua.istable(L, 3)) {
        _ = lua.lua_getfield(L, 3, "desc");
        if (lua.isnoneornil(L, -1)) {
            lua.pop(L, 1);
            _ = lua.lua_getfield(L, 3, "description");
        }
        if (lua.tostring(L, -1)) |text| {
            description = rt.alloc.dupe(u8, text) catch {
                rt.alloc.free(slash);
                return lua.raise(L, "OutOfMemory");
            };
        }
        lua.pop(L, 1);
    }
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.commands.append(rt.alloc, .{
        .slash = slash,
        .description = description,
        .lua_ref = ref,
    }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        rt.alloc.free(slash);
        if (description.len > 0) rt.alloc.free(description);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiKeymap(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const lhs = lua.tostring(L, 1) orelse return lua.raise(L, "keymap lhs required");
    const byte = parseKeymapLhs(lhs) orelse return lua.raise(L, "unsupported keymap");
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.keymaps.append(rt.alloc, .{ .byte = byte, .lua_ref = ref }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiHook(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TFUNCTION);
    const kind_name = lua.tostring(L, 1) orelse return lua.raise(L, "hook kind required");
    const kind = std.meta.stringToEnum(hooks.HookKind, kind_name) orelse
        return lua.raise(L, "unknown hook kind");
    lua.lua_pushvalue(L, 2);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.lua_hooks.append(rt.alloc, .{ .kind = kind, .lua_ref = ref }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiNotify(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const message = lua.tostring(L, 1) orelse return 0;
    var tone: types.NoticeTone = .neutral;
    if (lua.istable(L, 2)) {
        _ = lua.lua_getfield(L, 2, "tone");
        if (lua.tostring(L, -1)) |name| {
            tone = std.meta.stringToEnum(types.NoticeTone, name) orelse .neutral;
        }
        lua.pop(L, 1);
    }
    rt.host.notify(rt.host.ctx, message, tone);
    return 0;
}

fn apiModel(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.pushslice(L, rt.host.model(rt.host.ctx));
    return 1;
}

fn apiProvider(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const value = rt.host.get_opt(rt.host.ctx, rt.alloc, "provider") catch {
        lua.pushslice(L, "openai_compatible");
        return 1;
    } orelse {
        lua.pushslice(L, rt.host.provider(rt.host.ctx));
        return 1;
    };
    defer rt.alloc.free(value);
    lua.pushslice(L, value);
    return 1;
}

fn apiOptIndex(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const key = lua.tostring(L, 2) orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    const value = rt.host.get_opt(rt.host.ctx, rt.alloc, key) catch {
        lua.lua_pushnil(L);
        return 1;
    } orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    defer rt.alloc.free(value);
    lua.pushslice(L, value);
    return 1;
}

fn apiOptNewindex(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const key = lua.tostring(L, 2) orelse return lua.raise(L, "setting name required");
    const value = if (lua.lua_type(L, 3) == lua.TBOOLEAN)
        if (lua.lua_toboolean(L, 3) != 0) "on" else "off"
    else
        lua.tostring(L, 3) orelse return lua.raise(L, "setting value required");
    rt.host.set_opt(rt.host.ctx, key, value) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn optionalLineArg(L: ?*lua.State, idx: c_int) ?u32 {
    if (lua.lua_gettop(L) < idx or !lua.istable(L, idx)) return null;
    _ = lua.lua_getfield(L, idx, "line");
    defer lua.pop(L, 1);
    if (lua.lua_type(L, -1) != lua.TNUMBER) return null;
    const value = lua.tointeger(L, -1);
    if (value > 0 and value <= std.math.maxInt(u32)) return @intCast(value);
    return null;
}

fn apiViewOpen(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "path required");
    const line = optionalLineArg(L, 2);
    rt.host.open_view(rt.host.ctx, path, line) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn apiViewDiff(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    if (lua.istable(L, 1)) return apiViewDiffReview(L, rt);
    lua.luaL_checktype(L, 1, lua.TSTRING);
    lua.luaL_checktype(L, 2, lua.TSTRING);
    lua.luaL_checktype(L, 3, lua.TSTRING);
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "path required");
    const old_text = lua.tostring(L, 2) orelse return lua.raise(L, "old text required");
    const new_text = lua.tostring(L, 3) orelse return lua.raise(L, "new text required");
    const line = optionalLineArg(L, 4);
    rt.host.open_diff(rt.host.ctx, path, old_text, new_text, line) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn apiViewDiffReview(L: ?*lua.State, rt: *Runtime) c_int {
    _ = lua.lua_getfield(L, 1, "files");
    if (!lua.istable(L, -1)) {
        lua.pop(L, 1);
        return lua.raise(L, "files required");
    }
    const files_idx = lua.lua_absindex(L, -1);
    var files: std.ArrayList(DiffFile) = .empty;
    defer files.deinit(rt.alloc);
    var owned: std.ArrayList([]u8) = .empty;
    defer {
        for (owned.items) |item| rt.alloc.free(item);
        owned.deinit(rt.alloc);
    }

    var i: lua.Integer = 1;
    while (true) : (i += 1) {
        _ = lua.lua_rawgeti(L, files_idx, i);
        if (lua.isnoneornil(L, -1)) {
            lua.pop(L, 1);
            break;
        }
        if (!lua.istable(L, -1)) {
            lua.pop(L, 1);
            return lua.raise(L, "file entry must be a table");
        }
        const path = dupField(L, rt, -1, "path") catch {
            lua.pop(L, 1);
            return lua.raise(L, "file path required");
        };
        owned.append(rt.alloc, path) catch {
            rt.alloc.free(path);
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        const old_text = dupFieldOrEmpty(L, rt, -1, "old") catch {
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        owned.append(rt.alloc, old_text) catch {
            rt.alloc.free(old_text);
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        const new_text = dupFieldOrEmpty(L, rt, -1, "new") catch {
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        owned.append(rt.alloc, new_text) catch {
            rt.alloc.free(new_text);
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        files.append(rt.alloc, .{
            .path = path,
            .old_text = old_text,
            .new_text = new_text,
        }) catch {
            lua.pop(L, 1);
            return lua.raise(L, "OutOfMemory");
        };
        lua.pop(L, 1);
    }
    lua.pop(L, 1);
    if (files.items.len == 0) return lua.raise(L, "files required");

    var side_by_side = true;
    _ = lua.lua_getfield(L, 1, "layout");
    if (lua.tostring(L, -1)) |layout_name| {
        if (std.mem.eql(u8, layout_name, "unified")) side_by_side = false;
    }
    lua.pop(L, 1);

    rt.host.open_review(rt.host.ctx, .{
        .files = files.items,
        .line = optionalLineArg(L, 1),
        .side_by_side = side_by_side,
    }) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn apiInputAppend(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const text = lua.tostring(L, 1) orelse return lua.raise(L, "text required");
    rt.host.append_input(rt.host.ctx, text) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn apiPasteHook(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TFUNCTION);
    lua.lua_pushvalue(L, 1);
    const ref = lua.luaL_ref(L, lua.REGISTRYINDEX);
    rt.paste_hooks.append(rt.alloc, .{ .lua_ref = ref }) catch {
        lua.luaL_unref(L, lua.REGISTRYINDEX, ref);
        return lua.raise(L, "OutOfMemory");
    };
    return 0;
}

fn apiClipboardImagePath(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const path = rt.host.clipboard_image_path(rt.host.ctx, rt.alloc) catch |err| {
        return lua.raise(L, @errorName(err));
    } orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    defer rt.alloc.free(path);
    lua.pushslice(L, path);
    return 1;
}

fn apiImageAttach(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TSTRING);
    const path = lua.tostring(L, 1) orelse return lua.raise(L, "path required");
    rt.host.attach_image(rt.host.ctx, path) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn dupField(L: ?*lua.State, rt: *Runtime, idx: c_int, key: [*:0]const u8) error{ Missing, OutOfMemory }![]u8 {
    _ = lua.lua_getfield(L, idx, key);
    defer lua.pop(L, 1);
    const text = lua.tostring(L, -1) orelse return error.Missing;
    if (text.len == 0) return error.Missing;
    return rt.alloc.dupe(u8, text);
}

fn dupFieldOrEmpty(L: ?*lua.State, rt: *Runtime, idx: c_int, key: [*:0]const u8) error{OutOfMemory}![]u8 {
    _ = lua.lua_getfield(L, idx, key);
    defer lua.pop(L, 1);
    const text = lua.tostring(L, -1) orelse "";
    return rt.alloc.dupe(u8, text);
}

fn apiWorkspaceIndex(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    const key = lua.tostring(L, 2) orelse {
        lua.lua_pushnil(L);
        return 1;
    };
    if (std.mem.eql(u8, key, "root")) {
        lua.pushslice(L, rt.workspace_root);
        return 1;
    }
    lua.lua_pushnil(L);
    return 1;
}

fn apiLspStart(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    lua.luaL_checktype(L, 1, lua.TTABLE);
    _ = lua.lua_getfield(L, 1, "name");
    const name_text = lua.tostring(L, -1) orelse {
        lua.pop(L, 1);
        return lua.raise(L, "name required");
    };
    if (name_text.len == 0) {
        lua.pop(L, 1);
        return lua.raise(L, "name required");
    }
    const name = rt.alloc.dupe(u8, name_text) catch {
        lua.pop(L, 1);
        return lua.raise(L, "OutOfMemory");
    };
    lua.pop(L, 1);
    defer rt.alloc.free(name);

    var argv_store: std.ArrayList([]u8) = .empty;
    defer {
        for (argv_store.items) |item| rt.alloc.free(item);
        argv_store.deinit(rt.alloc);
    }
    _ = lua.lua_getfield(L, 1, "cmd");
    if (lua.isstring(L, -1)) {
        const cmd = lua.tostring(L, -1) orelse {
            lua.pop(L, 1);
            return lua.raise(L, "cmd required");
        };
        appendArg(&argv_store, rt.alloc, cmd) catch {
            lua.pop(L, 1);
            rt.addNotice(.@"error", "OutOfMemory", .{}) catch {};
            return 0;
        };
    } else if (lua.istable(L, -1)) {
        var index: lua.Integer = 1;
        while (true) : (index += 1) {
            _ = lua.lua_rawgeti(L, -1, index);
            if (lua.isnoneornil(L, -1)) {
                lua.pop(L, 1);
                break;
            }
            const arg = lua.tostring(L, -1) orelse {
                lua.pop(L, 1);
                rt.addNotice(.@"error", "cmd entries must be strings", .{}) catch {};
                return 0;
            };
            appendArg(&argv_store, rt.alloc, arg) catch {
                lua.pop(L, 1);
                rt.addNotice(.@"error", "OutOfMemory", .{}) catch {};
                return 0;
            };
            lua.pop(L, 1);
        }
    } else {
        lua.pop(L, 1);
        rt.addNotice(.@"error", "cmd required", .{}) catch {};
        return 0;
    }
    lua.pop(L, 1);
    if (argv_store.items.len == 0) {
        rt.addNotice(.@"error", "cmd required", .{}) catch {};
        return 0;
    }

    var root = rt.workspace_root;
    var root_owned: ?[]u8 = null;
    defer if (root_owned) |value| rt.alloc.free(value);
    _ = lua.lua_getfield(L, 1, "root");
    if (lua.tostring(L, -1)) |text| {
        if (text.len > 0) {
            root_owned = rt.alloc.dupe(u8, text) catch {
                lua.pop(L, 1);
                rt.addNotice(.@"error", "OutOfMemory", .{}) catch {};
                return 0;
            };
            root = root_owned.?;
        }
    }
    lua.pop(L, 1);

    const argv_view = rt.alloc.alloc([]const u8, argv_store.items.len) catch {
        rt.addNotice(.@"error", "OutOfMemory", .{}) catch {};
        return 0;
    };
    defer rt.alloc.free(argv_view);
    for (argv_store.items, 0..) |item, i| argv_view[i] = item;

    rt.host.start_lsp(rt.host.ctx, .{
        .name = name,
        .argv = argv_view,
        .root = root,
    }) catch |err| {
        if (err == error.PermissionDenied) {
            rt.addNotice(.@"error", "fx.lsp.start is not permitted", .{}) catch {};
            return 0;
        }
        if (err == error.LspUnavailable) {
            rt.addNotice(.@"error", "LSP is not available on this host", .{}) catch {};
            return 0;
        }
        rt.addNotice(.@"error", "{s}", .{@errorName(err)}) catch {};
        return 0;
    };
    return 0;
}

fn apiLspStop(L: ?*lua.State) callconv(.c) c_int {
    if (comptime !enabled) return 0;
    const rt = Runtime.current(L) orelse return lua.raise(L, "Lua runtime is unavailable");
    var name: []const u8 = "";
    if (!lua.isnoneornil(L, 1)) {
        if (lua.istable(L, 1)) {
            _ = lua.lua_getfield(L, 1, "name");
            name = lua.tostring(L, -1) orelse "";
        } else {
            name = lua.tostring(L, 1) orelse "";
        }
    }
    rt.host.stop_lsp(rt.host.ctx, name) catch |err| {
        return lua.raise(L, @errorName(err));
    };
    return 0;
}

fn appendArg(store: *std.ArrayList([]u8), alloc: Allocator, value: []const u8) !void {
    const copied = try alloc.dupe(u8, value);
    errdefer alloc.free(copied);
    try store.append(alloc, copied);
}

fn builtinHasCommand(specs: []const SlashSpec, slash: []const u8) bool {
    for (specs) |spec| {
        if (std.mem.eql(u8, spec.command, slash)) return true;
        for (spec.aliases) |alias| {
            if (std.mem.eql(u8, alias, slash)) return true;
        }
    }
    return false;
}

fn normalizeCommandName(alloc: Allocator, name: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, name, " \t/");
    if (trimmed.len == 0) return error.InvalidCommandName;
    if (trimmed.len > 64) return error.InvalidCommandName;
    for (trimmed, 0..) |byte, i| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
        if (!ok) return error.InvalidCommandName;
        if (i == 0 and !std.ascii.isAlphabetic(byte)) return error.InvalidCommandName;
    }
    const slash = try alloc.alloc(u8, trimmed.len + 1);
    slash[0] = '/';
    @memcpy(slash[1..], trimmed);
    return slash;
}

fn parseKeymapLhs(lhs: []const u8) ?u8 {
    const trimmed = std.mem.trim(u8, lhs, " \t");
    if (trimmed.len == 1) return trimmed[0];
    if (trimmed.len == 5 and trimmed[0] == '<' and trimmed[4] == '>' and
        (trimmed[1] == 'C' or trimmed[1] == 'c') and trimmed[2] == '-')
    {
        const letter = std.ascii.toLower(trimmed[3]);
        if (letter < 'a' or letter > 'z') return null;
        return letter - 'a' + 1;
    }
    if (eqlIgnoreCase(trimmed, "<CR>") or eqlIgnoreCase(trimmed, "<Enter>")) return '\r';
    if (eqlIgnoreCase(trimmed, "<Tab>")) return '\t';
    if (eqlIgnoreCase(trimmed, "<Esc>")) return 0x1b;
    if (eqlIgnoreCase(trimmed, "<Space>")) return ' ';
    return null;
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn preToolUseTrampoline(
    ctx: *anyopaque,
    input: hooks.PreToolUseInput,
) hooks.HandlerError!hooks.PreToolUseAction {
    if (comptime !enabled) return .continue_;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return .continue_;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != .pre_tool_use) continue;
        if (!lua.checkstack(L, 8)) return error.Failed;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        pushPreToolUseInput(L, input);
        if (lua.pcall(L, 1, 1, 0) != lua.OK) {
            lua.pop(L, 1);
            return error.Failed;
        }
        const action = readPreToolUseAction(self, L) catch {
            lua.pop(L, 1);
            return error.Failed;
        };
        lua.pop(L, 1);
        switch (action) {
            .continue_ => {},
            else => return action,
        }
    }
    return .continue_;
}

fn stopTrampoline(
    ctx: *anyopaque,
    input: hooks.StopInput,
) hooks.HandlerError!hooks.StopAction {
    if (comptime !enabled) return .allow;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return .allow;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != .stop) continue;
        if (!lua.checkstack(L, 8)) return error.Failed;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        lua.newtable(L);
        lua.pushslice(L, input.assistant_text);
        lua.lua_setfield(L, -2, "assistant_text");
        if (lua.pcall(L, 1, 1, 0) != lua.OK) {
            lua.pop(L, 1);
            return error.Failed;
        }
        if (lua.istable(L, -1)) {
            _ = lua.lua_getfield(L, -1, "action");
            const action_name = lua.tostring(L, -1) orelse "";
            lua.pop(L, 1);
            if (std.mem.eql(u8, action_name, "continue_once")) {
                _ = lua.lua_getfield(L, -1, "context");
                const context = lua.tostring(L, -1) orelse "";
                self.hook_text.clearRetainingCapacity();
                self.hook_text.appendSlice(self.alloc, context) catch {
                    lua.pop(L, 2);
                    return error.Failed;
                };
                lua.pop(L, 2);
                return .{ .continue_once = self.hook_text.items };
            }
            lua.pop(L, 1);
        } else {
            lua.pop(L, 1);
        }
    }
    return .allow;
}

fn postTurnEndTrampoline(ctx: *anyopaque, input: hooks.PostTurnEndInput) hooks.HandlerError!void {
    _ = input;
    runSideEffectHooks(ctx, .post_turn_end);
}

fn attentionRequiredTrampoline(ctx: *anyopaque, input: hooks.AttentionRequiredInput) hooks.HandlerError!void {
    _ = input;
    runSideEffectHooks(ctx, .attention_required);
}

fn runSideEffectHooks(ctx: *anyopaque, kind: hooks.HookKind) void {
    if (comptime !enabled) return;
    const self: *Runtime = @ptrCast(@alignCast(ctx));
    const L = self.state orelse return;
    self.lock();
    defer self.unlock();
    for (self.lua_hooks.items) |hook| {
        if (hook.kind != kind) continue;
        if (!lua.checkstack(L, 4)) continue;
        _ = lua.lua_rawgeti(L, lua.REGISTRYINDEX, hook.lua_ref);
        lua.newtable(L);
        if (lua.pcall(L, 1, 0, 0) != lua.OK) lua.pop(L, 1);
    }
}

fn pushPreToolUseInput(L: ?*lua.State, input: hooks.PreToolUseInput) void {
    lua.newtable(L);
    lua.pushslice(L, input.tool_name);
    lua.lua_setfield(L, -2, "tool_name");
    lua.pushslice(L, input.arguments_json);
    lua.lua_setfield(L, -2, "arguments_json");
    lua.pushslice(L, input.call_id);
    lua.lua_setfield(L, -2, "call_id");
    lua.lua_pushinteger(L, @intCast(input.step_index));
    lua.lua_setfield(L, -2, "step_index");
}

fn readPreToolUseAction(self: *Runtime, L: ?*lua.State) !hooks.PreToolUseAction {
    if (lua.isnoneornil(L, -1)) return .continue_;
    if (lua.lua_type(L, -1) == lua.TSTRING) {
        const name = lua.tostring(L, -1) orelse return .continue_;
        if (std.mem.eql(u8, name, "continue")) return .continue_;
        return error.Failed;
    }
    if (!lua.istable(L, -1)) return .continue_;
    _ = lua.lua_getfield(L, -1, "action");
    const action_name = lua.tostring(L, -1) orelse "continue";
    lua.pop(L, 1);
    if (std.mem.eql(u8, action_name, "block")) {
        _ = lua.lua_getfield(L, -1, "reason");
        const reason = lua.tostring(L, -1) orelse "blocked by Lua hook";
        self.hook_text.clearRetainingCapacity();
        try self.hook_text.appendSlice(self.alloc, reason);
        lua.pop(L, 1);
        return .{ .block = self.hook_text.items };
    }
    if (std.mem.eql(u8, action_name, "rewrite")) {
        _ = lua.lua_getfield(L, -1, "arguments");
        const arguments = lua.tostring(L, -1) orelse return error.Failed;
        self.hook_text.clearRetainingCapacity();
        try self.hook_text.appendSlice(self.alloc, arguments);
        lua.pop(L, 1);
        return .{ .rewrite_arguments = self.hook_text.items };
    }
    return .continue_;
}

test "broken init.lua is a notice and does not abort" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "this is not lua [[[");

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(null, workspace);

    try std.testing.expect(runtime.state != null);
    try std.testing.expectEqual(@as(usize, 0), runtime.loaded_files.items.len);
    try std.testing.expect(runtime.notices.items.len >= 1);
    try std.testing.expect(runtime.hasCommand("/hello") == false);
}

test "/hello from init.lua registers and runs" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("hello", function(payload)
        \\  fx.notify("hello " .. (payload or ""))
        \\end, { desc = "say hello" })
        \\
    );

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(alloc);
    const Ctx = struct {
        seen: *std.ArrayList(u8),
        alloc: Allocator,
        fn notify(raw: *anyopaque, message: []const u8, _: types.NoticeTone) void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.seen.appendSlice(ctx.alloc, message) catch {};
        }
    };
    var ctx = Ctx{ .seen = &seen, .alloc = alloc };

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .notify = Ctx.notify,
    });
    runtime.setBuiltinSlashSpecs(&.{
        .{ .kind = .help, .command = "/help" },
    });
    runtime.loadInit(null, workspace);

    try std.testing.expect(runtime.hasCommand("/hello"));
    const registry = runtime.slashRegistry(.{ .commands = &.{} });
    const spec = registry.lookup("/hello") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(command_specs.SlashKind.lua, spec.kind);
    runtime.invokeCommand("/hello", "world");
    try std.testing.expectEqualStrings("hello world", seen.items);
}

test "os.execute is denied unless the host grants process access" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), "os.execute('true')\n");

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(null, workspace);
    try std.testing.expect(runtime.notices.items.len >= 1);
    try std.testing.expect(std.mem.find(u8, runtime.notices.items[0].body, "os.execute") != null);
}

test "profile then workspace init.lua load in order" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(root);
    try tmp.dir.createDirPath(io_mod.getIo(), "home/.fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "workspace/.fx");
    var profile = try tmp.dir.createFile(io_mod.getIo(), "home/.fx/init.lua", .{});
    try profile.writeStreamingAll(io_mod.getIo(), "fx.command('from_profile', function() end)\n");
    profile.close(io_mod.getIo());
    var workspace_file = try tmp.dir.createFile(io_mod.getIo(), "workspace/.fx/init.lua", .{});
    try workspace_file.writeStreamingAll(io_mod.getIo(), "fx.command('from_workspace', function() end)\n");
    workspace_file.close(io_mod.getIo());

    const home = try std.fs.path.join(alloc, &.{ root, "home" });
    defer alloc.free(home);
    const workspace = try std.fs.path.join(alloc, &.{ root, "workspace" });
    defer alloc.free(workspace);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(home, workspace);
    try std.testing.expect(runtime.hasCommand("/from_profile"));
    try std.testing.expect(runtime.hasCommand("/from_workspace"));
    try std.testing.expectEqual(@as(usize, 2), runtime.loaded_files.items.len);
}

test "fx.view.open calls the host with an optional line" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("openit", function()
        \\  fx.view.open("src/main.zig", { line = 12 })
        \\end)
        \\
    );

    const Ctx = struct {
        path: std.ArrayList(u8),
        line: ?u32 = null,
        alloc: Allocator,
        fn open(raw: *anyopaque, path: []const u8, line: ?u32) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.path.clearRetainingCapacity();
            try ctx.path.appendSlice(ctx.alloc, path);
            ctx.line = line;
        }
    };
    var ctx = Ctx{ .path = .empty, .alloc = alloc };
    defer ctx.path.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .open_view = Ctx.open,
    });
    runtime.loadInit(null, workspace);
    runtime.invokeCommand("/openit", "");
    try std.testing.expectEqualStrings("src/main.zig", ctx.path.items);
    try std.testing.expectEqual(@as(?u32, 12), ctx.line);
}

test "fx.view.diff calls the host with old and new text" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("showdiff", function()
        \\  fx.view.diff("demo.lua", "keep\nold\n", "keep\nnew\n", { line = 2 })
        \\end)
        \\
    );

    const Ctx = struct {
        path: std.ArrayList(u8) = .empty,
        old_text: std.ArrayList(u8) = .empty,
        new_text: std.ArrayList(u8) = .empty,
        line: ?u32 = null,
        alloc: Allocator,
        fn diff(
            raw: *anyopaque,
            path: []const u8,
            old_text: []const u8,
            new_text: []const u8,
            line: ?u32,
        ) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            try ctx.path.appendSlice(ctx.alloc, path);
            try ctx.old_text.appendSlice(ctx.alloc, old_text);
            try ctx.new_text.appendSlice(ctx.alloc, new_text);
            ctx.line = line;
        }
    };
    var ctx = Ctx{ .alloc = alloc };
    defer ctx.path.deinit(alloc);
    defer ctx.old_text.deinit(alloc);
    defer ctx.new_text.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .open_diff = Ctx.diff,
    });
    runtime.loadInit(null, workspace);
    runtime.invokeCommand("/showdiff", "");
    try std.testing.expectEqualStrings("demo.lua", ctx.path.items);
    try std.testing.expectEqualStrings("keep\nold\n", ctx.old_text.items);
    try std.testing.expectEqualStrings("keep\nnew\n", ctx.new_text.items);
    try std.testing.expectEqual(@as(?u32, 2), ctx.line);
}

test "fx.view.diff review table calls the host with every file" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("showreview", function()
        \\  fx.view.diff({
        \\    files = {
        \\      { path = "a.lua", old = "old-a", new = "new-a" },
        \\      { path = "b.md", old = "old-b", new = "new-b" },
        \\    },
        \\    layout = "side",
        \\  })
        \\end)
        \\
    );

    const Ctx = struct {
        count: usize = 0,
        first_path: std.ArrayList(u8) = .empty,
        second_path: std.ArrayList(u8) = .empty,
        side_by_side: bool = false,
        alloc: Allocator,
        fn review(raw: *anyopaque, spec: DiffReview) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.count = spec.files.len;
            ctx.side_by_side = spec.side_by_side;
            if (spec.files.len >= 1) try ctx.first_path.appendSlice(ctx.alloc, spec.files[0].path);
            if (spec.files.len >= 2) try ctx.second_path.appendSlice(ctx.alloc, spec.files[1].path);
        }
    };
    var ctx = Ctx{ .alloc = alloc };
    defer ctx.first_path.deinit(alloc);
    defer ctx.second_path.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .open_review = Ctx.review,
    });
    runtime.loadInit(null, workspace);
    runtime.invokeCommand("/showreview", "");
    try std.testing.expectEqual(@as(usize, 2), ctx.count);
    try std.testing.expect(ctx.side_by_side);
    try std.testing.expectEqualStrings("a.lua", ctx.first_path.items);
    try std.testing.expectEqualStrings("b.md", ctx.second_path.items);
}

test "workspace lua plugin can require and register a command" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    try tmp.dir.createDirPath(io_mod.getIo(), "lua/diffview");
    var plugin = try tmp.dir.createFile(io_mod.getIo(), "lua/diffview/init.lua", .{});
    try plugin.writeStreamingAll(io_mod.getIo(),
        \\fx.command("diffview", function(payload)
        \\  fx.view.diff("demo.lua", "old", "new")
        \\end, { desc = "Lua plugin diff-view demo" })
        \\return true
        \\
    );
    plugin.close(io_mod.getIo());
    var init_file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer init_file.close(io_mod.getIo());
    try init_file.writeStreamingAll(io_mod.getIo(), "require(\"diffview\")\n");

    const Ctx = struct {
        path: std.ArrayList(u8) = .empty,
        old_text: std.ArrayList(u8) = .empty,
        new_text: std.ArrayList(u8) = .empty,
        alloc: Allocator,
        fn diff(
            raw: *anyopaque,
            path: []const u8,
            old_text: []const u8,
            new_text: []const u8,
            _: ?u32,
        ) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            try ctx.path.appendSlice(ctx.alloc, path);
            try ctx.old_text.appendSlice(ctx.alloc, old_text);
            try ctx.new_text.appendSlice(ctx.alloc, new_text);
        }
    };
    var ctx = Ctx{ .alloc = alloc };
    defer ctx.path.deinit(alloc);
    defer ctx.old_text.deinit(alloc);
    defer ctx.new_text.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .open_diff = Ctx.diff,
    });
    runtime.loadInit(null, workspace);
    try std.testing.expectEqual(@as(usize, 0), runtime.notices.items.len);
    try std.testing.expect(runtime.hasCommand("/diffview"));
    runtime.invokeCommand("/diffview", "");
    try std.testing.expectEqualStrings("demo.lua", ctx.path.items);
    try std.testing.expectEqualStrings("old", ctx.old_text.items);
    try std.testing.expectEqualStrings("new", ctx.new_text.items);
}

test "fx.input.append calls the host with composer text" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.command("say", function()
        \\  fx.input.append("hello from lua")
        \\end)
        \\
    );

    const Ctx = struct {
        text: std.ArrayList(u8) = .empty,
        alloc: Allocator,
        fn append(raw: *anyopaque, text: []const u8) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            try ctx.text.appendSlice(ctx.alloc, text);
        }
    };
    var ctx = Ctx{ .alloc = alloc };
    defer ctx.text.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .append_input = Ctx.append,
    });
    runtime.loadInit(null, workspace);
    runtime.invokeCommand("/say", "");
    try std.testing.expectEqualStrings("hello from lua", ctx.text.items);
}

test "fx.lsp.start passes name cmd and workspace root to the host" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.lsp.start({
        \\  name = "zls",
        \\  cmd = { "zls" },
        \\  root = fx.workspace.root,
        \\})
        \\
    );

    const Ctx = struct {
        name: std.ArrayList(u8) = .empty,
        cmd: std.ArrayList(u8) = .empty,
        root: std.ArrayList(u8) = .empty,
        alloc: Allocator,
        fn start(raw: *anyopaque, spec: LspStartSpec) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            try ctx.name.appendSlice(ctx.alloc, spec.name);
            try ctx.cmd.appendSlice(ctx.alloc, spec.argv[0]);
            try ctx.root.appendSlice(ctx.alloc, spec.root);
        }
    };
    var ctx = Ctx{ .alloc = alloc };
    defer ctx.name.deinit(alloc);
    defer ctx.cmd.deinit(alloc);
    defer ctx.root.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .start_lsp = Ctx.start,
    });
    runtime.loadInit(null, workspace);
    try std.testing.expectEqual(@as(usize, 0), runtime.notices.items.len);
    try std.testing.expectEqualStrings("zls", ctx.name.items);
    try std.testing.expectEqualStrings("zls", ctx.cmd.items);
    try std.testing.expectEqualStrings(workspace, ctx.root.items);
}

test "fx.lsp.start is a notice when the host denies process spawn" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.lsp.start({ name = "zls", cmd = { "zls" } })
        \\
    );

    const Ctx = struct {
        fn start(_: *anyopaque, _: LspStartSpec) anyerror!void {
            return error.PermissionDenied;
        }
    };
    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = undefined,
        .start_lsp = Ctx.start,
    });
    runtime.loadInit(null, workspace);
    try std.testing.expect(runtime.notices.items.len >= 1);
    try std.testing.expect(std.mem.find(u8, runtime.notices.items[0].body, "not permitted") != null);
}

test "fx.paste.hook intercepts clipboard paste and attaches an image path" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.paste.hook(function(event)
        \\  if event.source == "clipboard" then
        \\    local path = fx.clipboard.image_path()
        \\    if path then
        \\      fx.image.attach(path)
        \\      return true
        \\    end
        \\    return false
        \\  end
        \\  if event.text and event.text:match("%.png$") then
        \\    fx.image.attach(event.text)
        \\    return true
        \\  end
        \\  return false
        \\end)
        \\
    );

    const Ctx = struct {
        clipboard_path: []const u8,
        attached: std.ArrayList(u8) = .empty,
        alloc: Allocator,
        fn clipboardPath(raw: *anyopaque, host_alloc: Allocator) anyerror!?[]u8 {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            return try host_alloc.dupe(u8, ctx.clipboard_path);
        }
        fn attach(raw: *anyopaque, path: []const u8) anyerror!void {
            const ctx: *@This() = @ptrCast(@alignCast(raw));
            ctx.attached.clearRetainingCapacity();
            try ctx.attached.appendSlice(ctx.alloc, path);
        }
    };
    var ctx = Ctx{ .clipboard_path = "/tmp/fx-image-snapshots-test/clipboard.png", .alloc = alloc };
    defer ctx.attached.deinit(alloc);

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.bindHost(.{
        .ctx = &ctx,
        .clipboard_image_path = Ctx.clipboardPath,
        .attach_image = Ctx.attach,
    });
    runtime.loadInit(null, workspace);
    try std.testing.expectEqual(@as(usize, 0), runtime.notices.items.len);
    try std.testing.expectEqual(@as(usize, 1), runtime.paste_hooks.items.len);

    try std.testing.expect(runtime.dispatchPaste("clipboard", null));
    try std.testing.expectEqualStrings(ctx.clipboard_path, ctx.attached.items);

    ctx.attached.clearRetainingCapacity();
    try std.testing.expect(!runtime.dispatchPaste("insert", "hello from a text paste"));
    try std.testing.expectEqual(@as(usize, 0), ctx.attached.items.len);

    try std.testing.expect(runtime.dispatchPaste("insert", "/tmp/shot.png"));
    try std.testing.expectEqualStrings("/tmp/shot.png", ctx.attached.items);
}

test "fx.paste.hook pass-through leaves the paste unconsumed" {
    if (comptime !enabled) return error.SkipZigTest;
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const workspace = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(workspace);
    try tmp.dir.createDirPath(io_mod.getIo(), ".fx");
    var file = try tmp.dir.createFile(io_mod.getIo(), ".fx/init.lua", .{});
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(),
        \\fx.paste.hook(function(event)
        \\  return false
        \\end)
        \\
    );

    var runtime = Runtime.init(alloc);
    defer runtime.deinit();
    runtime.loadInit(null, workspace);
    try std.testing.expectEqual(@as(usize, 1), runtime.paste_hooks.items.len);
    try std.testing.expect(!runtime.dispatchPaste("clipboard", null));
    try std.testing.expect(!runtime.dispatchPaste("insert", "plain text"));
}
