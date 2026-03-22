const std = @import("std");
const ToolResult = @import("registry.zig").ToolResult;

const log = std.log.scoped(.tools);

const DANGEROUS = &[_][]const u8{
    "rm -rf /",
    "sudo",
    "shutdown",
    "reboot",
    "> /dev/",
};

pub fn run(allocator: std.mem.Allocator, input: std.json.Value) !ToolResult {
    const command: []const u8 = switch (input) {
        .object => |obj| blk: {
            const v = obj.get("command") orelse
                return ToolResult{ .output = try allocator.dupe(u8, "Error: missing 'command' field"), .is_error = true };
            break :blk switch (v) {
                .string => |s| s,
                else => return ToolResult{ .output = try allocator.dupe(u8, "Error: command must be a string"), .is_error = true },
            };
        },
        else => return ToolResult{ .output = try allocator.dupe(u8, "Error: input must be an object"), .is_error = true },
    };

    for (DANGEROUS) |pattern| {
        if (std.mem.indexOf(u8, command, pattern) != null) {
            log.debug("dangerous command blocked: {s}", .{command});
            return ToolResult{ .output = try allocator.dupe(u8, "Error: Dangerous command blocked"), .is_error = true };
        }
    }

    var child = std.process.Child.init(
        &[_][]const u8{ "sh", "-c", command },
        allocator,
    );
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    const stdout = try child.stdout.?.readToEndAlloc(allocator, 50_000);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.readToEndAlloc(allocator, 50_000);
    defer allocator.free(stderr);

    const term = try child.wait();
    // TODO: implement 120s timeout (kill child after timeout)
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else    => 1,
    };

    const total_raw = stdout.len + stderr.len;
    if (total_raw == 0) {
        return ToolResult{ .output = try allocator.dupe(u8, "(no output)"), .is_error = exit_code != 0 };
    }
    const cap = @min(total_raw, 50_000);
    const combined = try allocator.alloc(u8, cap);
    errdefer allocator.free(combined);
    var pos: usize = 0;
    for (&[_][]const u8{ stdout, stderr }) |part| {
        const n = @min(part.len, cap - pos);
        @memcpy(combined[pos..][0..n], part[0..n]);
        pos += n;
        if (pos >= cap) break;
    }
    return ToolResult{ .output = combined, .is_error = exit_code != 0 };
}

test "dangerous command is blocked" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("command", std.json.Value{ .string = "sudo rm -rf /" });

    const result = try run(std.testing.allocator, std.json.Value{ .object = map });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(result.is_error);
    try std.testing.expectEqualStrings("Error: Dangerous command blocked", result.output);
}

test "successful command returns stdout" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("command", std.json.Value{ .string = "echo hello" });

    const result = try run(std.testing.allocator, std.json.Value{ .object = map });
    defer std.testing.allocator.free(result.output);

    try std.testing.expect(!result.is_error);
    try std.testing.expectEqualStrings("hello", std.mem.trimRight(u8, result.output, "\n"));
}
