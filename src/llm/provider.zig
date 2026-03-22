const std = @import("std");
const session = @import("../core/session.zig");

pub const StreamCallback = *const fn (chunk: []const u8) void;

pub const ToolUseBlock = struct {
    id:         []const u8, // allocator.dupe'd
    name:       []const u8, // allocator.dupe'd
    input_json: []const u8, // allocator.dupe'd (raw JSON string)
};

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    unknown,
};

pub const LlmResponse = struct {
    stop_reason:            StopReason,
    tool_calls:             []ToolUseBlock,  // owned slice
    assistant_content_json: []const u8,       // owned, dupe'd JSON array string
    allocator:              std.mem.Allocator,

    pub fn deinit(self: *LlmResponse) void {
        for (self.tool_calls) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.name);
            self.allocator.free(block.input_json);
        }
        self.allocator.free(self.tool_calls);
        self.allocator.free(self.assistant_content_json);
    }
};

pub const Provider = union(enum) {
    anthropic: @import("anthropic.zig").Anthropic,
    openai:    @import("openai.zig").OpenAI,

    pub fn send(
        self: *Provider,
        allocator: std.mem.Allocator,
        messages: []const session.Message,
        on_chunk: StreamCallback,
    ) !LlmResponse {
        return switch (self.*) {
            inline else => |*p| try p.send(allocator, messages, on_chunk),
        };
    }
};

test "LlmResponse.deinit frees all owned memory" {
    const alloc = std.testing.allocator;
    var tool_calls = try alloc.alloc(ToolUseBlock, 1);
    tool_calls[0] = .{
        .id         = try alloc.dupe(u8, "tc1"),
        .name       = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":\"ls\"}"),
    };
    var r = LlmResponse{
        .stop_reason            = .end_turn,
        .tool_calls             = tool_calls,
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit();
}

test "LlmResponse.deinit empty tool_calls" {
    const alloc = std.testing.allocator;
    var r = LlmResponse{
        .stop_reason            = .tool_use,
        .tool_calls             = try alloc.alloc(ToolUseBlock, 0),
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit();
}
