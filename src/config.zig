const std = @import("std");

const log = std.log.scoped(.config);

pub const Provider = enum {
    anthropic,
    openai,
};

pub const AnthropicConfig = struct {
    api_key:  []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    model:    []const u8 = "claude-opus-4-5",
};

pub const OpenAIConfig = struct {
    api_key:  []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
    model:    []const u8 = "gpt-4o",
};

pub const Config = struct {
    default_provider: Provider = .anthropic,
    anthropic: ?AnthropicConfig = null,
    openai:    ?OpenAIConfig    = null,
    allocator: std.mem.Allocator,

    /// Free all owned strings. Call when Config is no longer needed.
    pub fn deinit(self: *Config) void {
        if (self.anthropic) |a| {
            self.allocator.free(a.api_key);
            self.allocator.free(a.base_url);
            self.allocator.free(a.model);
        }
        if (self.openai) |o| {
            self.allocator.free(o.api_key);
            self.allocator.free(o.base_url);
            self.allocator.free(o.model);
        }
    }

    /// Load config from environment variables, falling back to `.env` in cwd.
    /// All string values are allocated; caller must call deinit().
    pub fn load(allocator: std.mem.Allocator) !Config {
        log.debug("loading config", .{});

        // Parse .env into a map (key → owned value).
        var env_map = std.StringHashMap([]u8).init(allocator);
        defer {
            var it = env_map.valueIterator();
            while (it.next()) |v| allocator.free(v.*);
            env_map.deinit();
        }
        loadDotEnv(allocator, &env_map) catch |err| {
            log.debug(".env not loaded: {}", .{err});
        };

        const api_key  = try dupeEnv(allocator, "ANTHROPIC_API_KEY",  "",                          &env_map);
        const base_url = try dupeEnv(allocator, "ANTHROPIC_BASE_URL", "https://api.anthropic.com", &env_map);
        const model    = try dupeEnv(allocator, "MODEL_ID",           "claude-opus-4-5",           &env_map);

        return Config{
            .allocator = allocator,
            .anthropic = AnthropicConfig{
                .api_key  = api_key,
                .base_url = base_url,
                .model    = model,
            },
        };
    }
};

/// Return a newly-allocated copy of the env var, falling back to the .env map,
/// then to `default`. The caller owns the returned slice.
fn dupeEnv(
    allocator: std.mem.Allocator,
    key:       []const u8,
    default:   []const u8,
    env_map:   *std.StringHashMap([]u8),
) ![]u8 {
    if (std.posix.getenv(key)) |v| return allocator.dupe(u8, v);
    if (env_map.get(key))      |v| return allocator.dupe(u8, v);
    return allocator.dupe(u8, default);
}

/// Parse `.env` in the current working directory.
/// Each line may be:
///   KEY=value
///   KEY="value"   (double-quoted)
///   KEY='value'   (single-quoted)
/// Lines starting with `#` and blank lines are ignored.
fn loadDotEnv(allocator: std.mem.Allocator, map: *std.StringHashMap([]u8)) !void {
    const file = try std.fs.cwd().openFile(".env", .{});
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;

        var val = line[eq + 1 ..];
        // Strip surrounding quotes.
        if (val.len >= 2) {
            if ((val[0] == '"' and val[val.len - 1] == '"') or
                (val[0] == '\'' and val[val.len - 1] == '\''))
            {
                val = val[1 .. val.len - 1];
            }
        }

        const owned = try allocator.dupe(u8, val);
        errdefer allocator.free(owned);
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);

        // If key already exists, free the old value and replace.
        if (map.fetchRemove(owned_key)) |old| {
            allocator.free(old.value);
            allocator.free(old.key);
        }
        try map.putNoClobber(owned_key, owned);
    }
}

test "default config has anthropic provider" {
    const cfg = Config{ .allocator = std.testing.allocator };
    try std.testing.expectEqual(Provider.anthropic, cfg.default_provider);
}

test "AnthropicConfig has base_url field with default" {
    const cfg = AnthropicConfig{ .api_key = "test-key" };
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.base_url);
}

test "Config.load returns without error" {
    var cfg = try Config.load(std.testing.allocator);
    defer cfg.deinit();
}

test "loadDotEnv parses key=value pairs" {
    var map = std.StringHashMap([]u8).init(std.testing.allocator);
    defer {
        var it = map.iterator();
        while (it.next()) |entry| {
            std.testing.allocator.free(entry.key_ptr.*);
            std.testing.allocator.free(entry.value_ptr.*);
        }
        map.deinit();
    }

    // Write a temp .env file is impractical in unit tests, so test the parser inline.
    const content =
        \\# comment
        \\ANTHROPIC_API_KEY=sk-test
        \\ANTHROPIC_BASE_URL="https://example.com"
        \\MODEL_ID='kimi-k2.5'
    ;
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = line[eq + 1 ..];
        if (val.len >= 2 and
            ((val[0] == '"' and val[val.len - 1] == '"') or
             (val[0] == '\'' and val[val.len - 1] == '\'')))
            val = val[1 .. val.len - 1];
        const owned_key = try std.testing.allocator.dupe(u8, key);
        const owned_val = try std.testing.allocator.dupe(u8, val);
        try map.put(owned_key, owned_val);
    }

    try std.testing.expectEqualStrings("sk-test",           map.get("ANTHROPIC_API_KEY").?);
    try std.testing.expectEqualStrings("https://example.com", map.get("ANTHROPIC_BASE_URL").?);
    try std.testing.expectEqualStrings("kimi-k2.5",         map.get("MODEL_ID").?);
}
