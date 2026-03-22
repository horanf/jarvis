const std = @import("std");

const log = std.log.scoped(.config);

pub const Provider = enum {
    anthropic,
    openai,
};

pub const AnthropicConfig = struct {
    api_key: []const u8,
    model: []const u8 = "claude-opus-4-5",
};

pub const OpenAIConfig = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.openai.com/v1",
    model: []const u8 = "gpt-4o",
};

pub const Config = struct {
    default_provider: Provider = .anthropic,
    anthropic: ?AnthropicConfig = null,
    openai: ?OpenAIConfig = null,

    pub fn load(allocator: std.mem.Allocator) !Config {
        _ = allocator;
        // TODO: read from ~/.config/jarvis/config.toml
        log.debug("loading config", .{});
        return Config{};
    }
};

test "default config has anthropic provider" {
    const cfg = Config{};
    try std.testing.expectEqual(Provider.anthropic, cfg.default_provider);
}
