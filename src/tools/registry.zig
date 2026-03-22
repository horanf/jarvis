const std = @import("std");

const log = std.log.scoped(.tools);

pub const ToolResult = struct {
    output: []const u8,
    is_error: bool = false,
};

pub const ToolCall = struct {
    name: []const u8,
    input: std.json.Value,
};

pub fn dispatch(
    allocator: std.mem.Allocator,
    call: ToolCall,
) !ToolResult {
    log.debug("dispatch tool: {s}", .{call.name});
    if (std.mem.eql(u8, call.name, "shell")) {
        return @import("shell.zig").run(allocator, call.input);
    } else if (std.mem.eql(u8, call.name, "read_file")) {
        return @import("file.zig").read(allocator, call.input);
    } else if (std.mem.eql(u8, call.name, "write_file")) {
        return @import("file.zig").write(allocator, call.input);
    } else if (std.mem.eql(u8, call.name, "glob") or std.mem.eql(u8, call.name, "grep")) {
        return @import("search.zig").run(allocator, call.name, call.input);
    }
    return ToolResult{ .output = "unknown tool", .is_error = true };
}
