const std         = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("provider.zig");

const log = std.log.scoped(.anthropic);

fn serializeMessages(messages: []const session_mod.Message, allocator: std.mem.Allocator, writer: anytype) !void {
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
            .text => {
                const escaped = try jsonEscape(allocator, msg.content);
                defer allocator.free(escaped);
                try writer.writeAll(escaped);
            },
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
    current_tool_id:         std.ArrayListUnmanaged(u8) = .empty,
    current_tool_name:       std.ArrayListUnmanaged(u8) = .empty,
    current_input_json:      std.ArrayListUnmanaged(u8) = .empty,
    tool_calls:              std.ArrayListUnmanaged(prov.ToolUseBlock) = .empty,
    accumulated_text:        std.ArrayListUnmanaged(u8) = .empty,
    stop_reason:             prov.StopReason = .unknown,

    pub fn init(allocator: std.mem.Allocator) SseState {
        return .{
            .allocator          = allocator,
            .current_tool_id    = .empty,
            .current_tool_name  = .empty,
            .current_input_json = .empty,
            .tool_calls         = .empty,
            .accumulated_text   = .empty,
        };
    }

    pub fn deinit(self: *SseState) void {
        self.current_tool_id.deinit(self.allocator);
        self.current_tool_name.deinit(self.allocator);
        self.current_input_json.deinit(self.allocator);
        for (self.tool_calls.items) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.name);
            self.allocator.free(block.input_json);
        }
        self.tool_calls.deinit(self.allocator);
        self.accumulated_text.deinit(self.allocator);
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

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    // Simple JSON string escape: only handles quotes and backslashes for now
    var count: usize = 0;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') count += 1;
    }
    if (count == 0) return try std.fmt.allocPrint(allocator, "\"{s}\"", .{s});

    var result = try allocator.alloc(u8, s.len + count + 2); // +2 for quotes
    result[0] = '"';
    var i: usize = 1;
    for (s) |c| {
        switch (c) {
            '"' => { result[i] = '\\'; result[i+1] = '"'; i += 2; },
            '\\' => { result[i] = '\\'; result[i+1] = '\\'; i += 2; },
            '\n' => { result[i] = '\\'; result[i+1] = 'n'; i += 2; },
            '\r' => { result[i] = '\\'; result[i+1] = 'r'; i += 2; },
            '\t' => { result[i] = '\\'; result[i+1] = 't'; i += 2; },
            else => { result[i] = c; i += 1; },
        }
    }
    result[i] = '"';
    return result[0..i+1];
}

fn buildRequestBody(
    self: *Anthropic,
    allocator: std.mem.Allocator,
    messages: []const session_mod.Message,
    cwd: []const u8,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    const system_prompt = try std.fmt.allocPrint(
        allocator,
        "You are a coding agent at {s}. Use bash to solve tasks. Act, don't explain.",
        .{cwd},
    );
    defer allocator.free(system_prompt);

    const model_escaped = try jsonEscape(allocator, self.model);
    defer allocator.free(model_escaped);
    const system_escaped = try jsonEscape(allocator, system_prompt);
    defer allocator.free(system_escaped);

    try w.writeByte('{');
    try w.writeAll("\"model\":");
    try w.writeAll(model_escaped);
    try w.writeAll(",\"system\":");
    try w.writeAll(system_escaped);
    try w.writeAll(",\"messages\":");
    try serializeMessages(messages, allocator, w);
    try w.writeAll(",\"tools\":[{\"name\":\"bash\",\"description\":\"Run a shell command.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]");
    try w.writeAll(",\"max_tokens\":8000,\"stream\":true}");

    return buf.toOwnedSlice(allocator);
}

fn buildAssistantContentJson(
    allocator: std.mem.Allocator,
    state: *SseState,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('[');
    var first = true;

    if (state.accumulated_text.items.len > 0) {
        first = false;
        try w.writeAll("{\"type\":\"text\",\"text\":");
        const text_escaped = try jsonEscape(allocator, state.accumulated_text.items);
        defer allocator.free(text_escaped);
        try w.writeAll(text_escaped);
        try w.writeByte('}');
    }
    for (state.tool_calls.items) |block| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"type\":\"tool_use\",\"id\":");
        const id_escaped = try jsonEscape(allocator, block.id);
        defer allocator.free(id_escaped);
        try w.writeAll(id_escaped);
        try w.writeAll(",\"name\":");
        const name_escaped = try jsonEscape(allocator, block.name);
        defer allocator.free(name_escaped);
        try w.writeAll(name_escaped);
        try w.writeAll(",\"input\":");
        try w.writeAll(block.input_json);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
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
        const cwd_buf = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd_buf);

        const body = try buildRequestBody(self, allocator, messages, cwd_buf);
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
        defer allocator.free(url);

        // TODO: Zig 0.15.2 HTTP Client API changed significantly.
        // The old client.open() API is no longer available.
        // Need to rewrite using client.request() and handle streaming differently.
        // For now, return a stub response to allow compilation.
        _ = on_chunk;
        log.debug("anthropic send (Zig 0.15.2 API not yet implemented)", .{});

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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeMessages(msgs, std.testing.allocator, buf.writer(std.testing.allocator));
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    try serializeMessages(msgs, std.testing.allocator, buf.writer(std.testing.allocator));
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"text","text":"hi"}]}]
    , buf.items);
}

test "SSE: text_delta calls callback" {
    const Collector = struct {
        buf: std.ArrayListUnmanaged(u8) = .empty,
        fn cb(chunk: []const u8, ctx: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(ctx));
            self.buf.appendSlice(std.testing.allocator, chunk) catch {};
        }
    };
    var collector = Collector{ .buf = .empty };
    defer collector.buf.deinit(std.testing.allocator);

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
