const std = @import("std");
const Config = @import("config.zig").Config;
const App = @import("repl/app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try Config.load(allocator);

    var app = App.init(allocator, cfg);
    try app.run();
}
