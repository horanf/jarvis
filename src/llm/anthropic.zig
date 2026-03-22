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

fn buildRequestBody(
    self: *Anthropic,
    allocator: std.mem.Allocator,
    messages: []const session_mod.Message,
    cwd: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    const system_prompt = try std.fmt.allocPrint(
        allocator,
        "You are a coding agent at {s}. Use bash to solve tasks. Act, don't explain.",
        .{cwd},
    );
    defer allocator.free(system_prompt);

    try w.writeByte('{');
    try w.writeAll("\"model\":");
    try std.json.stringify(self.model, .{}, w);
    try w.writeAll(",\"system\":");
    try std.json.stringify(system_prompt, .{}, w);
    try w.writeAll(",\"messages\":");
    try serializeMessages(messages, w);
    try w.writeAll(",\"tools\":[{\"name\":\"bash\",\"description\":\"Run a shell command.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]");
    try w.writeAll(",\"max_tokens\":8000,\"stream\":true}");

    return buf.toOwnedSlice();
}

fn buildAssistantContentJson(
    allocator: std.mem.Allocator,
    state: *SseState,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeByte('[');
    var first = true;

    if (state.accumulated_text.items.len > 0) {
        first = false;
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.stringify(state.accumulated_text.items, .{}, w);
        try w.writeByte('}');
    }
    for (state.tool_calls.items) |block| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"type\":\"tool_use\",\"id\":");
        try std.json.stringify(block.id, .{}, w);
        try w.writeAll(",\"name\":");
        try std.json.stringify(block.name, .{}, w);
        try w.writeAll(",\"input\":");
        try w.writeAll(block.input_json);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice();
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

        var client = std.http.Client{ .allocator = allocator };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var server_header_buffer: [16 * 1024]u8 = undefined;
        var req = try client.open(.POST, uri, .{
            .server_header_buffer = &server_header_buffer,
            .extra_headers = &.{
                .{ .name = "content-type",      .value = "application/json" },
                .{ .name = "x-api-key",         .value = self.api_key },
                .{ .name = "anthropic-version", .value = "2023-06-01" },
            },
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        try req.writeAll(body);
        try req.finish();
        try req.wait();

        // Adapter: bridge public StreamCallback (1-arg) to internal SseCallback (2-arg)
        const ChunkAdapter = struct {
            public_cb: prov.StreamCallback,
            fn forward(chunk: []const u8, ctx: *anyopaque) void {
                const self2: *@This() = @ptrCast(@alignCast(ctx));
                self2.public_cb(chunk);
            }
        };
        var adapter = ChunkAdapter{ .public_cb = on_chunk };

        var state = SseState.init(allocator);
        errdefer state.deinit();

        var buf_reader = std.io.bufferedReader(req.reader());
        const reader = buf_reader.reader();
        var line_buf: [64 * 1024]u8 = undefined;

        while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |raw_line| {
            const line = std.mem.trimRight(u8, raw_line, "\r");
            if (std.mem.startsWith(u8, line, "data: ")) {
                const data = line[6..];
                if (std.mem.eql(u8, data, "[DONE]")) break;
                try processSseLine(data, &state, ChunkAdapter.forward, &adapter);
            }
        }

        // Read stop_reason BEFORE deinit'ing state
        const stop_reason = state.stop_reason;

        const assistant_json = try buildAssistantContentJson(allocator, &state);
        const tool_calls_slice = try state.tool_calls.toOwnedSlice();
        // Clear tool_calls before deinit so deinit doesn't double-free
        state.tool_calls = std.ArrayList(prov.ToolUseBlock).init(allocator);
        state.deinit();

        return prov.LlmResponse{
            .stop_reason            = stop_reason,
            .tool_calls             = tool_calls_slice,
            .assistant_content_json = assistant_json,
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
