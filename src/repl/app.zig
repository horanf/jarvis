const std = @import("std");
const vaxis = @import("vaxis");

const log = std.log.scoped(.repl);

pub const App = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) App {
        return .{ .allocator = allocator };
    }

    pub fn run(self: *App) !void {
        _ = self;
        // TODO: initialize libvaxis, enter raw mode, start event loop
        log.debug("repl run (stub)", .{});
    }
};
