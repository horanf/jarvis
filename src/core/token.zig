const std = @import("std");

/// Rough token count estimate: ~4 chars per token
pub fn estimate(text: []const u8) usize {
    return (text.len + 3) / 4;
}

test "estimate token count" {
    try std.testing.expectEqual(@as(usize, 3), estimate("hello world!"));
    try std.testing.expectEqual(@as(usize, 0), estimate(""));
}
