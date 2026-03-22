const std = @import("std");
const session = @import("../core/session.zig");

pub const StreamCallback = *const fn (chunk: []const u8) void;

/// Unified provider interface via tagged union
pub const Provider = union(enum) {
    anthropic: @import("anthropic.zig").Anthropic,
    openai: @import("openai.zig").OpenAI,

    pub fn send(
        self: *Provider,
        allocator: std.mem.Allocator,
        messages: []const session.Message,
        on_chunk: StreamCallback,
    ) !void {
        switch (self.*) {
            inline else => |*p| try p.send(allocator, messages, on_chunk),
        }
    }
};
