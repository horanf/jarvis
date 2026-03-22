const std = @import("std");
const ToolResult = @import("registry.zig").ToolResult;

const log = std.log.scoped(.tools);

pub fn run(allocator: std.mem.Allocator, input: std.json.Value) !ToolResult {
    _ = allocator;
    _ = input;
    // TODO: extract "command" from input, spawn child process, capture stdout/stderr
    log.debug("shell run (stub)", .{});
    return ToolResult{ .output = "" };
}
