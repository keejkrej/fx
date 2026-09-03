const std = @import("std");

const Allocator = std.mem.Allocator;

pub const max_manifest_bytes: usize = 4096;
pub const max_version_bytes: usize = 32;
pub const max_revision_bytes: usize = 64;
const min_revision_bytes: usize = 7;

pub const Channel = enum {
    stable,
    dev,

    pub fn parse(raw: []const u8) ?Channel {
        if (std.ascii.eqlIgnoreCase(raw, "stable")) return .stable;
        if (std.ascii.eqlIgnoreCase(raw, "dev")) return .dev;
        return null;
    }

    pub fn label(self: Channel) []const u8 {
        return @tagName(self);
    }
};

pub const CurrentBuild = struct {
    channel: Channel,
    version: []const u8,
    revision: []const u8,
};

pub const Target = union(Channel) {
    stable: Stable,
    dev: Dev,

    pub const Stable = struct {
        version: []u8,
        artifact_ref: []u8,
    };

    pub const Dev = struct {
        version: []u8,
        revision: []u8,
        artifact_ref: []u8,
    };

    pub fn initStable(alloc: Allocator, raw_version: []const u8) !Target {
        const trimmed = std.mem.trim(u8, raw_version, " \t\r\n");
        const normalized_version = normalizeVersion(trimmed);
        if (!validVersion(normalized_version)) return error.InvalidVersion;

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const artifact_ref = try alloc.dupe(u8, trimmed);
        return .{ .stable = .{
            .version = owned_version,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn parseDevManifest(alloc: Allocator, bytes: []const u8) !Target {
        if (bytes.len > max_manifest_bytes) return error.ManifestTooLarge;

        var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
            return error.InvalidManifest;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidManifest;

        const version_value = parsed.value.object.get("version") orelse
            return error.InvalidManifest;
        const revision_value = parsed.value.object.get("commit") orelse
            return error.InvalidManifest;
        if (version_value != .string or revision_value != .string) {
            return error.InvalidManifest;
        }

        const normalized_version = normalizeVersion(version_value.string);
        const manifest_revision = revision_value.string;
        if (!validVersion(normalized_version) or !validRevision(manifest_revision)) {
            return error.InvalidManifest;
        }

        const owned_version = try alloc.dupe(u8, normalized_version);
        errdefer alloc.free(owned_version);
        const owned_revision = try alloc.dupe(u8, manifest_revision);
        errdefer alloc.free(owned_revision);
        const artifact_ref = try std.fmt.allocPrint(alloc, "dev/{s}", .{manifest_revision});
        return .{ .dev = .{
            .version = owned_version,
            .revision = owned_revision,
            .artifact_ref = artifact_ref,
        } };
    }

    pub fn deinit(self: *Target, alloc: Allocator) void {
        switch (self.*) {
            .stable => |stable| {
                alloc.free(stable.version);
                alloc.free(stable.artifact_ref);
            },
            .dev => |dev| {
                alloc.free(dev.version);
                alloc.free(dev.revision);
                alloc.free(dev.artifact_ref);
            },
        }
        self.* = undefined;
    }

    pub fn channel(self: Target) Channel {
        return std.meta.activeTag(self);
    }

    pub fn version(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.version,
            .dev => |dev| dev.version,
        };
    }

    pub fn revision(self: Target) ?[]const u8 {
        return switch (self) {
            .stable => null,
            .dev => |dev| dev.revision,
        };
    }

    pub fn artifactRef(self: Target) []const u8 {
        return switch (self) {
            .stable => |stable| stable.artifact_ref,
            .dev => |dev| dev.artifact_ref,
        };
    }

    pub fn shouldInstall(self: Target, current: CurrentBuild) bool {
        if (self.channel() != current.channel) return true;
        return switch (self) {
            .stable => |stable| compareVersions(stable.version, current.version) == .gt,
            .dev => |dev| !revisionsEqual(dev.revision, current.revision),
        };
    }

    pub fn writeDisplayLabel(self: Target, out: []u8) ![]const u8 {
        return switch (self) {
            .stable => |stable| std.fmt.bufPrint(out, "{s}", .{stable.version}),
            .dev => |dev| std.fmt.bufPrint(out, "dev {s}", .{shortRevision(dev.revision)}),
        };
    }
};

pub fn normalizeVersion(raw: []const u8) []const u8 {
    if (raw.len > 0 and raw[0] == 'v') return raw[1..];
    return raw;
}

const VersionParts = struct {
    major: u32 = 0,
    minor: u32 = 0,
    patch: u32 = 0,
    fork: u32 = 0,
};

pub fn compareVersions(a: []const u8, b: []const u8) std.math.Order {
    const av = parseVersionParts(a) orelse VersionParts{};
    const bv = parseVersionParts(b) orelse VersionParts{};
    if (av.major != bv.major) return std.math.order(av.major, bv.major);
    if (av.minor != bv.minor) return std.math.order(av.minor, bv.minor);
    if (av.patch != bv.patch) return std.math.order(av.patch, bv.patch);
    return std.math.order(av.fork, bv.fork);
}

fn validVersion(raw: []const u8) bool {
    return parseVersionParts(raw) != null;
}

pub fn isForkShipVersion(raw: []const u8) bool {
    const parts = parseVersionParts(normalizeVersion(std.mem.trim(u8, raw, " \t\r\n"))) orelse return false;
    return parts.fork != 0;
}

pub fn selectLatestForkRelease(candidates: []const []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    for (candidates) |candidate| {
        const trimmed = std.mem.trim(u8, candidate, " \t\r\n");
        if (!isForkShipVersion(trimmed)) continue;
        if (best) |current_best| {
            switch (compareVersions(trimmed, current_best)) {
                .gt => best = trimmed,
                .eq => {
                    if (trimmed.len > 0 and trimmed[0] == 'v' and current_best[0] != 'v') {
                        best = trimmed;
                    }
                },
                .lt => {},
            }
        } else {
            best = trimmed;
        }
    }
    return best;
}

pub fn scanGithubMatchingTagRefs(json: []const u8) ?[]const u8 {
    var tags: [256][]const u8 = undefined;
    var count: usize = 0;
    var offset: usize = 0;
    while (nextGithubTagRef(json, offset)) |found| {
        if (count == tags.len) break;
        tags[count] = found.tag;
        count += 1;
        offset = found.next;
    }
    return selectLatestForkRelease(tags[0..count]);
}

const GithubTagRef = struct {
    tag: []const u8,
    next: usize,
};

fn nextGithubTagRef(json: []const u8, start: usize) ?GithubTagRef {
    const patterns = [_][]const u8{ "\"ref\":\"refs/tags/", "\"ref\": \"refs/tags/" };
    var best_pos: ?usize = null;
    var pattern_len: usize = 0;
    for (patterns) |pattern| {
        const rel = std.mem.find(u8, json[start..], pattern) orelse continue;
        const pos = start + rel;
        if (best_pos == null or pos < best_pos.?) {
            best_pos = pos;
            pattern_len = pattern.len;
        }
    }
    const pos = best_pos orelse return null;
    const tag_start = pos + pattern_len;
    const rest = json[tag_start..];
    const end = std.mem.findScalar(u8, rest, '"') orelse return null;
    if (end == 0) return null;
    return .{ .tag = rest[0..end], .next = tag_start + end + 1 };
}

fn validRevision(raw: []const u8) bool {
    if (raw.len < min_revision_bytes or raw.len > max_revision_bytes) return false;
    for (raw) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn parseVersionParts(raw: []const u8) ?VersionParts {
    const normalized = normalizeVersion(raw);
    if (normalized.len == 0 or normalized.len > max_version_bytes) return null;
    if (std.mem.findScalar(u8, normalized, '+') != null) return null;
    if (std.mem.findScalar(u8, normalized, '/') != null) return null;

    var core = normalized;
    var fork: u32 = 0;
    if (std.mem.findScalar(u8, normalized, '-')) |dash| {
        const suffix = normalized[dash + 1 ..];
        fork = numericPart(suffix) orelse return null;
        if (fork == 0) return null;
        core = normalized[0..dash];
    }

    var parts = std.mem.splitScalar(u8, core, '.');
    const major_s = parts.next() orelse return null;
    const minor_s = parts.next() orelse return null;
    const patch_s = parts.next() orelse return null;
    if (parts.next() != null) return null;

    return .{
        .major = numericPart(major_s) orelse return null,
        .minor = numericPart(minor_s) orelse return null,
        .patch = numericPart(patch_s) orelse return null,
        .fork = fork,
    };
}

fn numericPart(part: []const u8) ?u32 {
    if (part.len == 0) return null;
    for (part) |byte| if (!std.ascii.isDigit(byte)) return null;
    if (part.len > 1 and part[0] == '0') return null;
    return std.fmt.parseUnsigned(u32, part, 10) catch null;
}

fn revisionsEqual(full: []const u8, current: []const u8) bool {
    if (std.mem.eql(u8, current, "unknown")) return false;
    const common_len = @min(full.len, current.len);
    if (common_len < min_revision_bytes) return false;
    return std.ascii.eqlIgnoreCase(full[0..common_len], current[0..common_len]);
}

fn shortRevision(revision: []const u8) []const u8 {
    return revision[0..@min(revision.len, 12)];
}

test "channel parsing accepts only stable and dev" {
    try std.testing.expectEqual(Channel.stable, Channel.parse("stable").?);
    try std.testing.expectEqual(Channel.dev, Channel.parse("DEV").?);
    try std.testing.expect(Channel.parse("nightly") == null);
}

test "dev manifest creates a bounded immutable target" {
    const alloc = std.testing.allocator;
    var target = try Target.parseDevManifest(
        alloc,
        "{\"version\":\"0.3.62\",\"commit\":\"0123456789abcdef0123456789abcdef01234567\"}",
    );
    defer target.deinit(alloc);

    try std.testing.expectEqual(Channel.dev, target.channel());
    try std.testing.expectEqualStrings("0.3.62", target.version());
    try std.testing.expectEqualStrings(
        "dev/0123456789abcdef0123456789abcdef01234567",
        target.artifactRef(),
    );
    var label_buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("dev 0123456789ab", try target.writeDisplayLabel(&label_buf));
}

test "dev manifest rejects malformed and oversized external data" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidManifest,
        Target.parseDevManifest(alloc, "{\"version\":\"0.3.62\",\"commit\":\"../escape\"}"),
    );
    try std.testing.expectError(
        error.InvalidManifest,
        Target.parseDevManifest(alloc, "{\"version\":\"0.3\",\"commit\":\"0123456\"}"),
    );
    try std.testing.expectError(
        error.ManifestTooLarge,
        Target.parseDevManifest(alloc, " " ** (max_manifest_bytes + 1)),
    );
}

test "stable release ordering rejects older targets and preserves channel switching" {
    const alloc = std.testing.allocator;
    var older = try Target.initStable(alloc, "v0.0.1");
    defer older.deinit(alloc);
    const newer_current = CurrentBuild{
        .channel = .stable,
        .version = "0.0.2",
        .revision = "0123456789ab",
    };

    try std.testing.expect(!older.shouldInstall(newer_current));
    try std.testing.expect(!older.shouldInstall(.{
        .channel = .stable,
        .version = "0.4.5",
        .revision = "0123456789ab",
    }));
    try std.testing.expect(older.shouldInstall(.{
        .channel = .dev,
        .version = "0.0.2",
        .revision = "abcdef012345",
    }));
}

test "target freshness uses version for stable and revision for dev" {
    const alloc = std.testing.allocator;
    var stable = try Target.initStable(alloc, "v0.3.63");
    defer stable.deinit(alloc);
    const stable_current = CurrentBuild{
        .channel = .stable,
        .version = "0.3.62",
        .revision = "0123456789ab",
    };
    try std.testing.expect(stable.shouldInstall(stable_current));

    var dev = try Target.parseDevManifest(
        alloc,
        "{\"version\":\"0.3.62\",\"commit\":\"abcdef0123456789abcdef0123456789abcdef01\"}",
    );
    defer dev.deinit(alloc);
    try std.testing.expect(dev.shouldInstall(stable_current));
    try std.testing.expect(!dev.shouldInstall(.{
        .channel = .dev,
        .version = "0.3.62",
        .revision = "abcdef012345",
    }));
}

test "stable versions accept an optional numeric fork revision" {
    const alloc = std.testing.allocator;
    var target = try Target.initStable(alloc, "v0.0.7-1");
    defer target.deinit(alloc);
    try std.testing.expectEqualStrings("0.0.7-1", target.version());
    try std.testing.expectEqualStrings("v0.0.7-1", target.artifactRef());

    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7-0"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7-01"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7-alpha"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7-1.2"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7+1"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7/1"));
    try std.testing.expectError(error.InvalidVersion, Target.initStable(alloc, "0.0.7-"));
}

test "fork revision is newer than its upstream base and older than the next upstream" {
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.0.7", "0.0.7-1"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.0.7-1", "0.0.7-2"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.0.7-2", "0.0.8"));
    try std.testing.expectEqual(std.math.Order.lt, compareVersions("0.0.6", "0.0.7-1"));
    try std.testing.expectEqual(std.math.Order.eq, compareVersions("v0.0.7-1", "0.0.7-1"));
    try std.testing.expectEqual(std.math.Order.gt, compareVersions("0.0.8-1", "0.0.8"));

    const alloc = std.testing.allocator;
    var fork_ship = try Target.initStable(alloc, "v0.0.7-1");
    defer fork_ship.deinit(alloc);
    try std.testing.expect(fork_ship.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.7",
        .revision = "0123456789ab",
    }));
    try std.testing.expect(!fork_ship.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.7-1",
        .revision = "0123456789ab",
    }));
    try std.testing.expect(!fork_ship.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.7-2",
        .revision = "0123456789ab",
    }));

    var upstream = try Target.initStable(alloc, "v0.0.8");
    defer upstream.deinit(alloc);
    try std.testing.expect(upstream.shouldInstall(.{
        .channel = .stable,
        .version = "0.0.7-99",
        .revision = "0123456789ab",
    }));
}

test "latest fork ship ignores plain upstream tags" {
    try std.testing.expect(!isForkShipVersion("0.0.7"));
    try std.testing.expect(!isForkShipVersion("v0.0.8"));
    try std.testing.expect(isForkShipVersion("v0.0.7-1"));

    const mixed = [_][]const u8{ "v0.0.8", "v0.0.7", "v0.0.7-1", "v0.0.7-2" };
    try std.testing.expectEqualStrings("v0.0.7-2", selectLatestForkRelease(&mixed).?);

    const next_upstream = [_][]const u8{ "v0.0.7-99", "v0.0.8-1", "v0.0.8" };
    try std.testing.expectEqualStrings("v0.0.8-1", selectLatestForkRelease(&next_upstream).?);

    const only_plain = [_][]const u8{ "v0.0.7", "v0.0.8" };
    try std.testing.expect(selectLatestForkRelease(&only_plain) == null);
}

test "GitHub matching-refs scanner prefers the newest fork ship" {
    const json =
        \\[{"ref": "refs/tags/v0.0.7", "url": "https://api.github.com/repos/keejkrej/fx/git/refs/tags/v0.0.7"},
        \\ {"ref": "refs/tags/v0.0.8", "url": "https://api.github.com/repos/keejkrej/fx/git/refs/tags/v0.0.8"},
        \\ {"ref": "refs/tags/v0.0.7-1", "url": "https://api.github.com/repos/keejkrej/fx/git/refs/tags/v0.0.7-1"},
        \\ {"ref":"refs/tags/v0.0.7-2"}]
    ;
    try std.testing.expectEqualStrings("v0.0.7-2", scanGithubMatchingTagRefs(json).?);
    try std.testing.expect(scanGithubMatchingTagRefs("[]") == null);
}
