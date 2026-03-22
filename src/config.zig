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

    pub fn load(allocator: std.mem.Allocator) !Config {
        _ = allocator;
        log.debug("loading config", .{});
        return Config{
            .anthropic = AnthropicConfig{
                .api_key  = std.posix.getenv("ANTHROPIC_API_KEY")  orelse "",
                .base_url = std.posix.getenv("ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com",
                .model    = std.posix.getenv("MODEL_ID")           orelse "claude-opus-4-5",
            },
        };
    }
};

test "default config has anthropic provider" {
    const cfg = Config{};
    try std.testing.expectEqual(Provider.anthropic, cfg.default_provider);
}

test "AnthropicConfig has base_url field with default" {
    const cfg = AnthropicConfig{ .api_key = "test-key" };
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.base_url);
}

test "Config.load returns without error" {
    const cfg = try Config.load(std.testing.allocator);
    _ = cfg;
}
