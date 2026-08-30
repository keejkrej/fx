const std = @import("std");
const display_width = @import("../core/shared/display_width.zig");
const diff_mod = @import("../core/output/diff.zig");
const layout = @import("code_viewer_layout.zig");
const row_text = @import("footer/row_text.zig");
const ui_render = @import("render.zig");
const vt_emulator = @import("../core/terminal/engine.zig");

const Allocator = std.mem.Allocator;

pub const Mode = enum { browse, search, goto_line, comment };

pub const Kind = enum { file, diff };

pub const DiffLayout = enum { unified, side_by_side };

pub const DiagnosticSeverity = enum { err, warning, information, hint };

pub const DiagnosticMark = struct {
    line: usize,
    severity: DiagnosticSeverity,
};

pub const FileModel = struct {
    lines: []const []const u8,
    highlighted: []const []const u8 = &.{},
    diagnostics: []const DiagnosticMark = &.{},
};

pub const DiffModel = struct {
    lines: []const diff_mod.DiffLine,
    pairs: []const layout.Pair = &.{},
    hunks: []const layout.Hunk = &.{},
    hunk_index: usize = 0,
    display: DiffLayout = .unified,
};

pub const FileListEntry = struct {
    path: []const u8,
    added: u32 = 0,
    removed: u32 = 0,
};

pub const PaintInput = struct {
    rows: u16,
    cols: u16,
    kind: Kind,
    path: []const u8,
    language: []const u8 = "",
    cursor: usize,
    scroll: usize,
    mode: Mode = .browse,
    query: []const u8 = "",
    matches: []const usize = &.{},
    match_index: usize = 0,
    goto_buf: []const u8 = "",
    comment_buf: []const u8 = "",
    file: FileModel = .{ .lines = &.{} },
    diff: DiffModel = .{ .lines = &.{} },
    file_list: []const FileListEntry = &.{},
    file_index: usize = 0,
    show_file_list: bool = false,
    clear_display: bool = true,
};

pub const Paint = struct {
    bytes: []u8,

    pub fn deinit(self: Paint, alloc: Allocator) void {
        alloc.free(self.bytes);
    }
};

pub fn paint(alloc: Allocator, input: PaintInput) !Paint {
    if (input.rows == 0 or input.cols == 0) return error.InvalidCodeViewerLayout;

    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();

    try out.writer.writeAll("\x1b[?25l\x1b[H");
    if (input.clear_display) try out.writer.writeAll("\x1b[2J");

    const placed = layout.regions(input.rows);
    const line_count = displayLineCount(input);
    const window = layout.visibleWindow(input.scroll, input.cursor, placed.body_rows, line_count);

    var screen_row: u16 = 1;
    while (screen_row <= input.rows) : (screen_row += 1) {
        if (screen_row == placed.header_row) {
            var row = try composeHeader(alloc, input, line_count);
            defer row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, row.items);
            continue;
        }
        if (placed.body_start > 0 and
            screen_row >= placed.body_start and
            screen_row < placed.body_start +| placed.body_rows)
        {
            const line_index = window.first + (screen_row - placed.body_start);
            var row = try composeSplitBodyRow(
                alloc,
                input,
                screen_row - placed.body_start,
                line_index,
                line_index == input.cursor,
            );
            defer row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, row.items);
            continue;
        }
        if (screen_row == placed.status_row) {
            var row = try composeStatus(alloc, input);
            defer row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, row.items);
            continue;
        }
        if (screen_row == placed.hint_row) {
            var row = try composeHint(alloc, input);
            defer row.deinit(alloc);
            try writeScreenRow(&out.writer, screen_row, row.items);
            continue;
        }
        try writeScreenRow(&out.writer, screen_row, "");
    }

    if (input.mode == .browse) {
        try out.writer.writeAll("\x1b[?25l");
    } else {
        const cursor_row = if (placed.status_row > 0) placed.status_row else input.rows;
        const prefix_width: u16 = 1;
        const typed = switch (input.mode) {
            .browse => "",
            .search => input.query,
            .goto_line => input.goto_buf,
            .comment => input.comment_buf,
        };
        const cursor_col: u16 = prefix_width +| @as(u16, @intCast(@min(typed.len, @as(usize, input.cols -| 1))));
        try writeCursor(&out.writer, cursor_row, cursor_col +| 1);
        try out.writer.writeAll("\x1b[?25h");
    }
    try out.writer.writeAll(ui_render.reset_style);
    return .{ .bytes = try out.toOwnedSlice() };
}

fn displayLineCount(input: PaintInput) usize {
    return switch (input.kind) {
        .file => input.file.lines.len,
        .diff => switch (effectiveDiffLayout(input)) {
            .unified => input.diff.lines.len,
            .side_by_side => input.diff.pairs.len,
        },
    };
}

fn effectiveDiffLayout(input: PaintInput) DiffLayout {
    if (input.kind != .diff) return .unified;
    if (input.diff.display != .side_by_side) return .unified;
    const geometry = layout.sideBySideGeometry(input.cols, maxOldLine(input.diff.lines), maxNewLine(input.diff.lines));
    return if (geometry.usable) .side_by_side else .unified;
}

fn composeHeader(alloc: Allocator, input: PaintInput, line_count: usize) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.bold_style);
    const title = switch (input.kind) {
        .file => "code",
        .diff => "diff",
    };
    var buf: [160]u8 = undefined;
    const line_no = if (line_count == 0) 0 else input.cursor + 1;
    const hunk = if (input.kind == .diff and input.diff.hunks.len > 0)
        std.fmt.bufPrint(&buf, "  hunk {d}/{d}", .{
            input.diff.hunk_index + 1,
            input.diff.hunks.len,
        }) catch ""
    else
        "";
    const layout_label = switch (effectiveDiffLayout(input)) {
        .side_by_side => "  side",
        .unified => "  unified",
    };
    var file_buf: [32]u8 = undefined;
    const file_pos = if (input.file_list.len > 1)
        std.fmt.bufPrint(&file_buf, "  {d}/{d}", .{
            input.file_index + 1,
            input.file_list.len,
        }) catch ""
    else
        "";
    const lang = if (input.language.len == 0) "" else input.language;
    const raw = try std.fmt.allocPrint(alloc, "{s}{s}  {s}  {d}/{d}{s}{s}{s}{s}", .{
        title,
        file_pos,
        input.path,
        line_no,
        line_count,
        if (lang.len == 0) "" else "  ",
        lang,
        hunk,
        if (input.kind == .diff) layout_label else "",
    });
    defer alloc.free(raw);
    try row_text.appendClipped(alloc, &row, raw, input.cols);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSplitBodyRow(
    alloc: Allocator,
    input: PaintInput,
    sidebar_row: usize,
    line_index: usize,
    current: bool,
) !std.ArrayList(u8) {
    const sidebar_width = fileListWidth(input);
    if (sidebar_width == 0) return composeBodyRow(alloc, input, line_index, current, input.cols);

    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try appendSidebarCell(alloc, &row, input, sidebar_row, sidebar_width -| 1);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, "│");
    try row.appendSlice(alloc, ui_render.reset_style);
    const diff_cols = input.cols -| sidebar_width;
    var body = try composeBodyRow(alloc, input, line_index, current, diff_cols);
    defer body.deinit(alloc);
    try row.appendSlice(alloc, body.items);
    return row;
}

fn fileListWidth(input: PaintInput) u16 {
    if (!input.show_file_list or input.file_list.len == 0) return 0;
    if (input.cols < 72) return 0;
    return @min(28, input.cols / 3);
}

fn appendSidebarCell(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    input: PaintInput,
    sidebar_row: usize,
    width: u16,
) !void {
    if (width == 0) return;
    if (sidebar_row == 0) {
        try row.appendSlice(alloc, ui_render.dim_style);
        try row_text.appendClipped(alloc, row, " files", width);
        try row.appendSlice(alloc, ui_render.reset_style);
        try padToWidth(alloc, row, width);
        return;
    }
    const file_index = sidebar_row - 1;
    if (file_index >= input.file_list.len) {
        try padToWidth(alloc, row, width);
        return;
    }
    const file = input.file_list[file_index];
    const current = file_index == input.file_index;
    const style = if (current) ui_render.bold_style else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    const marker = if (current) "▸ " else "  ";
    const label = try std.fmt.allocPrint(alloc, "{s}{s}  +{d} -{d}", .{
        marker,
        basename(file.path),
        file.added,
        file.removed,
    });
    defer alloc.free(label);
    try row_text.appendClipped(alloc, row, label, width);
    try row.appendSlice(alloc, ui_render.reset_style);
    try padToWidth(alloc, row, width);
}

fn padToWidth(alloc: Allocator, row: *std.ArrayList(u8), width: u16) !void {
    const used = clipVisible(row.items, width);
    if (used >= width) return;
    try row.appendNTimes(alloc, ' ', width - @as(u16, @intCast(used)));
}

fn clipVisible(bytes: []const u8, width: u16) usize {
    var visible: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b) {
            i = display_width.ansiSequenceEnd(bytes, i);
            continue;
        }
        const unit = display_width.displayUnitAt(bytes, i);
        if (unit.byte_len == 0) break;
        if (visible + unit.cell_width > width) break;
        visible += unit.cell_width;
        i += unit.byte_len;
    }
    return visible;
}

fn basename(path: []const u8) []const u8 {
    const name = std.fs.path.basename(path);
    return if (name.len > 0) name else path;
}

fn composeBodyRow(
    alloc: Allocator,
    input: PaintInput,
    line_index: usize,
    current: bool,
    cols: u16,
) !std.ArrayList(u8) {
    return switch (input.kind) {
        .file => composeFileRow(alloc, input, line_index, current, cols),
        .diff => switch (effectiveDiffLayout(input)) {
            .unified => composeUnifiedRow(alloc, input, line_index, current, cols),
            .side_by_side => composeSideBySideRow(alloc, input, line_index, current, cols),
        },
    };
}

fn composeFileRow(
    alloc: Allocator,
    input: PaintInput,
    line_index: usize,
    current: bool,
    cols: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (line_index >= input.file.lines.len) return row;
    const gutter = layout.gutterWidth(input.file.lines.len);
    const match = isMatch(input.matches, line_index);
    try appendGutter(alloc, &row, line_index + 1, gutter, current, match);
    const diagnostic = diagnosticForLine(input.file.diagnostics, line_index);
    var marker_width: u16 = 0;
    if (input.file.diagnostics.len > 0) {
        marker_width = 2;
        try appendDiagnosticMarker(alloc, &row, diagnostic);
    }
    const text_width = cols -| gutter -| marker_width;
    const styled = if (line_index < input.file.highlighted.len)
        input.file.highlighted[line_index]
    else
        input.file.lines[line_index];
    try row_text.appendClipped(alloc, &row, styled, text_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeUnifiedRow(
    alloc: Allocator,
    input: PaintInput,
    line_index: usize,
    current: bool,
    cols: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (line_index >= input.diff.lines.len) return row;
    const line = input.diff.lines[line_index];
    const number = line.new_num orelse line.old_num orelse 0;
    const gutter = layout.gutterWidth(@max(maxOldLine(input.diff.lines), maxNewLine(input.diff.lines)));
    try appendGutter(alloc, &row, number, gutter, current, false);
    const marker = switch (line.op) {
        .equal => " ",
        .add => "+",
        .remove => "-",
    };
    const marker_style = switch (line.op) {
        .equal => ui_render.dim_style,
        .add => ui_render.diff_added_marker_style,
        .remove => ui_render.diff_removed_marker_style,
    };
    try row.appendSlice(alloc, marker_style);
    try row.appendSlice(alloc, marker);
    try row.appendSlice(alloc, ui_render.reset_style);
    try row.append(alloc, ' ');
    const text_width = cols -| gutter -| 2;
    const text_style = switch (line.op) {
        .equal => "",
        .add => ui_render.diff_added_marker_style,
        .remove => ui_render.diff_removed_marker_style,
    };
    if (text_style.len > 0) try row.appendSlice(alloc, text_style);
    try row_text.appendClipped(alloc, &row, line.text, text_width);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeSideBySideRow(
    alloc: Allocator,
    input: PaintInput,
    line_index: usize,
    current: bool,
    cols: u16,
) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    if (line_index >= input.diff.pairs.len) return row;
    const pair = input.diff.pairs[line_index];
    const geometry = layout.sideBySideGeometry(cols, maxOldLine(input.diff.lines), maxNewLine(input.diff.lines));
    if (!geometry.usable) return composeUnifiedRow(alloc, input, line_index, current, cols);

    try appendPairHalf(alloc, &row, pair.left, geometry.old_gutter, geometry.col_width, current, true);
    try row.appendSlice(alloc, ui_render.dim_style);
    try row.appendSlice(alloc, "│");
    try row.appendSlice(alloc, ui_render.reset_style);
    try appendPairHalf(alloc, &row, pair.right, geometry.new_gutter, geometry.col_width, current, false);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendPairHalf(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    line: ?diff_mod.DiffLine,
    gutter: u16,
    col_width: u16,
    current: bool,
    old_side: bool,
) !void {
    const number: usize = if (line) |value|
        (if (old_side) value.old_num else value.new_num) orelse 0
    else
        0;
    const changed = if (line) |value| value.op != .equal else false;
    try appendGutter(alloc, row, number, gutter, current, changed);
    const text = if (line) |value| value.text else "";
    const style = if (line) |value| switch (value.op) {
        .add => ui_render.diff_added_marker_style,
        .remove => ui_render.diff_removed_marker_style,
        .equal => "",
    } else ui_render.dim_style;
    if (style.len > 0) try row.appendSlice(alloc, style);
    try row_text.appendClipped(alloc, row, text, col_width);
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn composeStatus(alloc: Allocator, input: PaintInput) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.dim_style);
    switch (input.mode) {
        .browse => {
            const counts = diagnosticCounts(input.file.diagnostics);
            if (input.query.len > 0) {
                const n = if (input.matches.len == 0) 0 else input.match_index + 1;
                const text = try std.fmt.allocPrint(
                    alloc,
                    "/{s}  {d}/{d}",
                    .{ input.query, n, input.matches.len },
                );
                defer alloc.free(text);
                try row_text.appendClipped(alloc, &row, text, input.cols);
            } else if (counts.errors > 0 or counts.warnings > 0) {
                const text = try std.fmt.allocPrint(
                    alloc,
                    "{d}E  {d}W",
                    .{ counts.errors, counts.warnings },
                );
                defer alloc.free(text);
                try row_text.appendClipped(alloc, &row, text, input.cols);
            }
        },
        .search => {
            try row.append(alloc, '/');
            try row_text.appendClipped(alloc, &row, input.query, input.cols -| 1);
        },
        .goto_line => {
            try row.append(alloc, ':');
            try row_text.appendClipped(alloc, &row, input.goto_buf, input.cols -| 1);
        },
        .comment => {
            try row.append(alloc, '>');
            try row_text.appendClipped(alloc, &row, input.comment_buf, input.cols -| 1);
        },
    }
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn composeHint(alloc: Allocator, input: PaintInput) !std.ArrayList(u8) {
    var row: std.ArrayList(u8) = .empty;
    errdefer row.deinit(alloc);
    try row.appendSlice(alloc, ui_render.hint_style);
    const text = switch (input.mode) {
        .browse => if (input.kind == .diff)
            if (input.file_list.len > 1)
                "q quit  {/} hunk  h/l file  tab files  t layout  c comment"
            else
                "q quit  {/} hunk  t layout  c comment  / search"
        else
            "q quit  / search  : line  n/N next  d def  j/k scroll",
        .search => "enter find  n/N next  esc clear",
        .goto_line => "enter jump  esc cancel",
        .comment => "enter send to agent  esc cancel",
    };
    try row_text.appendClipped(alloc, &row, text, input.cols);
    try row.appendSlice(alloc, ui_render.reset_style);
    return row;
}

fn appendGutter(
    alloc: Allocator,
    row: *std.ArrayList(u8),
    number: usize,
    width: u16,
    current: bool,
    emphasize: bool,
) !void {
    if (width == 0) return;
    const style = if (current)
        ui_render.bold_style
    else if (emphasize)
        ui_render.hint_style
    else
        ui_render.dim_style;
    try row.appendSlice(alloc, style);
    var buf: [16]u8 = undefined;
    const label = if (number == 0)
        ""
    else
        std.fmt.bufPrint(&buf, "{d}", .{number}) catch "";
    const digits_width = width -| 1;
    if (label.len < digits_width) {
        try row.appendNTimes(alloc, ' ', digits_width - label.len);
    }
    const shown = if (label.len > digits_width) label[label.len - digits_width ..] else label;
    try row.appendSlice(alloc, shown);
    try row.append(alloc, ' ');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn isMatch(matches: []const usize, line_index: usize) bool {
    for (matches) |match| {
        if (match == line_index) return true;
    }
    return false;
}

fn diagnosticForLine(marks: []const DiagnosticMark, line_index: usize) ?DiagnosticSeverity {
    var found: ?DiagnosticSeverity = null;
    for (marks) |mark| {
        if (mark.line != line_index) continue;
        found = if (found) |current| worseSeverity(current, mark.severity) else mark.severity;
    }
    return found;
}

fn diagnosticCounts(marks: []const DiagnosticMark) struct { errors: usize, warnings: usize } {
    var errors: usize = 0;
    var warnings: usize = 0;
    for (marks) |mark| {
        switch (mark.severity) {
            .err => errors += 1,
            .warning => warnings += 1,
            else => {},
        }
    }
    return .{ .errors = errors, .warnings = warnings };
}

fn worseSeverity(left: DiagnosticSeverity, right: DiagnosticSeverity) DiagnosticSeverity {
    return if (@intFromEnum(left) <= @intFromEnum(right)) left else right;
}

fn appendDiagnosticMarker(alloc: Allocator, row: *std.ArrayList(u8), severity: ?DiagnosticSeverity) !void {
    const style = if (severity) |value| switch (value) {
        .err => ui_render.diff_removed_marker_style,
        .warning => ui_render.warning_style,
        .information, .hint => ui_render.dim_style,
    } else ui_render.dim_style;
    try row.appendSlice(alloc, style);
    if (severity) |value| {
        const marker: u8 = switch (value) {
            .err => 'E',
            .warning => 'W',
            .information => 'I',
            .hint => 'H',
        };
        try row.append(alloc, marker);
    } else {
        try row.append(alloc, ' ');
    }
    try row.append(alloc, ' ');
    try row.appendSlice(alloc, ui_render.reset_style);
}

fn maxOldLine(lines: []const diff_mod.DiffLine) u32 {
    var max_num: u32 = 1;
    for (lines) |line| {
        if (line.old_num) |number| max_num = @max(max_num, number);
    }
    return max_num;
}

fn maxNewLine(lines: []const diff_mod.DiffLine) u32 {
    var max_num: u32 = 1;
    for (lines) |line| {
        if (line.new_num) |number| max_num = @max(max_num, number);
    }
    return max_num;
}

fn writeScreenRow(writer: *std.Io.Writer, row: u16, bytes: []const u8) !void {
    try writeCursor(writer, row, 1);
    try writer.writeAll(ui_render.reset_style);
    try writer.writeAll("\x1b[K");
    try writer.writeAll(bytes);
    try writer.writeAll(ui_render.reset_style);
}

fn writeCursor(writer: *std.Io.Writer, row: u16, col: u16) !void {
    try writer.print("\x1b[{d};{d}H", .{ row, col });
}

test "file viewer paints line numbers and the file path" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "const std = @import(\"std\");", "pub fn main() void {}", "" };
    var screen = try paint(alloc, .{
        .rows = 10,
        .cols = 48,
        .kind = .file,
        .path = "src/main.zig",
        .language = "zig",
        .cursor = 1,
        .scroll = 0,
        .file = .{ .lines = &lines },
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 48, 10);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(alloc);
    try grid.rowTextTrimmed(1, &header);
    try std.testing.expect(std.mem.find(u8, header.items, "src/main.zig") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "zig") != null);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try grid.rowTextTrimmed(3, &body);
    try std.testing.expect(std.mem.find(u8, body.items, "2") != null);
    try std.testing.expect(std.mem.find(u8, body.items, "pub fn main") != null);

    var hint: std.ArrayList(u8) = .empty;
    defer hint.deinit(alloc);
    try grid.rowTextTrimmed(10, &hint);
    try std.testing.expect(std.mem.find(u8, hint.items, "q quit") != null);
}

test "file viewer paints diagnostic markers and counts" {
    const alloc = std.testing.allocator;
    const lines = [_][]const u8{ "const x = 1;", "const y = 2;" };
    const diagnostics = [_]DiagnosticMark{
        .{ .line = 0, .severity = .err },
        .{ .line = 1, .severity = .warning },
    };
    var screen = try paint(alloc, .{
        .rows = 8,
        .cols = 40,
        .kind = .file,
        .path = "demo.zig",
        .cursor = 0,
        .scroll = 0,
        .file = .{ .lines = &lines, .diagnostics = &diagnostics },
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 40, 8);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try grid.rowTextTrimmed(2, &body);
    try std.testing.expect(std.mem.find(u8, body.items, "E") != null);
    try std.testing.expect(std.mem.find(u8, body.items, "const x") != null);

    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(alloc);
    try grid.rowTextTrimmed(7, &status);
    try std.testing.expect(std.mem.find(u8, status.items, "1E") != null);
    try std.testing.expect(std.mem.find(u8, status.items, "1W") != null);
}

test "diff viewer paints unified hunks and the path" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .equal, .old_num = 1, .new_num = 1, .text = "keep" },
        .{ .op = .remove, .old_num = 2, .text = "old" },
        .{ .op = .add, .new_num = 2, .text = "new" },
    };
    const hunks = [_]layout.Hunk{.{ .start = 1, .end = 3, .first_change = 1 }};
    var screen = try paint(alloc, .{
        .rows = 10,
        .cols = 40,
        .kind = .diff,
        .path = "src/app.zig",
        .cursor = 1,
        .scroll = 0,
        .diff = .{
            .lines = &lines,
            .hunks = &hunks,
            .display = .unified,
        },
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 40, 10);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(alloc);
    try grid.rowTextTrimmed(1, &header);
    try std.testing.expect(std.mem.find(u8, header.items, "src/app.zig") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "diff") != null);

    var removed: std.ArrayList(u8) = .empty;
    defer removed.deinit(alloc);
    try grid.rowTextTrimmed(3, &removed);
    try std.testing.expect(std.mem.find(u8, removed.items, "-") != null);
    try std.testing.expect(std.mem.find(u8, removed.items, "old") != null);

    var added: std.ArrayList(u8) = .empty;
    defer added.deinit(alloc);
    try grid.rowTextTrimmed(4, &added);
    try std.testing.expect(std.mem.find(u8, added.items, "+") != null);
    try std.testing.expect(std.mem.find(u8, added.items, "new") != null);
}

test "side-by-side paint keeps both sides of a replace" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .remove, .old_num = 1, .text = "old" },
        .{ .op = .add, .new_num = 1, .text = "new" },
    };
    const pairs = [_]layout.Pair{.{
        .left = lines[0],
        .right = lines[1],
    }};
    var screen = try paint(alloc, .{
        .rows = 8,
        .cols = 48,
        .kind = .diff,
        .path = "notes.txt",
        .cursor = 0,
        .scroll = 0,
        .diff = .{
            .lines = &lines,
            .pairs = &pairs,
            .display = .side_by_side,
        },
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 48, 8);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(alloc);
    try grid.rowTextTrimmed(2, &body);
    try std.testing.expect(std.mem.find(u8, body.items, "old") != null);
    try std.testing.expect(std.mem.find(u8, body.items, "new") != null);
}

test "diff review paints a file list beside the hunks" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .remove, .old_num = 1, .text = "old" },
        .{ .op = .add, .new_num = 1, .text = "new" },
    };
    const pairs = [_]layout.Pair{.{ .left = lines[0], .right = lines[1] }};
    const files = [_]FileListEntry{
        .{ .path = "lua/diffview/demo.lua", .added = 2, .removed = 1 },
        .{ .path = "README.md", .added = 3, .removed = 1 },
    };
    var screen = try paint(alloc, .{
        .rows = 10,
        .cols = 90,
        .kind = .diff,
        .path = "lua/diffview/demo.lua",
        .cursor = 0,
        .scroll = 0,
        .diff = .{
            .lines = &lines,
            .pairs = &pairs,
            .display = .side_by_side,
        },
        .file_list = &files,
        .file_index = 0,
        .show_file_list = true,
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 90, 10);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var header: std.ArrayList(u8) = .empty;
    defer header.deinit(alloc);
    try grid.rowTextTrimmed(1, &header);
    try std.testing.expect(std.mem.find(u8, header.items, "1/2") != null);
    try std.testing.expect(std.mem.find(u8, header.items, "side") != null);

    var sidebar: std.ArrayList(u8) = .empty;
    defer sidebar.deinit(alloc);
    try grid.rowTextTrimmed(2, &sidebar);
    try std.testing.expect(std.mem.find(u8, sidebar.items, "files") != null);

    var listed: std.ArrayList(u8) = .empty;
    defer listed.deinit(alloc);
    try grid.rowTextTrimmed(3, &listed);
    try std.testing.expect(std.mem.find(u8, listed.items, "demo.lua") != null);

    var second: std.ArrayList(u8) = .empty;
    defer second.deinit(alloc);
    try grid.rowTextTrimmed(4, &second);
    try std.testing.expect(std.mem.find(u8, second.items, "README.md") != null);

    var hint: std.ArrayList(u8) = .empty;
    defer hint.deinit(alloc);
    try grid.rowTextTrimmed(10, &hint);
    try std.testing.expect(std.mem.find(u8, hint.items, "h/l file") != null);
    try std.testing.expect(std.mem.find(u8, hint.items, "{/} hunk") != null);
    try std.testing.expect(std.mem.find(u8, hint.items, "c comment") != null);
}

test "diff comment prompt paints the note and send-to-agent hint" {
    const alloc = std.testing.allocator;
    const lines = [_]diff_mod.DiffLine{
        .{ .op = .remove, .old_num = 1, .text = "old" },
        .{ .op = .add, .new_num = 1, .text = "new" },
    };
    var screen = try paint(alloc, .{
        .rows = 8,
        .cols = 60,
        .kind = .diff,
        .path = "demo.lua",
        .cursor = 0,
        .scroll = 0,
        .mode = .comment,
        .comment_buf = "look at this hunk",
        .diff = .{ .lines = &lines },
    });
    defer screen.deinit(alloc);

    var grid = try vt_emulator.Grid.init(alloc, 60, 8);
    defer grid.deinit();
    try grid.feed(screen.bytes);

    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(alloc);
    try grid.rowTextTrimmed(7, &status);
    try std.testing.expect(std.mem.find(u8, status.items, ">look at this hunk") != null);

    var hint: std.ArrayList(u8) = .empty;
    defer hint.deinit(alloc);
    try grid.rowTextTrimmed(8, &hint);
    try std.testing.expect(std.mem.find(u8, hint.items, "enter send to agent") != null);
}
