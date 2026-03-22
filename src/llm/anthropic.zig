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

// Internal two-arg callback (with context pointer) used by processSseLine.
// The public StreamCallback (one-arg) is bridged in send() via a local adapter.
const SseCallback = *const fn (chunk: []const u8, ctx: *anyopaque) void;

pub const SseState = struct {
    allocator:               std.mem.Allocator,
    current_block_is_tool:   bool = false,
    current_tool_id:         std.ArrayList(u8),
    current_tool_name:       std.ArrayList(u8),
    current_input_json:      std.ArrayList(u8),
    tool_calls:              std.ArrayList(prov.ToolUseBlock),
    accumulated_text:        std.ArrayList(u8),
    stop_reason:             prov.StopReason = .unknown,

    pub fn init(allocator: std.mem.Allocator) SseState {
        return .{
            .allocator          = allocator,
            .current_tool_id    = std.ArrayList(u8).init(allocator),
            .current_tool_name  = std.ArrayList(u8).init(allocator),
            .current_input_json = std.ArrayList(u8).init(allocator),
            .tool_calls         = std.ArrayList(prov.ToolUseBlock).init(allocator),
            .accumulated_text   = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *SseState) void {
        self.current_tool_id.deinit();
        self.current_tool_name.deinit();
        self.current_input_json.deinit();
        for (self.tool_calls.items) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.name);
            self.allocator.free(block.input_json);
        }
        self.tool_calls.deinit();
        self.accumulated_text.deinit();
    }
};

pub fn processSseLine(
    data:     []const u8,
    state:    *SseState,
    on_chunk: SseCallback,
    ctx:      *anyopaque,
) !void {
    const parsed = std.json.parseFromSlice(
        std.json.Value, state.allocator, data, .{},
    ) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else    => return,
    };
    const event_type: []const u8 = switch (obj.get("type") orelse return) {
        .string => |s| s,
        else    => return,
    };

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const cb_obj = switch (obj.get("content_block") orelse return) {
            .object => |o| o, else => return,
        };
        const block_type: []const u8 = switch (cb_obj.get("type") orelse return) {
            .string => |s| s, else => return,
        };
        state.current_block_is_tool = std.mem.eql(u8, block_type, "tool_use");
        state.current_tool_id.clearRetainingCapacity();
        state.current_tool_name.clearRetainingCapacity();
        state.current_input_json.clearRetainingCapacity();
        if (state.current_block_is_tool) {
            if (cb_obj.get("id"))   |v| if (v == .string) try state.current_tool_id.appendSlice(v.string);
            if (cb_obj.get("name")) |v| if (v == .string) try state.current_tool_name.appendSlice(v.string);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const delta = switch (obj.get("delta") orelse return) {
            .object => |o| o, else => return,
        };
        const dtype: []const u8 = switch (delta.get("type") orelse return) {
            .string => |s| s, else => return,
        };
        if (std.mem.eql(u8, dtype, "text_delta")) {
            const text: []const u8 = switch (delta.get("text") orelse return) {
                .string => |s| s, else => return,
            };
            try state.accumulated_text.appendSlice(text);
            on_chunk(text, ctx);
        } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
            const partial: []const u8 = switch (delta.get("partial_json") orelse return) {
                .string => |s| s, else => return,
            };
            try state.current_input_json.appendSlice(partial);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        if (state.current_block_is_tool) {
            try state.tool_calls.append(.{
                .id         = try state.allocator.dupe(u8, state.current_tool_id.items),
                .name       = try state.allocator.dupe(u8, state.current_tool_name.items),
                .input_json = try state.allocator.dupe(u8, state.current_input_json.items),
            });
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const delta = switch (obj.get("delta") orelse return) {
            .object => |o| o, else => return,
        };
        const sr: []const u8 = switch (delta.get("stop_reason") orelse return) {
            .string => |s| s, else => return,
        };
        state.stop_reason = parseStopReason(sr);
        return;
    }
}

fn parseStopReason(s: []const u8) prov.StopReason {
    if (std.mem.eql(u8, s, "end_turn"))      return .end_turn;
    if (std.mem.eql(u8, s, "tool_use"))      return .tool_use;
    if (std.mem.eql(u8, s, "max_tokens"))    return .max_tokens;
    if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
    return .unknown;
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

test "SSE: text_delta calls callback" {
    const Collector = struct {
        buf: std.ArrayList(u8),
        fn cb(chunk: []const u8, ctx: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(ctx));
            self.buf.appendSlice(chunk) catch {};
        }
    };
    var collector = Collector{ .buf = std.ArrayList(u8).init(std.testing.allocator) };
    defer collector.buf.deinit();

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}
    , &state, Collector.cb, &collector);
    try processSseLine(
        \\{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello\"}}
    , &state, Collector.cb, &collector);

    try std.testing.expectEqualStrings("hello", collector.buf.items);
}

test "SSE: tool_use block is captured" {
    const noop = struct {
        fn cb(_: []const u8, _: *anyopaque) void {}
    };
    var dummy: u8 = 0;

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_123\",\"name\":\"bash\",\"input\":{}}}
    , &state, noop.cb, &dummy);
    try processSseLine(
        \\{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"ls\\\"}\"}}
    , &state, noop.cb, &dummy);
    try processSseLine(
        \\{\"type\":\"content_block_stop\",\"index\":1}
    , &state, noop.cb, &dummy);

    try std.testing.expectEqual(@as(usize, 1), state.tool_calls.items.len);
    try std.testing.expectEqualStrings("tool_123", state.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("bash",     state.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", state.tool_calls.items[0].input_json);
}

test "SSE: stop_reason from message_delta" {
    const noop = struct {
        fn cb(_: []const u8, _: *anyopaque) void {}
    };
    var dummy: u8 = 0;

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\",\"stop_sequence\":null},\"usage\":{\"output_tokens\":42}}
    , &state, noop.cb, &dummy);

    try std.testing.expectEqual(prov.StopReason.tool_use, state.stop_reason);
}
