const std = @import("std");

pub const ConsoleInput = struct {
    bytes: [7]u8 = undefined,
    length: usize = 0,
    high: ?u16 = null,

    fn scalar(self: *ConsoleInput, value: u21) void {
        self.length += std.unicode.utf8Encode(value, self.bytes[self.length..]) catch unreachable;
    }
    pub fn feed(self: *ConsoleInput, unit: u16) void {
        std.debug.assert(self.length == 0);
        if (self.high) |high| {
            self.high = null;
            if (unit >= 0xdc00 and unit <= 0xdfff) {
                self.scalar(0x10000 + (@as(u21, high - 0xd800) << 10) + (unit - 0xdc00));
                return;
            }
            self.scalar(0xfffd);
        }
        if (unit >= 0xd800 and unit <= 0xdbff) {
            self.high = unit;
        } else {
            self.scalar(if (unit >= 0xdc00 and unit <= 0xdfff) 0xfffd else unit);
        }
    }
    pub fn take(self: *ConsoleInput, out: []u8) usize {
        const count = @min(out.len, self.length);
        @memcpy(out[0..count], self.bytes[0..count]);
        self.length -= count;
        @memmove(self.bytes[0..self.length], self.bytes[count..][0..self.length]);
        return count;
    }
};

test "console Unicode input preserves byte-sized reads and split surrogate pairs" {
    var input: ConsoleInput = .{};
    const units = [_]u16{ 'c', 'a', 'f', 0xe9, ' ', 0x65e5, 0x672c, 0x8a9e, 0xd83d, 0xde42 };
    var actual: [64]u8 = undefined;
    var length: usize = 0;
    for (units) |unit| {
        input.feed(unit);
        while (input.length != 0) length += input.take(actual[length..][0..1]);
    }
    try std.testing.expectEqualStrings("café 日本語\u{1f642}", actual[0..length]);
    input.feed(0xd800);
    input.feed('x');
    length = input.take(&actual);
    try std.testing.expectEqualStrings("\u{fffd}x", actual[0..length]);
}
