# Agent Loop (s01) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Python `s01_agent_loop.py` demo to Zig by filling the existing jarvis skeleton with a working REPL + Anthropic SSE agent loop.

**Architecture:** Eight files are modified in dependency order (data types first, HTTP + tools in the middle, REPL last). Each task produces a compilable, tested increment. Provider interface is extended to return `LlmResponse` instead of `void`; `session.Message` gains a `content_kind` field to carry pre-serialised JSON arrays for tool results.

**Tech Stack:** Zig 0.15, `std.http.Client` (HTTP/SSE), `std.process.Child` (subprocess), `std.json` (JSON parse/stringify), `std.io.bufferedReader` (line-buffered SSE), `std.testing` (TDD).

**Spec:** `docs/superpowers/specs/2026-03-22-agent-loop-design.md`

---

## File Map

| File | What changes |
|------|-------------|
| `src/core/session.zig` | Add `ContentKind`; extend `Message`; update `Session.append` signature |
| `src/config.zig` | Add `base_url` to `AnthropicConfig`; read three env vars in `Config.load` |
| `src/llm/provider.zig` | Add `ToolUseBlock`, `StopReason`, `LlmResponse`; update `Provider.send` wrapper |
| `src/llm/anthropic.zig` | Implement full `send()`: message serialisation + HTTP POST + SSE parse |
| `src/llm/openai.zig` | Update stub `send()` to return `LlmResponse` (4-field stub) |
| `src/tools/shell.zig` | Implement `run()`: dangerous-check + `sh -c` subprocess + output capture |
| `src/tools/registry.zig` | Rename dispatch key `"shell"` → `"bash"` |
| `src/repl/app.zig` | Replace stub with REPL loop + agent loop (drops vaxis import) |

> **Note on `src/repl/render.zig`:** After Task 9 replaces `app.zig`, `render.zig` is no longer imported by anything. It is a stub with no side-effects. Run `zig build` after Task 9 to confirm it does not break the build; if it causes an unused-import error, remove the `vaxis` import from its first line.

---

## Task 1: `session.zig` — ContentKind + Message + Session.append

**Files:**
- Modify: `src/core/session.zig`

### Background
`Message.content` is currently always a plain string. We need a `content_kind` flag so the HTTP layer knows whether to embed `content` as a JSON string or as a raw JSON array literal.

- [ ] **Step 1: Write the failing tests**

Add these test blocks at the bottom of `src/core/session.zig` (after the existing test):

```zig
test "message content_kind defaults to text" {
    const m = Message{ .role = .user, .content = "hi" };
    try std.testing.expectEqual(ContentKind.text, m.content_kind);
}

test "session append with json_array content_kind" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "[{\"type\":\"tool_result\"}]", .json_array);
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try std.testing.expectEqual(ContentKind.json_array, s.messages.items[0].content_kind);
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
zig test src/core/session.zig
```

Expected: compile error — `ContentKind` not defined, `append` has wrong arity.

- [ ] **Step 3: Implement the changes**

Replace the entire contents of `src/core/session.zig` with:

```zig
const std = @import("std");

pub const Role = enum { user, assistant, system };

pub const ContentKind = enum { text, json_array };

pub const Message = struct {
    role: Role,
    content: []const u8,
    content_kind: ContentKind = .text,
};

pub const Session = struct {
    messages: std.ArrayListUnmanaged(Message) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Session) void {
        self.messages.deinit(self.allocator);
    }

    pub fn append(
        self: *Session,
        role: Role,
        content: []const u8,
        content_kind: ContentKind,
    ) !void {
        try self.messages.append(self.allocator, .{
            .role         = role,
            .content      = content,
            .content_kind = content_kind,
        });
    }
};

test "session append message" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "hello", .text);
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try std.testing.expectEqual(Role.user, s.messages.items[0].role);
}

test "message content_kind defaults to text" {
    const m = Message{ .role = .user, .content = "hi" };
    try std.testing.expectEqual(ContentKind.text, m.content_kind);
}

test "session append with json_array content_kind" {
    var s = Session.init(std.testing.allocator);
    defer s.deinit();
    try s.append(.user, "[{\"type\":\"tool_result\"}]", .json_array);
    try std.testing.expectEqual(@as(usize, 1), s.messages.items.len);
    try std.testing.expectEqual(ContentKind.json_array, s.messages.items[0].content_kind);
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/core/session.zig
```

Expected: all 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/core/session.zig
git commit -m "feat(session): add ContentKind and update append signature"
```

---

## Task 2: `config.zig` — base_url + env vars

**Files:**
- Modify: `src/config.zig`

### Background
`AnthropicConfig` is missing `base_url`. `Config.load` needs to read three env vars so the app works with kimi k2.5 (or any Anthropic-compatible endpoint) without code changes.

- [ ] **Step 1: Write the failing tests**

Add at the bottom of `src/config.zig`:

```zig
test "AnthropicConfig has base_url field with default" {
    const cfg = AnthropicConfig{ .api_key = "test-key" };
    try std.testing.expectEqualStrings("https://api.anthropic.com", cfg.base_url);
}

test "Config.load returns without error" {
    const cfg = try Config.load(std.testing.allocator);
    _ = cfg;
}
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
zig test src/config.zig
```

Expected: compile error — `base_url` field not found.

- [ ] **Step 3: Implement the changes**

Replace the entire contents of `src/config.zig` with:

```zig
const std = @import("std");

const log = std.log.scoped(.config);

pub const Provider = enum { anthropic, openai };

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
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/config.zig
```

Expected: 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/config.zig
git commit -m "feat(config): add base_url to AnthropicConfig, read env vars in load()"
```

---

## Task 3: `provider.zig` + `openai.zig` — new types, updated signatures, deinit test

**Files:**
- Modify: `src/llm/provider.zig`
- Modify: `src/llm/openai.zig`
- Modify: `src/llm/anthropic.zig` (stub only — keep it compiling)

### Background
`Provider.send` currently returns `!void`. We need it to return `!LlmResponse`. All inner structs must match. Update `anthropic.zig` to a temporary stub that compiles with the new signature — the real implementation comes in Tasks 6–8.

**Sub-step A: update `provider.zig` and `openai.zig`**

- [ ] **Step 1: Write a failing `LlmResponse.deinit` test**

Create a new file `src/llm/provider_test.zig` (or add inline to `provider.zig` at the bottom — see Step 3):

```zig
test "LlmResponse.deinit frees all owned memory" {
    const alloc = std.testing.allocator;
    var tool_calls = try alloc.alloc(ToolUseBlock, 1);
    tool_calls[0] = .{
        .id         = try alloc.dupe(u8, "tc1"),
        .name       = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":\"ls\"}"),
    };
    var r = LlmResponse{
        .stop_reason            = .end_turn,
        .tool_calls             = tool_calls,
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit(); // std.testing.allocator will catch any leak
}

test "LlmResponse.deinit empty tool_calls" {
    const alloc = std.testing.allocator;
    var r = LlmResponse{
        .stop_reason            = .tool_use,
        .tool_calls             = try alloc.alloc(ToolUseBlock, 0),
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit();
}
```

- [ ] **Step 2: Run to confirm they fail (compile error)**

```bash
zig test src/llm/provider.zig
```

Expected: compile error — types not yet defined.

- [ ] **Step 3: Replace `src/llm/provider.zig`**

```zig
const std = @import("std");
const session = @import("../core/session.zig");

pub const StreamCallback = *const fn (chunk: []const u8) void;

pub const ToolUseBlock = struct {
    id:         []const u8, // allocator.dupe'd
    name:       []const u8, // allocator.dupe'd
    input_json: []const u8, // allocator.dupe'd (raw JSON string)
};

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    unknown,
};

pub const LlmResponse = struct {
    stop_reason:             StopReason,
    tool_calls:              []ToolUseBlock,  // owned slice
    assistant_content_json:  []const u8,       // owned, dupe'd JSON array string
    allocator:               std.mem.Allocator,

    pub fn deinit(self: *LlmResponse) void {
        for (self.tool_calls) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.name);
            self.allocator.free(block.input_json);
        }
        self.allocator.free(self.tool_calls);
        self.allocator.free(self.assistant_content_json);
    }
};

pub const Provider = union(enum) {
    anthropic: @import("anthropic.zig").Anthropic,
    openai:    @import("openai.zig").OpenAI,

    pub fn send(
        self: *Provider,
        allocator: std.mem.Allocator,
        messages: []const session.Message,
        on_chunk: StreamCallback,
    ) !LlmResponse {
        return switch (self.*) {
            inline else => |*p| try p.send(allocator, messages, on_chunk),
        };
    }
};

test "LlmResponse.deinit frees all owned memory" {
    const alloc = std.testing.allocator;
    var tool_calls = try alloc.alloc(ToolUseBlock, 1);
    tool_calls[0] = .{
        .id         = try alloc.dupe(u8, "tc1"),
        .name       = try alloc.dupe(u8, "bash"),
        .input_json = try alloc.dupe(u8, "{\"command\":\"ls\"}"),
    };
    var r = LlmResponse{
        .stop_reason            = .end_turn,
        .tool_calls             = tool_calls,
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit();
}

test "LlmResponse.deinit empty tool_calls" {
    const alloc = std.testing.allocator;
    var r = LlmResponse{
        .stop_reason            = .tool_use,
        .tool_calls             = try alloc.alloc(ToolUseBlock, 0),
        .assistant_content_json = try alloc.dupe(u8, "[]"),
        .allocator              = alloc,
    };
    r.deinit();
}
```

**Sub-step B: update stubs so the project compiles**

- [ ] **Step 4: Replace `src/llm/openai.zig`**

```zig
const std   = @import("std");
const session_mod = @import("../core/session.zig");
const prov  = @import("provider.zig");

const log = std.log.scoped(.openai);

pub const OpenAI = struct {
    api_key:  []const u8,
    base_url: []const u8,
    model:    []const u8,

    pub fn send(
        self: *OpenAI,
        allocator: std.mem.Allocator,
        messages: []const session_mod.Message,
        on_chunk: prov.StreamCallback,
    ) !prov.LlmResponse {
        _ = self; _ = messages; _ = on_chunk;
        log.debug("openai send (stub)", .{});
        return prov.LlmResponse{
            .stop_reason            = .end_turn,
            .tool_calls             = try allocator.alloc(prov.ToolUseBlock, 0),
            .assistant_content_json = try allocator.dupe(u8, "[]"),
            .allocator              = allocator,
        };
    }
};
```

- [ ] **Step 5: Update `src/llm/anthropic.zig` to a compiling stub**

Replace the `send` function body only (keep the struct fields as they are):

```zig
const std = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("provider.zig");

const log = std.log.scoped(.anthropic);

pub const Anthropic = struct {
    api_key:  []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    model:    []const u8,

    pub fn send(
        self: *Anthropic,
        allocator: std.mem.Allocator,
        messages: []const session_mod.Message,
        on_chunk: prov.StreamCallback,
    ) !prov.LlmResponse {
        _ = self; _ = messages; _ = on_chunk;
        log.debug("anthropic send (stub)", .{});
        return prov.LlmResponse{
            .stop_reason            = .end_turn,
            .tool_calls             = try allocator.alloc(prov.ToolUseBlock, 0),
            .assistant_content_json = try allocator.dupe(u8, "[]"),
            .allocator              = allocator,
        };
    }
};
```

- [ ] **Step 6: Verify the project compiles and tests pass**

```bash
zig build && zig test src/llm/provider.zig
```

Expected: build succeeds; 2 `LlmResponse.deinit` tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/llm/provider.zig src/llm/openai.zig src/llm/anthropic.zig
git commit -m "feat(provider): add LlmResponse/ToolUseBlock/StopReason types, update send() to !LlmResponse"
```

---

## Task 4: `shell.zig` — dangerous-command blocking + subprocess

**Files:**
- Modify: `src/tools/shell.zig`

### Background
`shell.zig` is a stub. We implement `run()`: check for dangerous commands, spawn `sh -c <command>`, capture stdout+stderr, return combined output. `ToolResult.output` is caller-owned (allocated with the passed allocator); callers must free it.

- [ ] **Step 1: Write failing tests**

Add test blocks at the bottom of `src/tools/shell.zig`:

```zig
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
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
zig test src/tools/shell.zig
```

Expected: tests fail — stub returns empty string without blocking.

- [ ] **Step 3: Implement `src/tools/shell.zig`**

```zig
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

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 50_000);
    defer allocator.free(stdout);
    const stderr = try child.stderr.?.reader().readAllAlloc(allocator, 50_000);
    defer allocator.free(stderr);

    const term = try child.wait();
    // TODO: implement 120s timeout (kill child after timeout)
    const exit_code: u8 = switch (term) {
        .Exited => |c| c,
        else    => 1,
    };

    var combined = std.ArrayList(u8).init(allocator);
    defer combined.deinit();
    try combined.appendSlice(stdout);
    if (stderr.len > 0) try combined.appendSlice(stderr);
    if (combined.items.len > 50_000) combined.shrinkRetainingCapacity(50_000);

    if (combined.items.len == 0) {
        return ToolResult{ .output = try allocator.dupe(u8, "(no output)"), .is_error = exit_code != 0 };
    }
    return ToolResult{ .output = try allocator.dupe(u8, combined.items), .is_error = exit_code != 0 };
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/tools/shell.zig
```

Expected: 2 tests pass with no memory leaks.

- [ ] **Step 5: Commit**

```bash
git add src/tools/shell.zig
git commit -m "feat(shell): implement bash execution with dangerous-command blocking"
```

---

## Task 5: `registry.zig` — rename dispatch key to "bash"

**Files:**
- Modify: `src/tools/registry.zig`

- [ ] **Step 1: Write failing tests**

Add at the bottom of `src/tools/registry.zig`:

```zig
test "dispatch 'bash' succeeds" {
    var map = std.json.ObjectMap.init(std.testing.allocator);
    defer map.deinit();
    try map.put("command", std.json.Value{ .string = "echo registry-test" });

    const result = try dispatch(std.testing.allocator, ToolCall{
        .name  = "bash",
        .input = std.json.Value{ .object = map },
    });
    defer std.testing.allocator.free(result.output);
    try std.testing.expect(!result.is_error);
}

test "dispatch unknown tool returns is_error" {
    const result = try dispatch(std.testing.allocator, ToolCall{
        .name  = "nonexistent",
        .input = std.json.Value{ .null = {} },
    });
    try std.testing.expect(result.is_error);
}
```

- [ ] **Step 2: Run to confirm 'bash' test fails**

```bash
zig test src/tools/registry.zig
```

Expected: `dispatch 'bash'` test fails — hits "unknown tool" branch.

- [ ] **Step 3: Change `"shell"` to `"bash"` in `dispatch()`**

In `src/tools/registry.zig`, change:

```zig
if (std.mem.eql(u8, call.name, "shell")) {
```

to:

```zig
if (std.mem.eql(u8, call.name, "bash")) {
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/tools/registry.zig
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/tools/registry.zig
git commit -m "fix(registry): rename dispatch key from 'shell' to 'bash'"
```

---

## Task 6: `anthropic.zig` — message serialisation helper

**Files:**
- Modify: `src/llm/anthropic.zig`

### Background
Before doing HTTP, implement and test message-to-JSON serialisation in isolation.

- [ ] **Step 1: Write failing tests**

Add at the bottom of `src/llm/anthropic.zig`:

```zig
test "serializeMessages: text message" {
    const msgs = &[_]session_mod.Message{
        .{ .role = .user, .content = "hello world", .content_kind = .text },
    };
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try serializeMessages(msgs, buf.writer());
    try std.testing.expectEqualStrings(
        \\[{"role":"user","content":"hello world"}]
    , buf.items);
}

test "serializeMessages: json_array message" {
    const msgs = &[_]session_mod.Message{
        .{
            .role         = .assistant,
            .content      = "[{\"type\":\"text\",\"text\":\"hi\"}]",
            .content_kind = .json_array,
        },
    };
    var buf = std.ArrayList(u8).init(std.testing.allocator);
    defer buf.deinit();
    try serializeMessages(msgs, buf.writer());
    try std.testing.expectEqualStrings(
        \\[{"role":"assistant","content":[{"type":"text","text":"hi"}]}]
    , buf.items);
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
zig test src/llm/anthropic.zig
```

Expected: compile error — `serializeMessages` not defined.

- [ ] **Step 3: Add `serializeMessages` to `anthropic.zig`**

Add after the imports (before the `Anthropic` struct):

```zig
fn serializeMessages(messages: []const session_mod.Message, writer: anytype) !void {
    try writer.writeByte('[');
    for (messages, 0..) |msg, i| {
        if (i > 0) try writer.writeByte(',');
        const role_str: []const u8 = switch (msg.role) {
            .user      => "user",
            .assistant => "assistant",
            .system    => "system",
        };
        try writer.print("{{\"role\":\"{s}\",\"content\":", .{role_str});
        switch (msg.content_kind) {
            .text       => try std.json.stringify(msg.content, .{}, writer),
            .json_array => try writer.writeAll(msg.content),
        }
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/llm/anthropic.zig
```

Expected: 2 tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/llm/anthropic.zig
git commit -m "feat(anthropic): implement serializeMessages with ContentKind support"
```

---

## Task 7: `anthropic.zig` — SSE state machine

**Files:**
- Modify: `src/llm/anthropic.zig`

### Background
The SSE parser is pure logic — extract it as `processSseLine` for unit testing.

**Callback design note:** `processSseLine` uses an internal two-argument callback signature `*const fn (chunk: []const u8, ctx: *anyopaque) void` (not the public `StreamCallback`) so it can be unit-tested without closures. The public `StreamCallback` (one argument, no context) lives in `provider.zig`. The `send()` function in Task 8 bridges them with a local adapter struct.

- [ ] **Step 1: Write failing tests**

Add to the bottom of `src/llm/anthropic.zig`:

```zig
// Internal callback type used by processSseLine (not the public StreamCallback)
const SseCallback = *const fn (chunk: []const u8, ctx: *anyopaque) void;

test "SSE: text_delta calls callback" {
    const Collector = struct {
        buf: std.ArrayList(u8),
        fn cb(chunk: []const u8, ctx: *anyopaque) void {
            var self: *@This() = @ptrCast(@alignCast(ctx));
            self.buf.appendSlice(chunk) catch {};
        }
    };
    var collector = Collector{ .buf = std.ArrayList(u8).init(std.testing.allocator) };
    defer collector.buf.deinit();

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}
    , &state, Collector.cb, &collector);
    try processSseLine(
        \\{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}
    , &state, Collector.cb, &collector);

    try std.testing.expectEqualStrings("hello", collector.buf.items);
}

test "SSE: tool_use block is captured" {
    const noop = struct {
        fn cb(_: []const u8, _: *anyopaque) void {}
    };
    var dummy: u8 = 0;

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tool_123","name":"bash","input":{}}}
    , &state, noop.cb, &dummy);
    try processSseLine(
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"command\":\"ls\"}"}}
    , &state, noop.cb, &dummy);
    try processSseLine(
        \\{"type":"content_block_stop","index":1}
    , &state, noop.cb, &dummy);

    try std.testing.expectEqual(@as(usize, 1), state.tool_calls.items.len);
    try std.testing.expectEqualStrings("tool_123", state.tool_calls.items[0].id);
    try std.testing.expectEqualStrings("bash",     state.tool_calls.items[0].name);
    try std.testing.expectEqualStrings("{\"command\":\"ls\"}", state.tool_calls.items[0].input_json);
}

test "SSE: stop_reason from message_delta" {
    const noop = struct {
        fn cb(_: []const u8, _: *anyopaque) void {}
    };
    var dummy: u8 = 0;

    var state = SseState.init(std.testing.allocator);
    defer state.deinit();

    try processSseLine(
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":42}}
    , &state, noop.cb, &dummy);

    try std.testing.expectEqual(prov.StopReason.tool_use, state.stop_reason);
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
zig test src/llm/anthropic.zig
```

Expected: compile errors — `SseState`, `processSseLine`, `SseCallback` not defined.

- [ ] **Step 3: Add `SseState` and `processSseLine` to `anthropic.zig`**

Add after `serializeMessages` (before the `Anthropic` struct):

```zig
const prov = @import("provider.zig");

// Internal two-arg callback (with context pointer) used by processSseLine.
// The public StreamCallback (one-arg) is bridged in send() via a local adapter.
const SseCallback = *const fn (chunk: []const u8, ctx: *anyopaque) void;

pub const SseState = struct {
    allocator:               std.mem.Allocator,
    current_block_is_tool:   bool = false,
    current_tool_id:         std.ArrayList(u8),
    current_tool_name:       std.ArrayList(u8),
    current_input_json:      std.ArrayList(u8),
    tool_calls:              std.ArrayList(prov.ToolUseBlock),
    accumulated_text:        std.ArrayList(u8),
    stop_reason:             prov.StopReason = .unknown,

    pub fn init(allocator: std.mem.Allocator) SseState {
        return .{
            .allocator          = allocator,
            .current_tool_id    = std.ArrayList(u8).init(allocator),
            .current_tool_name  = std.ArrayList(u8).init(allocator),
            .current_input_json = std.ArrayList(u8).init(allocator),
            .tool_calls         = std.ArrayList(prov.ToolUseBlock).init(allocator),
            .accumulated_text   = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *SseState) void {
        self.current_tool_id.deinit();
        self.current_tool_name.deinit();
        self.current_input_json.deinit();
        for (self.tool_calls.items) |block| {
            self.allocator.free(block.id);
            self.allocator.free(block.name);
            self.allocator.free(block.input_json);
        }
        self.tool_calls.deinit();
        self.accumulated_text.deinit();
    }
};

pub fn processSseLine(
    data:     []const u8,
    state:    *SseState,
    on_chunk: SseCallback,
    ctx:      *anyopaque,
) !void {
    const parsed = std.json.parseFromSlice(
        std.json.Value, state.allocator, data, .{},
    ) catch return;
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else    => return,
    };
    const event_type: []const u8 = switch (obj.get("type") orelse return) {
        .string => |s| s,
        else    => return,
    };

    if (std.mem.eql(u8, event_type, "content_block_start")) {
        const cb_obj = switch (obj.get("content_block") orelse return) {
            .object => |o| o, else => return,
        };
        const block_type: []const u8 = switch (cb_obj.get("type") orelse return) {
            .string => |s| s, else => return,
        };
        state.current_block_is_tool = std.mem.eql(u8, block_type, "tool_use");
        state.current_tool_id.clearRetainingCapacity();
        state.current_tool_name.clearRetainingCapacity();
        state.current_input_json.clearRetainingCapacity();
        if (state.current_block_is_tool) {
            if (cb_obj.get("id"))   |v| if (v == .string) try state.current_tool_id.appendSlice(v.string);
            if (cb_obj.get("name")) |v| if (v == .string) try state.current_tool_name.appendSlice(v.string);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_delta")) {
        const delta = switch (obj.get("delta") orelse return) {
            .object => |o| o, else => return,
        };
        const dtype: []const u8 = switch (delta.get("type") orelse return) {
            .string => |s| s, else => return,
        };
        if (std.mem.eql(u8, dtype, "text_delta")) {
            const text: []const u8 = switch (delta.get("text") orelse return) {
                .string => |s| s, else => return,
            };
            try state.accumulated_text.appendSlice(text);
            on_chunk(text, ctx);
        } else if (std.mem.eql(u8, dtype, "input_json_delta")) {
            const partial: []const u8 = switch (delta.get("partial_json") orelse return) {
                .string => |s| s, else => return,
            };
            try state.current_input_json.appendSlice(partial);
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "content_block_stop")) {
        if (state.current_block_is_tool) {
            try state.tool_calls.append(.{
                .id         = try state.allocator.dupe(u8, state.current_tool_id.items),
                .name       = try state.allocator.dupe(u8, state.current_tool_name.items),
                .input_json = try state.allocator.dupe(u8, state.current_input_json.items),
            });
        }
        return;
    }

    if (std.mem.eql(u8, event_type, "message_delta")) {
        const delta = switch (obj.get("delta") orelse return) {
            .object => |o| o, else => return,
        };
        const sr: []const u8 = switch (delta.get("stop_reason") orelse return) {
            .string => |s| s, else => return,
        };
        state.stop_reason = parseStopReason(sr);
        return;
    }
}

fn parseStopReason(s: []const u8) prov.StopReason {
    if (std.mem.eql(u8, s, "end_turn"))      return .end_turn;
    if (std.mem.eql(u8, s, "tool_use"))      return .tool_use;
    if (std.mem.eql(u8, s, "max_tokens"))    return .max_tokens;
    if (std.mem.eql(u8, s, "stop_sequence")) return .stop_sequence;
    return .unknown;
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
zig test src/llm/anthropic.zig
```

Expected: 5 tests pass (2 serialisation + 3 SSE).

- [ ] **Step 5: Commit**

```bash
git add src/llm/anthropic.zig
git commit -m "feat(anthropic): implement SSE state machine (SseState + processSseLine)"
```

---

## Task 8: `anthropic.zig` — HTTP POST + full `send()`

**Files:**
- Modify: `src/llm/anthropic.zig`

### Background
Wire `serializeMessages` and the SSE state machine into a real HTTP POST. The `send()` function bridges the public one-arg `StreamCallback` to the two-arg `SseCallback` via a local adapter struct.

- [ ] **Step 1: Add `buildRequestBody` helper**

Add after `parseStopReason`:

```zig
fn buildRequestBody(
    self: *Anthropic,
    allocator: std.mem.Allocator,
    messages: []const session_mod.Message,
    cwd: []const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();

    const system_prompt = try std.fmt.allocPrint(
        allocator,
        "You are a coding agent at {s}. Use bash to solve tasks. Act, don't explain.",
        .{cwd},
    );
    defer allocator.free(system_prompt);

    try w.writeByte('{');
    try w.writeAll("\"model\":");
    try std.json.stringify(self.model, .{}, w);
    try w.writeAll(",\"system\":");
    try std.json.stringify(system_prompt, .{}, w);
    try w.writeAll(",\"messages\":");
    try serializeMessages(messages, w);
    try w.writeAll(",\"tools\":[{\"name\":\"bash\",\"description\":\"Run a shell command.\",\"input_schema\":{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\"}},\"required\":[\"command\"]}}]");
    try w.writeAll(",\"max_tokens\":8000,\"stream\":true}");

    return buf.toOwnedSlice();
}
```

- [ ] **Step 2: Add `buildAssistantContentJson` helper**

Add after `buildRequestBody`:

```zig
fn buildAssistantContentJson(
    allocator: std.mem.Allocator,
    state: *SseState,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeByte('[');
    var first = true;

    if (state.accumulated_text.items.len > 0) {
        first = false;
        try w.writeAll("{\"type\":\"text\",\"text\":");
        try std.json.stringify(state.accumulated_text.items, .{}, w);
        try w.writeByte('}');
    }
    for (state.tool_calls.items) |block| {
        if (!first) try w.writeByte(',');
        first = false;
        // Use std.json.stringify for id and name to handle any special characters
        try w.writeAll("{\"type\":\"tool_use\",\"id\":");
        try std.json.stringify(block.id, .{}, w);
        try w.writeAll(",\"name\":");
        try std.json.stringify(block.name, .{}, w);
        try w.writeAll(",\"input\":");
        try w.writeAll(block.input_json);  // already valid JSON
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice();
}
```

- [ ] **Step 3: Replace the stub `send()` with the full implementation**

In the `Anthropic` struct, replace the stub `send` with:

```zig
pub fn send(
    self: *Anthropic,
    allocator: std.mem.Allocator,
    messages: []const session_mod.Message,
    on_chunk: prov.StreamCallback,
) !prov.LlmResponse {
    const cwd_buf = try std.process.getCwdAlloc(allocator);
    defer allocator.free(cwd_buf);

    const body = try buildRequestBody(self, allocator, messages, cwd_buf);
    defer allocator.free(body);

    const url = try std.fmt.allocPrint(allocator, "{s}/v1/messages", .{self.base_url});
    defer allocator.free(url);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var server_header_buffer: [16 * 1024]u8 = undefined;
    var req = try client.open(.POST, uri, .{
        .server_header_buffer = &server_header_buffer,
        .extra_headers = &.{
            .{ .name = "content-type",      .value = "application/json" },
            .{ .name = "x-api-key",         .value = self.api_key },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
        },
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    try req.send();
    try req.writeAll(body);
    try req.finish();
    try req.wait();

    // Adapter: bridge public StreamCallback (1-arg) to internal SseCallback (2-arg)
    const ChunkAdapter = struct {
        public_cb: prov.StreamCallback,
        fn forward(chunk: []const u8, ctx: *anyopaque) void {
            const self2: *@This() = @ptrCast(@alignCast(ctx));
            self2.public_cb(chunk);
        }
    };
    var adapter = ChunkAdapter{ .public_cb = on_chunk };

    var state = SseState.init(allocator);
    errdefer state.deinit();

    var buf_reader = std.io.bufferedReader(req.reader());
    const reader = buf_reader.reader();
    var line_buf: [64 * 1024]u8 = undefined;

    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, line, "data: ")) {
            const data = line[6..];
            if (std.mem.eql(u8, data, "[DONE]")) break;
            try processSseLine(data, &state, ChunkAdapter.forward, &adapter);
        }
    }

    // Read stop_reason BEFORE deinit'ing state
    const stop_reason = state.stop_reason;

    const assistant_json = try buildAssistantContentJson(allocator, &state);
    const tool_calls_slice = try state.tool_calls.toOwnedSlice();
    // Clear tool_calls before deinit so deinit doesn't double-free
    state.tool_calls = std.ArrayList(prov.ToolUseBlock).init(allocator);
    state.deinit();

    return prov.LlmResponse{
        .stop_reason            = stop_reason,
        .tool_calls             = tool_calls_slice,
        .assistant_content_json = assistant_json,
        .allocator              = allocator,
    };
}
```

- [ ] **Step 4: Verify the project compiles**

```bash
zig build
```

Expected: compiles (runtime requires valid env vars).

- [ ] **Step 5: Commit**

```bash
git add src/llm/anthropic.zig
git commit -m "feat(anthropic): implement HTTP POST + SSE stream in send()"
```

---

## Task 9: `repl/app.zig` — REPL + agent loop

**Files:**
- Modify: `src/repl/app.zig`
- Modify: `src/main.zig`

### Background
Replace the vaxis stub with a simple stdin REPL. The vaxis import is removed. `render.zig` becomes a dead stub — verify it does not break the build after this task.

- [ ] **Step 1: Write a unit test for `buildToolResultsJson`**

This is a pure serialisation function we can test before implementing the full REPL:

```zig
test "buildToolResultsJson produces correct JSON" {
    const prov_mod   = @import("../llm/provider.zig");
    const reg        = @import("../tools/registry.zig");

    const tool_calls = &[_]prov_mod.ToolUseBlock{
        .{ .id = "tc1", .name = "bash", .input_json = "{\"command\":\"ls\"}" },
    };
    const results = &[_]reg.ToolResult{
        .{ .output = "file.txt\n", .is_error = false },
    };

    const json = try buildToolResultsJson(std.testing.allocator, tool_calls, results);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings(
        \\[{"type":"tool_result","tool_use_id":"tc1","content":"file.txt\n"}]
    , json);
}

test "buildToolResultsJson sets is_error for failed tool" {
    const prov_mod   = @import("../llm/provider.zig");
    const reg        = @import("../tools/registry.zig");

    const tool_calls = &[_]prov_mod.ToolUseBlock{
        .{ .id = "tc2", .name = "bash", .input_json = "{}" },
    };
    const results = &[_]reg.ToolResult{
        .{ .output = "Error: bad", .is_error = true },
    };

    const json = try buildToolResultsJson(std.testing.allocator, tool_calls, results);
    defer std.testing.allocator.free(json);

    // is_error: true must be present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"is_error\":true") != null);
}
```

- [ ] **Step 2: Run to confirm they fail**

```bash
zig test src/repl/app.zig
```

Expected: compile error.

- [ ] **Step 3: Replace `src/repl/app.zig`**

```zig
const std        = @import("std");
const session_mod = @import("../core/session.zig");
const prov        = @import("../llm/provider.zig");
const registry    = @import("../tools/registry.zig");
const config_mod  = @import("../config.zig");

const log = std.log.scoped(.repl);

fn printChunk(chunk: []const u8) void {
    std.io.getStdOut().writer().writeAll(chunk) catch {};
}

fn buildToolResultsJson(
    allocator:  std.mem.Allocator,
    tool_calls: []const prov.ToolUseBlock,
    results:    []const registry.ToolResult,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();
    const w = buf.writer();
    try w.writeByte('[');
    for (tool_calls, 0..) |tc, i| {
        if (i > 0) try w.writeByte(',');
        const res = results[i];
        try w.writeAll("{\"type\":\"tool_result\",\"tool_use_id\":");
        try std.json.stringify(tc.id, .{}, w);
        try w.writeAll(",\"content\":");
        try std.json.stringify(res.output, .{}, w);
        if (res.is_error) try w.writeAll(",\"is_error\":true");
        try w.writeByte('}');
    }
    try w.writeByte(']');
    return buf.toOwnedSlice();
}

fn agentLoop(
    allocator: std.mem.Allocator,
    sess: *session_mod.Session,
    provider: *prov.Provider,
) !void {
    const stdout = std.io.getStdOut().writer();
    while (true) {
        var response = try provider.send(allocator, sess.messages.items, printChunk);
        defer response.deinit();

        try sess.append(.assistant, response.assistant_content_json, .json_array);

        if (response.stop_reason != .tool_use) break;

        var results = try allocator.alloc(registry.ToolResult, response.tool_calls.len);
        defer allocator.free(results);

        for (response.tool_calls, 0..) |tc, idx| {
            const display = tc.input_json[0..@min(tc.input_json.len, 200)];
            try stdout.print("\x1b[33m$ {s}\x1b[0m\n", .{display});

            const parsed = try std.json.parseFromSlice(
                std.json.Value, allocator, tc.input_json, .{},
            );
            defer parsed.deinit();

            const result = try registry.dispatch(allocator, registry.ToolCall{
                .name  = tc.name,
                .input = parsed.value,
            });
            results[idx] = result;

            const preview = result.output[0..@min(result.output.len, 200)];
            try stdout.print("{s}\n", .{preview});
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
        const stdout = std.io.getStdOut().writer();
        const stdin  = std.io.getStdIn().reader();

        const anthro_cfg = self.cfg.anthropic orelse {
            try stdout.writeAll("Error: no anthropic config\n");
            return;
        };

        var provider = prov.Provider{
            .anthropic = .{
                .api_key  = anthro_cfg.api_key,
                .base_url = anthro_cfg.base_url,
                .model    = anthro_cfg.model,
            },
        };

        var sess = session_mod.Session.init(self.allocator);
        defer sess.deinit();

        var line_buf: [4096]u8 = undefined;
        while (true) {
            try stdout.writeAll("\x1b[36mjarvis >> \x1b[0m");
            const line = stdin.readUntilDelimiterOrEof(&line_buf, '\n') catch break orelse break;
            const trimmed = std.mem.trimRight(u8, line, "\r");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "q") or std.mem.eql(u8, trimmed, "exit")) break;

            const owned = try self.allocator.dupe(u8, trimmed);
            defer self.allocator.free(owned);
            try sess.append(.user, owned, .text);

            try stdout.writeByte('\n');
            agentLoop(self.allocator, &sess, &provider) catch |err| {
                try stdout.print("Error: {}\n", .{err});
            };
            try stdout.writeByte('\n');
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
```

- [ ] **Step 4: Update `src/main.zig`**

```zig
const std    = @import("std");
const Config = @import("config.zig").Config;
const App    = @import("repl/app.zig").App;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const cfg = try Config.load(allocator);

    var app = App.init(allocator, cfg);
    try app.run();
}
```

- [ ] **Step 5: Build and check `render.zig`**

```bash
zig build 2>&1
```

If `render.zig` causes an error (unused import), open it and remove the `vaxis` import line.

- [ ] **Step 6: Run tests**

```bash
zig build test
```

Expected: all tests pass.

- [ ] **Step 7: Commit**

```bash
git add src/repl/app.zig src/main.zig src/repl/render.zig
git commit -m "feat(repl): implement REPL + agent loop, wire Config to App"
```

---

## Task 10: Smoke test + tag

**Files:** none (verification only)

- [ ] **Step 1: Run the full test suite**

```bash
zig build test
```

Expected: all tests pass (session × 3, config × 3, provider × 2, shell × 2, registry × 2, anthropic × 5, app × 2).

- [ ] **Step 2: Smoke test with real API**

```bash
export ANTHROPIC_API_KEY=<your-key>
export ANTHROPIC_BASE_URL=<kimi-endpoint>   # e.g. https://api.moonshot.cn/anthropic/v1
export MODEL_ID=kimi-k2-5

zig build run
```

At the `jarvis >>` prompt:
```
list files in the current directory
```

Expected: model calls `bash` tool with `ls`, output is printed, model responds with a summary.

- [ ] **Step 3: Tag the demo**

```bash
git tag s01-agent-loop
```

---

## Quick Reference

| Command | Purpose |
|---------|---------|
| `zig build` | Compile everything |
| `zig build test` | Run all tests |
| `zig test src/core/session.zig` | Test session in isolation |
| `zig test src/config.zig` | Test config in isolation |
| `zig test src/tools/shell.zig` | Test shell in isolation |
| `zig test src/tools/registry.zig` | Test registry in isolation |
| `zig test src/llm/provider.zig` | Test provider types in isolation |
| `zig test src/llm/anthropic.zig` | Test serialisation + SSE in isolation |
| `zig build run` | Run the REPL |
