//! Hit-testing for `[Image N]` chips. OSC 8 `file://` badges stay in the
//! paint path; this module resolves a click to a filesystem path so the
//! TUI can launch the system image viewer when the terminal ignores the link.

const std = @import("std");
const entity_spans = @import("../shared/entity_spans.zig");
const types = @import("../shared/types.zig");
const visual_layout = @import("../../ui/input/visual_layout.zig");
const vt_emulator = @import("../terminal/engine.zig");
const image_attachments = @import("image_attachments.zig");

test {
    _ = @import("../hosts/file_opener.zig");
}

const Allocator = std.mem.Allocator;

pub fn isFileUrl(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "file://");
}

pub fn fileUrlAtCell(grid: vt_emulator.Grid, row: u16, col: u16) ?[]const u8 {
    const cell = grid.cellAt(row, col) orelse return null;
    const url = grid.hyperlinkUrl(cell.style.hyperlink_id) orelse return null;
    if (!isFileUrl(url)) return null;
    return url;
}

pub fn gridHasFileHyperlink(grid: vt_emulator.Grid) bool {
    var row: u16 = 1;
    while (row <= grid.rows) : (row += 1) {
        var col: u16 = 1;
        while (col <= grid.cols) : (col += 1) {
            if (fileUrlAtCell(grid, row, col) != null) return true;
        }
    }
    return false;
}

pub fn mouseTrackingWanted(pending_image_count: usize, grid: ?*vt_emulator.Grid) bool {
    if (pending_image_count > 0) return true;
    const live = grid orelse return false;
    return gridHasFileHyperlink(live.*);
}

pub fn attachmentOpenPath(attachment: types.ImageAttachment) []const u8 {
    return attachment.snapshot_path orelse attachment.path;
}

pub fn imagePathAtRawOffset(
    images: []const types.ImageAttachment,
    tokens: []const entity_spans.ImageTokenSpan,
    raw_offset: usize,
) ?[]const u8 {
    for (tokens) |token| {
        if (raw_offset >= token.span.raw_start and raw_offset < token.span.raw_end) {
            for (images) |image| {
                if (image.id == token.id) return attachmentOpenPath(image);
            }
            return null;
        }
    }
    return null;
}

pub fn composerImageOpenPath(
    source: visual_layout.Source,
    row_index: usize,
    content_column: usize,
) ?[]const u8 {
    const point = visual_layout.cursorPointAtPosition(source, row_index, content_column) orelse
        return null;
    return imagePathAtRawOffset(source.images, source.image_tokens, point.raw_offset);
}

/// Percent-decode a `file://` URL into an owned filesystem path. Returns
/// `null` when the URL is not a local file path. Caller frees the slice.
pub fn decodeFileUrlPath(alloc: Allocator, url: []const u8) Allocator.Error!?[]u8 {
    const raw = stripFileUrlToRawPath(url) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);

    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '%' and i + 2 < raw.len) {
            if (parseHexByte(raw[i + 1], raw[i + 2])) |byte| {
                try out.append(alloc, byte);
                i += 3;
                continue;
            }
        }
        try out.append(alloc, raw[i]);
        i += 1;
    }

    // Windows file URIs encode `C:\...` as `/C:/...`.
    if (out.items.len >= 3 and
        out.items[0] == '/' and
        std.ascii.isAlphabetic(out.items[1]) and
        out.items[2] == ':')
    {
        _ = out.orderedRemove(0);
    }

    if (out.items.len == 0) {
        out.deinit(alloc);
        return null;
    }
    return try out.toOwnedSlice(alloc);
}

fn stripFileUrlToRawPath(url: []const u8) ?[]const u8 {
    if (!isFileUrl(url)) return null;
    var rest = url["file://".len..];
    if (std.mem.startsWith(u8, rest, "localhost")) {
        rest = rest["localhost".len..];
    } else if (rest.len >= 2 and std.ascii.isAlphabetic(rest[0]) and rest[1] == ':') {
        // `file://C:/Users/...`
    } else if (rest.len == 0 or rest[0] != '/') {
        return null;
    }
    if (std.mem.findScalar(u8, rest, '?')) |idx| rest = rest[0..idx];
    if (std.mem.findScalar(u8, rest, '#')) |idx| rest = rest[0..idx];
    return if (rest.len == 0) null else rest;
}

fn parseHexByte(hi: u8, lo: u8) ?u8 {
    return std.fmt.parseInt(u8, &.{ hi, lo }, 16) catch null;
}

test "decodeFileUrlPath strips file scheme and percent-decodes" {
    const alloc = std.testing.allocator;

    const plain = (try decodeFileUrlPath(alloc, "file:///tmp/pic.png")).?;
    defer alloc.free(plain);
    try std.testing.expectEqualStrings("/tmp/pic.png", plain);

    const spaced = (try decodeFileUrlPath(alloc, "file:///Users/me/CleanShot%202026.png")).?;
    defer alloc.free(spaced);
    try std.testing.expectEqualStrings("/Users/me/CleanShot 2026.png", spaced);

    const reserved = (try decodeFileUrlPath(alloc, "file:///tmp/a%23b%3Fc%25d.png")).?;
    defer alloc.free(reserved);
    try std.testing.expectEqualStrings("/tmp/a#b?c%d.png", reserved);

    const local = (try decodeFileUrlPath(alloc, "file://localhost/tmp/x.png")).?;
    defer alloc.free(local);
    try std.testing.expectEqualStrings("/tmp/x.png", local);

    const win = (try decodeFileUrlPath(alloc, "file:///C:/Users/me/pic.png")).?;
    defer alloc.free(win);
    try std.testing.expectEqualStrings("C:/Users/me/pic.png", win);

    try std.testing.expect(try decodeFileUrlPath(alloc, "https://example.com/x.png") == null);
    try std.testing.expect(try decodeFileUrlPath(alloc, "file://evil.example/tmp/x") == null);
}

test "fileUrlAtCell reads OSC 8 file links from the shadow grid" {
    const alloc = std.testing.allocator;
    var grid = try vt_emulator.Grid.init(alloc, 40, 4);
    defer grid.deinit();

    var badge: std.Io.Writer.Allocating = .init(alloc);
    defer badge.deinit();
    try image_attachments.writeImageBadge(&badge.writer, 2, "/tmp/pic.png");
    try grid.feed(badge.written());

    try std.testing.expectEqualStrings("file:///tmp/pic.png", fileUrlAtCell(grid, 1, 1).?);
    try std.testing.expect(gridHasFileHyperlink(grid));
    try std.testing.expect(fileUrlAtCell(grid, 2, 1) == null);
}

test "mouseTrackingWanted follows pending images and visible file chips" {
    try std.testing.expect(mouseTrackingWanted(1, null));
    try std.testing.expect(!mouseTrackingWanted(0, null));

    const alloc = std.testing.allocator;
    var grid = try vt_emulator.Grid.init(alloc, 20, 2);
    defer grid.deinit();
    try std.testing.expect(!mouseTrackingWanted(0, &grid));

    var badge: std.Io.Writer.Allocating = .init(alloc);
    defer badge.deinit();
    try image_attachments.writeImageBadge(&badge.writer, 1, "/tmp/a.png");
    try grid.feed(badge.written());
    try std.testing.expect(mouseTrackingWanted(0, &grid));
}

test "composerImageOpenPath prefers snapshot_path on the image token" {
    const input = "[Image #3]";
    const snapshot = "/tmp/fx-image-snapshots/clip.png";
    const source_path = "/tmp/original.png";
    const images = [_]types.ImageAttachment{.{
        .id = 3,
        .path = @constCast(source_path),
        .media_type = @constCast("image/png"),
        .snapshot_path = @constCast(snapshot),
    }};
    const tokens = [_]entity_spans.ImageTokenSpan{.{
        .span = .{ .raw_start = 0, .raw_end = input.len },
        .id = 3,
    }};

    const path = composerImageOpenPath(.{
        .input = input,
        .cursor = 0,
        .terminal_cols = 80,
        .images = &images,
        .image_tokens = &tokens,
    }, 0, 1);
    try std.testing.expectEqualStrings(snapshot, path.?);
}
