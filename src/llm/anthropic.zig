const std         = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("provider.zig");

const log = std.log.scoped(.anthropic);

fn serializeMessages(messages: []const session_mod.Message, writer: anytype) !void {
    try writer.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte(',');
        const role_str: []const u8 = switch (msg.role) {
            .user      => "user",
            .assistant => "assistant",
            .system    => "system",
        };
        try writer.print("{{\"role\":\"{s}\",\"content\":", .{role_str});
        switch (msg.content_kind) {
            .text       => try std.json.stringify(msg.content, .{}, writer),
            .json_array => try writer.writeAll(msg.content),
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}

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

test "serializeMessages: text message" {
    const msgs = &[_]session_mod.Message{
        .{ .role = .user, .content = "hello world", .content_kind = .text },
    };
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try serializeMessages(msgs, buf.writer());
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":"hello world"}]
    , buf.items);
}

test "serializeMessages: json_array message" {
    const msgs = &[_]session_mod.Message{
        .{
            .role         = .assistant,
            .content      = "[{\"type\":\"text\",\"text\":\"hi\"}]",
            .content_kind = .json_array,
        },
    };
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try serializeMessages(msgs, buf.writer());
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"text","text":"hi"}]}]
    , buf.items);
}
