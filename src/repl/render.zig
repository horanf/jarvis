const std = @import("std");

const log = std.log.scoped(.render);

/// Write a streaming chunk to the terminal
pub fn writeChunk(chunk: []const u8) void {
    // TODO: render via libvaxis surface
    _ = chunk;
    log.debug("render chunk (stub)", .{});
}

/// Display tool call invocation
pub fn writeToolCall(name: []const u8, output: []const u8, is_error: bool) void {
    _ = name;
    _ = output;
    _ = is_error;
    log.debug("render tool call (stub)", .{});
}
