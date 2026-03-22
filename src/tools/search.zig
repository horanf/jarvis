const std = @import("std");
const ToolResult = @import("registry.zig").ToolResult;

const log = std.log.scoped(.tools);

pub fn run(allocator: std.mem.Allocator, tool_name: []const u8, input: std.json.Value) !ToolResult {
    _ = allocator;
    _ = input;
    log.debug("{s} (stub)", .{tool_name});
    return ToolResult{ .output = "" };
}
