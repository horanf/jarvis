const std        = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("../llm/provider.zig");
const registry    = @import("../tools/registry.zig");
const config_mod  = @import("../config.zig");
const anthropic   = @import("../llm/anthropic.zig");

const log = std.log.scoped(.repl);

fn jsonEscape(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var count: usize = 0;
    for (s) |c| {
        if (c == '"' or c == '\\' or c == '\n' or c == '\r' or c == '\t') count += 1;
    }
    if (count == 0) return try std.fmt.allocPrint(allocator, "\"{s}\"", .{s});

    var result = try allocator.alloc(u8, s.len + count + 2);
    result[0] = '"';
    var i: usize = 1;
    for (s) |c| {
        switch (c) {
            '"' => { result[i] = '\\'; result[i+1] = '"'; i += 2; },
            '\\' => { result[i] = '\\'; result[i+1] = '\\'; i += 2; },
            '\n' => { result[i] = '\\'; result[i+1] = 'n'; i += 2; },
            '\r' => { result[i] = '\\'; result[i+1] = 'r'; i += 2; },
            '\t' => { result[i] = '\\'; result[i+1] = 't'; i += 2; },
            else => { result[i] = c; i += 1; },
        }
    }
    result[i] = '"';
    return result[0..i+1];
}

fn printChunk(chunk: []const u8) void {
    _ = std.posix.write(std.posix.STDOUT_FILENO, chunk) catch {};
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    var pos: usize = 0;
    while (pos < buf.len) {
        const n = try std.posix.write(fd, buf[pos..]);
        if (n == 0) return error.WriteFailed;
        pos += n;
    }
}

fn buildToolResultsJson(
    allocator:  std.mem.Allocator,
    tool_calls: []const prov.ToolUseBlock,
    results:    []const registry.ToolResult,
) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeByte('[');
    for (tool_calls, 0..) |tc, i| {
        if (i > 0) try w.writeByte(',');
        const res = results[i];
        try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        const id_escaped = try jsonEscape(allocator, tc.id);
        defer allocator.free(id_escaped);
        try w.writeAll(id_escaped);
        try w.writeAll(",\"content\":");
        const content_escaped = try jsonEscape(allocator, res.output);
        defer allocator.free(content_escaped);
        try w.writeAll(content_escaped);
        if (res.is_error) try w.writeAll(",\"is_error\":true");
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice(allocator);
}

fn agentLoop(
    allocator: std.mem.Allocator,
    sess: *session_mod.Session,
    provider: *prov.Provider,
) !void {
    while (true) {
        var response = try provider.send(allocator, sess.messages.items, printChunk);
        defer response.deinit();

        try sess.append(.assistant, response.assistant_content_json, .json_array);

        if (response.stop_reason != .tool_use) break;

        var results = try allocator.alloc(registry.ToolResult, response.tool_calls.len);
        var results_filled: usize = 0;
        defer {
            for (results[0..results_filled]) |r| allocator.free(r.output);
            allocator.free(results);
        }

        for (response.tool_calls, 0..) |tc, idx| {
            const display = tc.input_json[0..@min(tc.input_json.len, 200)];
            const prompt = try std.fmt.allocPrint(allocator, "\x1b[33m$ {s}\x1b[0m\n", .{display});
            defer allocator.free(prompt);
            try writeAll(std.posix.STDOUT_FILENO, prompt);

            const parsed = try std.json.parseFromSlice(
                std.json.Value, allocator, tc.input_json, .{},
            );
            defer parsed.deinit();

            const result = try registry.dispatch(allocator, registry.ToolCall{
                .name  = tc.name,
                .input = parsed.value,
            });
            results[idx] = result;
            results_filled += 1;

            const preview = result.output[0..@min(result.output.len, 200)];
            const out_line = try std.fmt.allocPrint(allocator, "{s}\n", .{preview});
            defer allocator.free(out_line);
            try writeAll(std.posix.STDOUT_FILENO, out_line);
        }

        const results_json = try buildToolResultsJson(allocator, response.tool_calls, results);
        defer allocator.free(results_json);
        try sess.append(.user, results_json, .json_array);
    }
}

pub const App = struct {
    allocator: std.mem.Allocator,
    cfg:       config_mod.Config,

    pub fn init(allocator: std.mem.Allocator, cfg: config_mod.Config) App {
        return .{ .allocator = allocator, .cfg = cfg };
    }

    pub fn run(self: *App) !void {
        const anthro_cfg = self.cfg.anthropic orelse {
            try writeAll(std.posix.STDOUT_FILENO, "Error: no anthropic config\n");
            return;
        };

        // 初始化 anthropic 客户端
        var anthro_client = try anthropic.Anthropic.init(
            self.allocator,
            anthro_cfg.api_key,
            anthro_cfg.base_url,
            anthro_cfg.model,
        );
        defer anthro_client.deinit();

        var provider = prov.Provider{
            .anthropic = anthro_client,
        };

        var sess = session_mod.Session.init(self.allocator);
        defer sess.deinit();

        var line_buf: [4096]u8 = undefined;
        while (true) {
            try writeAll(std.posix.STDOUT_FILENO, "\x1b[36mjarvis >> \x1b[0m");

            // Read from stdin using posix.read
            const n = std.posix.read(std.posix.STDIN_FILENO, &line_buf) catch break;
            if (n == 0) break;

            // Find newline
            var line_end: usize = 0;
            while (line_end < n and line_buf[line_end] != '\n') : (line_end += 1) {}
            const line = line_buf[0..line_end];

            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "exit")) break;

            try sess.append(.user, trimmed, .text);

            try writeAll(std.posix.STDOUT_FILENO, "\n");
            agentLoop(self.allocator, &sess, &provider) catch |err| {
                const err_msg = try std.fmt.allocPrint(self.allocator, "Error: {}\n", .{err});
                defer self.allocator.free(err_msg);
                try writeAll(std.posix.STDOUT_FILENO, err_msg);
            };
            try writeAll(std.posix.STDOUT_FILENO, "\n");
        }
    }
};

test "buildToolResultsJson produces correct JSON" {
    const tool_calls = &[_]prov.ToolUseBlock{
        .{ .id = "tc1", .name = "bash", .input_json = "{\"command\":\"ls\"}" },
    };
    const results = &[_]registry.ToolResult{
        .{ .output = "file.txt\n", .is_error = false },
    };
    const json = try buildToolResultsJson(std.testing.allocator, tool_calls, results);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_use_id\":\"tc1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_error\"") == null); // not present for success
}

test "buildToolResultsJson sets is_error for failed tool" {
    const tool_calls = &[_]prov.ToolUseBlock{
        .{ .id = "tc2", .name = "bash", .input_json = "{}" },
    };
    const results = &[_]registry.ToolResult{
        .{ .output = "Error: bad", .is_error = true },
    };
    const json = try buildToolResultsJson(std.testing.allocator, tool_calls, results);
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_error\":true") != null);
}
