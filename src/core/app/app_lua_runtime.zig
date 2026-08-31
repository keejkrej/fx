const std = @import("std");
const config_runtime = @import("../config/config_runtime.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("../config/model_provider.zig");
const provider_runtime = @import("provider_runtime.zig");
const scripting = @import("../scripting/runtime.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub fn Runtime(comptime App: type) type {
    return struct {
        pub fn configure(app: *App) !void {
            if (comptime !scripting.enabled) return;
            if (app.workspace_root.len == 0) return;
            app.scripting.bindHost(host(app));
            if (comptime @hasDecl(App, "builtinSlashSpecs")) {
                app.scripting.setBuiltinSlashSpecs(App.builtinSlashSpecs());
            }
            app.scripting.loadInit(io_mod.getenv("HOME"), app.workspace_root);
            try flushNotices(app);
        }

        pub fn registerHooks(app: *App) !void {
            if (comptime !scripting.enabled) return;
            try app.scripting.registerLifecycleHooks(&app.lifecycle_runtime);
        }

        pub fn handleLua(app: *App, rest: []const u8) !void {
            const trimmed = std.mem.trim(u8, rest, " \t");
            if (std.mem.eql(u8, trimmed, "reload")) {
                app.scripting.bindHost(host(app));
                app.scripting.reload();
                const failed = app.scripting.notices.items.len > 0;
                try flushNotices(app);
                if (!failed) {
                    try app.writeDomainNotice(.{
                        .topic = "lua",
                        .tone = .neutral,
                        .body = "Reloaded Lua init files.",
                    }, true);
                }
                return;
            }
            if (trimmed.len != 0) {
                try app.writeDomainNotice(.{
                    .topic = "lua",
                    .tone = .@"error",
                    .body = "Unknown /lua argument. Try /lua or /lua reload.",
                }, true);
                return;
            }
            const body = try app.scripting.statusText(app.alloc);
            defer app.alloc.free(body);
            try app.writeDomainNotice(.{
                .topic = "lua",
                .tone = .neutral,
                .body = body,
            }, true);
        }

        pub fn handleLuaCommand(app: *App, command: []const u8, payload: []const u8) !void {
            app.scripting.bindHost(host(app));
            app.scripting.invokeCommand(command, payload);
            try flushNotices(app);
        }

        pub fn dispatchKeymap(app: *App, byte: u8) bool {
            if (comptime !scripting.enabled) return false;
            const handled = app.scripting.dispatchKeymap(byte);
            flushNotices(app) catch {};
            return handled;
        }

        pub fn cycleView(app: *App) !bool {
            if (comptime !scripting.enabled) return false;
            if (!app.scripting.hasViews()) return false;
            app.scripting.bindHost(host(app));
            const result = app.scripting.cycleView();
            try flushNotices(app);
            return result != .none;
        }

        pub fn dispatchPaste(app: *App, source: []const u8, text: ?[]const u8) bool {
            if (comptime !scripting.enabled) return false;
            app.scripting.bindHost(host(app));
            const handled = app.scripting.dispatchPaste(source, text);
            flushNotices(app) catch {};
            if (handled) {
                if (comptime @hasField(App, "shell")) {
                    if (comptime @hasField(App, "terminal")) {
                        if (!app.terminal.codeViewerScreenActive()) {
                            app.shell.render_requests.request(.footer);
                        }
                    } else {
                        app.shell.render_requests.request(.footer);
                    }
                }
            }
            return handled;
        }

        fn flushNotices(app: *App) !void {
            const notices = app.scripting.takeNotices();
            defer app.scripting.freeNotices(notices);
            for (notices) |notice| {
                try app.writeDomainNotice(.{
                    .topic = "lua",
                    .tone = notice.tone,
                    .body = notice.body,
                }, true);
            }
        }

        fn host(app: *App) scripting.Host {
            return .{
                .ctx = app,
                .notify = notify,
                .model = model,
                .provider = provider,
                .get_opt = getOpt,
                .set_opt = setOpt,
                .open_view = openView,
                .open_diff = openDiff,
                .open_review = openReview,
                .append_input = appendInput,
                .clipboard_image_path = clipboardImagePath,
                .attach_image = attachImage,
                .allow_process = allowProcess,
                .start_lsp = startLsp,
                .stop_lsp = stopLsp,
                .close_view = closeView,
            };
        }

        fn notify(raw: *anyopaque, message: []const u8, tone: types.NoticeTone) void {
            const app: *App = @ptrCast(@alignCast(raw));
            app.writeDomainNotice(.{
                .topic = "lua",
                .tone = tone,
                .body = message,
            }, true) catch {};
        }

        fn model(raw: *anyopaque) []const u8 {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "selected_model")) {
                return app.selected_model.items;
            }
            return "";
        }

        fn provider(raw: *anyopaque) []const u8 {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime provider_runtime.supported(App)) {
                return @tagName(provider_runtime.provider(app));
            }
            return @tagName(model_provider.ProviderId.gateway);
        }

        fn getOpt(raw: *anyopaque, alloc: Allocator, key: []const u8) anyerror!?[]u8 {
            const app: *App = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, key, "model")) {
                return try alloc.dupe(u8, model(raw));
            }
            if (std.mem.eql(u8, key, "provider")) {
                const workspace = if (comptime @hasField(App, "workspace_root")) app.workspace_root else "";
                var settings = config_runtime.loadMergedSettings(alloc, workspace) catch {
                    return try alloc.dupe(u8, provider(raw));
                };
                defer settings.deinit(alloc);
                const name = if (settings.provider) |value| @tagName(value) else provider(raw);
                return try alloc.dupe(u8, name);
            }
            if (std.mem.eql(u8, key, "permission_mode")) {
                if (comptime @hasField(App, "permission_engine")) {
                    return try alloc.dupe(u8, @tagName(app.permission_engine.mode));
                }
            }
            if (std.mem.eql(u8, key, "effort")) {
                if (comptime @hasField(App, "effort")) {
                    return try alloc.dupe(u8, @tagName(app.effort));
                }
            }
            if (std.mem.eql(u8, key, "fast_mode")) {
                if (comptime @hasField(App, "fast_mode")) {
                    return try alloc.dupe(u8, if (app.fast_mode) "on" else "off");
                }
            }
            return null;
        }

        fn setOpt(raw: *anyopaque, key: []const u8, value: []const u8) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            var patch = config_runtime.UserSettingsPatch{};
            if (std.mem.eql(u8, key, "model")) {
                const current_provider = if (comptime provider_runtime.supported(App))
                    provider_runtime.provider(app)
                else
                    .gateway;
                patch.model_preference = .{ .provider = current_provider, .model = value };
            } else if (std.mem.eql(u8, key, "fast_mode")) {
                patch.fast_mode = parseOnOff(value) orelse return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "permission_mode")) {
                patch.permission_mode = std.meta.stringToEnum(types.PermissionMode, value) orelse
                    return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "effort")) {
                patch.effort = types.ReasoningEffort.parse(value) orelse return error.InvalidValue;
            } else if (std.mem.eql(u8, key, "provider")) {
                patch.provider = model_provider.parse(value) orelse return error.InvalidValue;
            } else {
                return error.UnknownSetting;
            }
            var attempt = config_runtime.attemptUserPreferences(app.alloc, patch);
            defer attempt.deinit(app.alloc);
            switch (attempt) {
                .failure => |failure| return failure.err,
                .outcome => {},
            }
        }

        fn openView(raw: *anyopaque, path: []const u8, line: ?u32) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "code_viewer")) {
                const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
                try app_code_viewer_runtime.Runtime(App).openPath(app, path, line);
                return;
            }
            try noticeViewerUnavailable(app, path);
        }

        fn openDiff(
            raw: *anyopaque,
            path: []const u8,
            old_text: []const u8,
            new_text: []const u8,
            line: ?u32,
        ) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "code_viewer")) {
                const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
                try app_code_viewer_runtime.Runtime(App).openDiff(app, path, old_text, new_text, line);
                return;
            }
            try noticeViewerUnavailable(app, path);
        }

        fn openReview(raw: *anyopaque, review: scripting.DiffReview) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "code_viewer")) {
                const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
                var files: std.ArrayList(app_code_viewer_runtime.DiffFile) = .empty;
                defer files.deinit(app.alloc);
                try files.ensureTotalCapacity(app.alloc, review.files.len);
                for (review.files) |file| {
                    files.appendAssumeCapacity(.{
                        .path = file.path,
                        .old_text = file.old_text,
                        .new_text = file.new_text,
                    });
                }
                try app_code_viewer_runtime.Runtime(App).openReview(
                    app,
                    files.items,
                    review.side_by_side,
                    review.line,
                );
                return;
            }
            const label = if (review.files.len > 0) review.files[0].path else "diff";
            try noticeViewerUnavailable(app, label);
        }

        fn appendInput(raw: *anyopaque, text: []const u8) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime !@hasField(App, "input_runtime")) return;
            const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
            const merged = try app_code_viewer_runtime.mergeComposerContext(
                app.alloc,
                app.input_runtime.edit_state.input.items,
                text,
            );
            defer app.alloc.free(merged);
            try app.input_runtime.textReplacementState().replace(app.alloc, merged);
            if (comptime @hasField(App, "shell")) {
                if (comptime @hasField(App, "terminal")) {
                    if (!app.terminal.codeViewerScreenActive()) {
                        app.shell.render_requests.request(.footer);
                    }
                } else {
                    app.shell.render_requests.request(.footer);
                }
            }
        }

        fn clipboardImagePath(raw: *anyopaque, alloc: Allocator) anyerror!?[]u8 {
            const image_attachments = @import("../images/image_attachments.zig");
            return image_attachments.takeClipboardImagePath(alloc) catch |err| switch (err) {
                error.ClipboardToolMissing => {
                    notify(raw, image_attachments.clipboardToolMissingNotice(), .@"error");
                    return null;
                },
                error.ImageTooLarge => {
                    notify(raw, image_attachments.image_too_large_notice, .@"error");
                    return null;
                },
                error.UnsupportedImageType => {
                    notify(raw, "clipboard did not contain a PNG, JPEG, GIF, or WebP image", .@"error");
                    return null;
                },
                else => return err,
            };
        }

        fn attachImage(raw: *anyopaque, path: []const u8) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime !@hasField(App, "pending_images")) return error.Unsupported;
            const image_commands = @import("../images/image_commands.zig");
            try image_commands.Commands(App).attachPath(app, path);
        }

        fn noticeViewerUnavailable(app: *App, path: []const u8) !void {
            const message = try std.fmt.allocPrint(
                app.alloc,
                "code viewer is unavailable ({s})",
                .{path},
            );
            defer app.alloc.free(message);
            try app.writeDomainNotice(.{
                .topic = "lua",
                .tone = .neutral,
                .body = message,
            }, true);
        }

        fn allowProcess(raw: *anyopaque) bool {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime !@hasField(App, "permission_engine")) return false;
            return app.permission_engine.mode == .yolo;
        }

        fn closeView(raw: *anyopaque) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "code_viewer")) {
                const app_code_viewer_runtime = @import("app_code_viewer_runtime.zig");
                try app_code_viewer_runtime.Runtime(App).close(app);
            }
        }

        fn startLsp(raw: *anyopaque, spec: scripting.LspStartSpec) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "lsp")) {
                const app_lsp_runtime = @import("app_lsp_runtime.zig");
                try app_lsp_runtime.Runtime(App).start(app, .{
                    .name = spec.name,
                    .argv = spec.argv,
                    .root = if (spec.root.len == 0) app.workspace_root else spec.root,
                });
                return;
            }
            return error.LspUnavailable;
        }

        fn stopLsp(raw: *anyopaque, name: []const u8) anyerror!void {
            const app: *App = @ptrCast(@alignCast(raw));
            if (comptime @hasField(App, "lsp")) {
                const app_lsp_runtime = @import("app_lsp_runtime.zig");
                try app_lsp_runtime.Runtime(App).stop(app, name);
                return;
            }
            return error.LspUnavailable;
        }
    };
}

fn parseOnOff(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "on") or std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "off") or std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}
