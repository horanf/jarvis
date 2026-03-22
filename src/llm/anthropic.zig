const std = @import("std");
const session = @import("../core/session.zig");
const StreamCallback = @import("provider.zig").StreamCallback;

const log = std.log.scoped(.anthropic);

pub const Anthropic = struct {
    api_key: []const u8,
    model: []const u8,

    pub fn send(
        self: *Anthropic,
        allocator: std.mem.Allocator,
        messages: []const session.Message,
        on_chunk: StreamCallback,
    ) !void {
        _ = self;
        _ = allocator;
        _ = messages;
        _ = on_chunk;
        // TODO: implement SSE streaming via std.http
        log.debug("anthropic send (stub)", .{});
    }
};
