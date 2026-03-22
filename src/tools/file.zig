const std = @import("std");
const ToolResult = @import("registry.zig").ToolResult;

const log = std.log.scoped(.tools);

pub fn read(allocator: std.mem.Allocator, input: std.json.Value) !ToolResult {
    _ = allocator;
    _ = input;
    // TODO: extract "path", read file content
    log.debug("file read (stub)", .{});
    return ToolResult{ .output = "" };
}

pub fn write(allocator: std.mem.Allocator, input: std.json.Value) !ToolResult {
    _ = allocator;
    _ = input;
    // TODO: extract "path" and "content", write to disk
    log.debug("file write (stub)", .{});
    return ToolResult{ .output = "ok" };
}
