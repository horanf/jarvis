const std = @import("std");
const session = @import("../core/session.zig");
const StreamCallback = @import("provider.zig").StreamCallback;

const log = std.log.scoped(.openai);

pub const OpenAI = struct {
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,

    pub fn send(
        self: *OpenAI,
        allocator: std.mem.Allocator,
        messages: []const session.Message,
        on_chunk: StreamCallback,
    ) !void {
        _ = self;
        _ = allocator;
        _ = messages;
        _ = on_chunk;
        // TODO: implement OpenAI-compatible SSE streaming
        log.debug("openai send (stub)", .{});
    }
};
