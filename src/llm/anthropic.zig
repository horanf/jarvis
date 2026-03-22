const std         = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("provider.zig");
const sdk         = @import("anthropic");

const log = std.log.scoped(.anthropic);

pub const Anthropic = struct {
    client: sdk.Client,
    model:  []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        api_key:   []const u8,
        base_url:  []const u8,
        model:     []const u8,
    ) !Anthropic {
        const owned_model = try allocator.dupe(u8, model);
        errdefer allocator.free(owned_model);
        const client = try sdk.Client.init(allocator, .{
            .api_key  = api_key,
            .base_url = base_url,
        });
        return .{ .client = client, .model = owned_model };
    }

    pub fn deinit(self: *Anthropic) void {
        const alloc = self.client.allocator;
        self.client.deinit();
        alloc.free(self.model);
    }

    pub fn send(
        self:      *Anthropic,
        allocator: std.mem.Allocator,
        messages:  []const session_mod.Message,
        on_chunk:  prov.StreamCallback,
    ) !prov.LlmResponse {
        // Convert session messages to SDK MessageParam.
        // .text      → plain string content
        // .json_array → raw JSON array embedded as-is
        var sdk_msgs = try allocator.alloc(sdk.MessageParam, messages.len);
        defer allocator.free(sdk_msgs);
        for (messages, 0..) |msg, i| {
            const role: sdk.Role = switch (msg.role) {
                .user      => .user,
                .assistant => .assistant,
                .system    => .user, // system goes in top-level system field; shouldn't appear here
            };
            sdk_msgs[i] = switch (msg.content_kind) {
                .text       => .{ .role = role, .content          = msg.content },
                .json_array => .{ .role = role, .raw_content_json = msg.content },
            };
        }

        // Build tool definition using an arena so the json.Value tree lives
        // long enough for serialisation.
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var cmd_props = std.json.ObjectMap.init(aa);
        try cmd_props.put("type", std.json.Value{ .string = "string" });
        var properties = std.json.ObjectMap.init(aa);
        try properties.put("command", std.json.Value{ .object = cmd_props });

        const tools = [_]sdk.Tool{.{
            .name        = "bash",
            .description = "Run a shell command.",
            .input_schema = .{
                .type       = "object",
                .properties = std.json.Value{ .object = properties },
                .required   = &[_][]const u8{"command"},
            },
        }};

        // Build system prompt with current working directory.
        const cwd = try std.process.getCwdAlloc(allocator);
        defer allocator.free(cwd);
        const system = try std.fmt.allocPrint(
            allocator,
            "You are a coding agent at {s}. Use bash to solve tasks. Act, don't explain.",
            .{cwd},
        );
        defer allocator.free(system);

        var result = try self.client.messages().stream(.{
            .model      = self.model,
            .max_tokens = 8000,
            .messages   = sdk_msgs,
            .tools      = &tools,
            .system     = system,
        });
        defer result.deinit();

        switch (result) {
            .api_error => |*api_err| {
                log.err("API error status={d}", .{api_err.statusCode()});
                return error.ApiError;
            },
            .stream => |*stream| {
                return try processStream(allocator, stream, on_chunk);
            },
        }
    }
};

fn processStream(
    allocator: std.mem.Allocator,
    stream:    anytype,
    on_chunk:  prov.StreamCallback,
) !prov.LlmResponse {
    var accumulated_text: std.ArrayListUnmanaged(u8) = .empty;
    defer accumulated_text.deinit(allocator);

    var tool_calls: std.ArrayListUnmanaged(prov.ToolUseBlock) = .empty;
    defer {
        for (tool_calls.items) |tc| {
            allocator.free(tc.id);
            allocator.free(tc.name);
            allocator.free(tc.input_json);
        }
        tool_calls.deinit(allocator);
    }

    var current_tool_id:    std.ArrayListUnmanaged(u8) = .empty;
    defer current_tool_id.deinit(allocator);
    var current_tool_name:  std.ArrayListUnmanaged(u8) = .empty;
    defer current_tool_name.deinit(allocator);
    var current_input_json: std.ArrayListUnmanaged(u8) = .empty;
    defer current_input_json.deinit(allocator);

    var current_block_is_tool = false;
    var stop_reason: prov.StopReason = .unknown;

    while (try stream.nextEvent()) |event| {
        if (std.mem.eql(u8, event.event, "content_block_start")) {
            const parsed = std.json.parseFromSlice(
                sdk.StreamContentBlockStartEvent, allocator, event.data,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            defer parsed.deinit();

            const block_type = parsed.value.content_block.type;
            current_block_is_tool = std.mem.eql(u8, block_type, "tool_use");
            current_tool_id.clearRetainingCapacity();
            current_tool_name.clearRetainingCapacity();
            current_input_json.clearRetainingCapacity();

            if (current_block_is_tool) {
                if (parsed.value.content_block.id)   |id|   try current_tool_id.appendSlice(allocator, id);
                if (parsed.value.content_block.name) |name| try current_tool_name.appendSlice(allocator, name);
            }
        } else if (std.mem.eql(u8, event.event, "content_block_delta")) {
            const parsed = std.json.parseFromSlice(
                sdk.StreamContentBlockDeltaEvent, allocator, event.data,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            defer parsed.deinit();

            const dtype = parsed.value.delta.type;
            if (std.mem.eql(u8, dtype, "text_delta")) {
                if (parsed.value.delta.text) |text| {
                    try accumulated_text.appendSlice(allocator, text);
                    on_chunk(text);
                }
            } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
                if (parsed.value.delta.partial_json) |partial| {
                    try current_input_json.appendSlice(allocator, partial);
                }
            }
        } else if (std.mem.eql(u8, event.event, "content_block_stop")) {
            if (current_block_is_tool and current_tool_id.items.len > 0) {
                try tool_calls.append(allocator, .{
                    .id         = try allocator.dupe(u8, current_tool_id.items),
                    .name       = try allocator.dupe(u8, current_tool_name.items),
                    .input_json = try allocator.dupe(u8, current_input_json.items),
                });
                current_block_is_tool = false;
            }
        } else if (std.mem.eql(u8, event.event, "message_delta")) {
            const parsed = std.json.parseFromSlice(
                sdk.StreamMessageDeltaEvent, allocator, event.data,
                .{ .ignore_unknown_fields = true },
            ) catch continue;
            defer parsed.deinit();

            if (parsed.value.delta.stop_reason) |sr| {
                stop_reason = parseStopReason(sr);
            }
        } else if (std.mem.eql(u8, event.event, "message_stop")) {
            break;
        }
    }

    const assistant_json = try buildAssistantContentJson(
        allocator, accumulated_text.items, tool_calls.items,
    );
    const tool_calls_slice = try tool_calls.toOwnedSlice(allocator);
    tool_calls = .empty; // prevent double-free in defer above

    return prov.LlmResponse{
        .stop_reason            = stop_reason,
        .tool_calls             = tool_calls_slice,
        .assistant_content_json = assistant_json,
        .allocator              = allocator,
    };
}

fn parseStopReason(s: []const u8) prov.StopReason {
    if (std.mem.eql(u8, s, "end_turn"))      return .end_turn;
    if (std.mem.eql(u8, s, "tool_use"))      return .tool_use;
    if (std.mem.eql(u8, s, "max_tokens"))    return .max_tokens;
    if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
    return .unknown;
}

fn buildAssistantContentJson(
    allocator:  std.mem.Allocator,
    text:       []const u8,
    tool_calls: []const prov.ToolUseBlock,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeByte('[');
    var first = true;

    if (text.len > 0) {
        first = false;
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try writeJsonString(w, text);
        try w.writeByte('}');
    }
    for (tool_calls) |tc| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"type\":\"tool_use\",\"id\":");
        try writeJsonString(w, tc.id);
        try w.writeAll(",\"name\":");
        try writeJsonString(w, tc.name);
        try w.writeAll(",\"input\":");
        try w.writeAll(tc.input_json);
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}

fn writeJsonString(writer: anytype, s: []const u8) !void {
    try writer.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"'  => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
}

const testing = std.testing;

test "parseStopReason" {
    try testing.expectEqual(prov.StopReason.end_turn, parseStopReason("end_turn"));
    try testing.expectEqual(prov.StopReason.tool_use, parseStopReason("tool_use"));
    try testing.expectEqual(prov.StopReason.unknown,  parseStopReason("invalid"));
}

test "buildAssistantContentJson with text only" {
    const json = try buildAssistantContentJson(testing.allocator, "hello", &.{});
    defer testing.allocator.free(json);
    try testing.expectEqualStrings("[{\"type\":\"text\",\"text\":\"hello\"}]", json);
}

test "buildAssistantContentJson with tool call" {
    const tool_calls = &[_]prov.ToolUseBlock{
        .{ .id = "tc1", .name = "bash", .input_json = "{\"cmd\":\"ls\"}" },
    };
    const json = try buildAssistantContentJson(testing.allocator, "", tool_calls);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"type\":\"tool_use\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"id\":\"tc1\"") != null);
}
