const std = @import("std");

/// First-class model transport. Distinct from `CredentialSource`, which is only
/// how fx authenticates leftover Vercel surfaces that are not the model loop.
pub const ModelBackend = enum {
    openai_compatible,

    pub fn label(self: ModelBackend) []const u8 {
        return switch (self) {
            .openai_compatible => "OpenAI-compatible",
        };
    }

    pub fn persistedName(self: ModelBackend) []const u8 {
        return @tagName(self);
    }

    pub fn isImplemented(self: ModelBackend) bool {
        return switch (self) {
            .openai_compatible => true,
        };
    }

    pub fn usesGatewayBalance(self: ModelBackend) bool {
        _ = self;
        return false;
    }
};

pub const provider_env = "FX_PROVIDER";

pub fn parse(text: []const u8) ?ModelBackend {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.meta.stringToEnum(ModelBackend, trimmed);
}

pub fn parseStrict(text: []const u8) ?ModelBackend {
    return std.meta.stringToEnum(ModelBackend, text);
}

test "model backend round trips through its persisted name" {
    for (std.meta.tags(ModelBackend)) |backend| {
        try std.testing.expectEqual(backend, parse(@tagName(backend)).?);
        try std.testing.expectEqual(backend, parseStrict(@tagName(backend)).?);
        try std.testing.expectEqualStrings(@tagName(backend), backend.persistedName());
    }
    try std.testing.expect(parse("openai") == null);
    try std.testing.expect(parse("vercel_gateway") == null);
    try std.testing.expect(parse("chatgpt") == null);
    try std.testing.expect(parse(" grok ") == null);
    try std.testing.expect(parse(" openai_compatible ") == .openai_compatible);
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parseStrict(" openai_compatible ") == null);
}

test "model backend implementation and billing flags stay conservative" {
    try std.testing.expect(ModelBackend.openai_compatible.isImplemented());
    try std.testing.expect(!ModelBackend.openai_compatible.usesGatewayBalance());
    try std.testing.expectEqualStrings("OpenAI-compatible", ModelBackend.openai_compatible.label());
}
