# Agent Loop (s01) — Design Spec

**Date**: 2026-03-22
**Status**: Approved
**Scope**: Port Python `s01_agent_loop.py` demo to Zig, filling in existing jarvis skeleton

---

## Background

The Python demo (`s01_agent_loop.py`) demonstrates the core agent loop pattern:
- A REPL reads user input
- Sends messages to an LLM with a `bash` tool
- Executes tool calls and feeds results back
- Loops until the model stops calling tools

This spec covers porting that pattern to Zig within the existing jarvis architecture.

---

## Decisions

| Question | Decision | Rationale |
|----------|----------|-----------|
| Integration style | Fill existing skeleton (B) | Reuses session, tools, provider modules |
| API protocol | Anthropic format (`/v1/messages`) | Matches Python demo; kimi k2.5 compatible |
| Streaming | SSE streaming | More realistic; on_chunk callback for text deltas |
| Message content | Extend `session.Message` with `content_kind` | Minimal change; provider-agnostic |

---

## Architecture

Module dependency direction is unchanged:

```
main → config
main → repl → llm → core
            → tools
            → core
```

---

## Section 1: Data Types & Interface

### `src/core/session.zig` — Minimal Change

Add `ContentKind` enum and `content_kind` field to `Message`:

```zig
pub const ContentKind = enum { text, json_array };

pub const Message = struct {
    role: Role,
    content: []const u8,
    content_kind: ContentKind = .text,
};
```

- `text`: plain string content (existing behavior, default)
- `json_array`: pre-serialized JSON array string, embedded as-is in HTTP body

Update `Session.append` to accept `content_kind`:

```zig
pub fn append(
    self: *Session,
    role: Role,
    content: []const u8,
    content_kind: ContentKind,
) !void
```

Existing call sites pass `.text` explicitly.

### `src/config.zig` — Add `base_url`

Extend `AnthropicConfig` with a `base_url` field:

```zig
pub const AnthropicConfig = struct {
    api_key: []const u8,
    base_url: []const u8 = "https://api.anthropic.com",
    model: []const u8 = "claude-opus-4-5",
};
```

`Config.load` reads environment variables:

```zig
pub fn load(allocator: std.mem.Allocator) !Config {
    _ = allocator;
    return Config{
        .anthropic = AnthropicConfig{
            .api_key   = std.posix.getenv("ANTHROPIC_API_KEY")  orelse "",
            .base_url  = std.posix.getenv("ANTHROPIC_BASE_URL") orelse "https://api.anthropic.com",
            .model     = std.posix.getenv("MODEL_ID")           orelse "claude-opus-4-5",
        },
    };
}
```

### `src/llm/provider.zig` — Extended Return Type

New types (single authoritative definition):

```zig
pub const ToolUseBlock = struct {
    id: []const u8,              // owned (allocator.dupe'd during SSE parse)
    name: []const u8,            // owned (allocator.dupe'd during SSE parse)
    input_json: []const u8,      // owned (allocator.dupe'd during SSE parse)
};

pub const StopReason = enum {
    end_turn,
    tool_use,
    max_tokens,
    stop_sequence,
    unknown,        // catch-all for unrecognised values
};

pub const LlmResponse = struct {
    stop_reason: StopReason,
    tool_calls: []ToolUseBlock,        // slice owned by this struct
    assistant_content_json: []const u8, // owned; full assistant content array JSON
    allocator: std.mem.Allocator,

    /// Frees all owned memory.
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
```

**Memory ownership rule**: all `[]const u8` fields in `ToolUseBlock` and
`assistant_content_json` are `allocator.dupe`'d copies. Caller owns `LlmResponse`
and must call `deinit` when done.

Updated `Provider` union wrapper and inner-struct signature (both must return `!LlmResponse`):

```zig
// Provider union wrapper in provider.zig:
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
```

`openai.zig` stub:

```zig
pub fn send(self: *OpenAI, allocator: std.mem.Allocator,
            messages: []const session.Message, on_chunk: StreamCallback) !LlmResponse {
    _ = self; _ = messages; _ = on_chunk;
    return LlmResponse{
        .stop_reason             = .end_turn,
        .tool_calls              = try allocator.alloc(ToolUseBlock, 0),
        .assistant_content_json  = try allocator.dupe(u8, "[]"),
        .allocator               = allocator,
    };
}
```

---

## Section 2: `src/llm/anthropic.zig` — HTTP + SSE

### Request

```
POST {base_url}/v1/messages
Headers:
  x-api-key: {api_key}
  anthropic-version: 2023-06-01
  content-type: application/json
Body:
  {
    "model": "{model}",
    "system": "You are a coding agent at {cwd}. Use bash to solve tasks. Act, don't explain.",
    "messages": [...],
    "tools": [{
      "name": "bash",
      "description": "Run a shell command.",
      "input_schema": {
        "type": "object",
        "properties": { "command": { "type": "string" } },
        "required": ["command"]
      }
    }],
    "max_tokens": 8000,
    "stream": true
  }
```

Config values come from `AnthropicConfig` (passed from `main` via `App`).

### Message Serialization

- `content_kind == .text` → `{"role":"user","content":"plain string"}`
- `content_kind == .json_array` → `{"role":"user","content":[...]}` (direct embed)

### SSE Stream Parsing

Use `std.io.bufferedReader` wrapping the HTTP response reader, with
`readUntilDelimiterOrEof` on `\n` to handle TCP fragmentation.

Lines starting with `data: ` carry JSON payloads. Maintain state variable
`current_block_is_tool_use: bool` to track the active block type.

| Event type | Condition | Action |
|------------|-----------|--------|
| `content_block_start` | `block.type == "tool_use"` | Set `current_block_is_tool_use = true`; dupe `id` and `name`; init empty `input_json` ArrayList |
| `content_block_start` | `block.type == "text"` | Set `current_block_is_tool_use = false`; init empty `text` ArrayList |
| `content_block_delta` | `delta.type == "text_delta"` | Call `on_chunk(delta.text)`; append to `text` ArrayList |
| `content_block_delta` | `delta.type == "input_json_delta"` | Append to `input_json` ArrayList |
| `content_block_stop` | `current_block_is_tool_use == true` | Finalize: dupe `input_json.items`, append `ToolUseBlock` to tool_calls list |
| `content_block_stop` | `current_block_is_tool_use == false` | Finalize: dupe `text.items` for accumulated text content |
| `message_delta` | — | Capture `stop_reason` string; map to `StopReason` enum (unknown string → `.unknown`) |
| `message_stop` | — | Break loop |

### Building `assistant_content_json`

After stream ends, build the full assistant content JSON array for history:

```json
[
  {"type": "text", "text": "...accumulated text..."},
  {"type": "tool_use", "id": "...", "name": "bash", "input": {"command": "..."}}
]
```

If no text was accumulated, omit the text block. Serialize and `allocator.dupe` the result
into `LlmResponse.assistant_content_json`.

---

## Section 3: `src/tools/shell.zig` + `src/repl/app.zig`

### `src/tools/shell.zig`

Tool name dispatched as `"bash"` (matching Anthropic tool definition).

```
run(allocator, input: std.json.Value) !ToolResult
  1. Extract "command" field from input JSON
  2. Check against DANGEROUS list:
       ["rm -rf /", "sudo", "shutdown", "reboot", "> /dev/"]
     → return ToolResult{ .output="Error: Dangerous command blocked", .is_error=true }
  3. std.process.Child with argv = &[_][]const u8{ "sh", "-c", command }
     stdout and stderr both captured (pipe)
     timeout: 120s (TODO: kill child after 120s; stub acceptable for initial impl)
  4. Collect stdout + stderr (concatenated), truncate to 50000 bytes
  5. Return ToolResult{ .output = combined, .is_error = (exit_code != 0) }
```

### `src/tools/registry.zig` — Tool Name Change

Update dispatch condition from `"shell"` to `"bash"`:

```zig
if (std.mem.eql(u8, call.name, "bash")) {
    return @import("shell.zig").run(allocator, call.input);
}
```

### tool_result JSON Format

```json
[
  {
    "type": "tool_result",
    "tool_use_id": "<id from ToolUseBlock.id>",
    "content": "<output string>",
    "is_error": true
  }
]
```

`is_error` may be omitted or set to `false` when `ToolResult.is_error == false`; both
are valid per the Anthropic API. Implementations may include it unconditionally for
simplicity.

If multiple tool calls exist in one turn, all results appear in the same array.

### `src/repl/app.zig` — Agent Loop

```
App.run():
  load Config (reads env vars)
  build Provider (.anthropic)
  var session = Session.init(allocator)
  defer session.deinit()

  loop (REPL):
    print "\x1b[36mjarvis >> \x1b[0m", read line from stdin
    if EOF or "q"/"exit"/"" → break
    session.append(.user, line, .text)

    agent_loop(&session, &provider):
      while true:
        var response = try provider.send(allocator, session.messages.items, printChunk)
        defer response.deinit()

        // Append full assistant content array to history
        try session.append(.assistant, response.assistant_content_json, .json_array)

        if response.stop_reason != .tool_use → break

        // Execute each tool call
        var results_json = try buildToolResultsJson(allocator, response.tool_calls)
        defer allocator.free(results_json)

        for each tool_call in response.tool_calls:
          print "\x1b[33m$ {command}\x1b[0m"
          result = tools.dispatch(allocator, ToolCall{.name=tool_call.name, ...})
          print result.output[0..min(200, len)]

        try session.append(.user, results_json, .json_array)

buildToolResultsJson(allocator, tool_calls, results) []const u8:
  serialize to JSON array (see format above)
  return allocator.dupe'd result

printChunk(chunk: []const u8) void:
  write chunk to stdout
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/core/session.zig` | Add `ContentKind`; extend `Message`; update `Session.append` |
| `src/config.zig` | Add `base_url` to `AnthropicConfig`; read env vars in `Config.load` |
| `src/llm/provider.zig` | Add `ToolUseBlock`, `StopReason`, `LlmResponse`; update `send()` signature |
| `src/llm/anthropic.zig` | Implement HTTP POST + SSE parsing + response serialization |
| `src/llm/openai.zig` | Update `send()` signature; return stub `LlmResponse` (4 fields) |
| `src/tools/shell.zig` | Implement bash execution with dangerous-command blocking |
| `src/tools/registry.zig` | Rename dispatch key from `"shell"` to `"bash"` |
| `src/repl/app.zig` | Implement REPL + agent loop |

---

## Testing

Per CLAUDE.md TDD convention — test blocks written before implementation:

- `session.zig`: `content_kind` default is `.text`; `append` with `.json_array` stores correctly
- `shell.zig`: dangerous command returns `is_error=true`; successful command returns stdout
- `anthropic.zig`: message serialization (`.text` vs `.json_array`); SSE line parser with sample event data; `LlmResponse.deinit` with `std.testing.allocator` (no leak)
- `registry.zig`: `"bash"` dispatches to `shell.run`; unknown name returns `is_error=true`
- `repl/app.zig`: agent loop with mock provider: first call returns `.tool_use`, second returns `.end_turn`; verify session message count
