const std         = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("provider.zig");

const log = std.log.scoped(.anthropic);

pub const Anthropic = struct {
    api_key:  []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    model:    []const u8,

    pub fn send(
        self: *Anthropic,
        allocator: std.mem.Allocator,
        messages: []const session_mod.Message,
        on_chunk: prov.StreamCallback,
    ) !prov.LlmResponse {
        _ = self; _ = messages; _ = on_chunk;
        log.debug("anthropic send (stub)", .{});
        return prov.LlmResponse{
            .stop_reason            = .end_turn,
            .tool_calls             = try allocator.alloc(prov.ToolUseBlock, 0),
            .assistant_content_json = try allocator.dupe(u8, "[]"),
            .allocator              = allocator,
        };
    }
};
