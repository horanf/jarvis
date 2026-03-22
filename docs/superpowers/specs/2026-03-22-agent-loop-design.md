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

- `text`: plain string content (existing behavior)
- `json_array`: pre-serialized JSON array string, embedded as-is in HTTP body

### `src/llm/provider.zig` — Extended Return Type

New types:

```zig
pub const ToolUseBlock = struct {
    id: []const u8,         // used to build tool_result
    name: []const u8,       // e.g. "bash"
    input_json: []const u8, // raw JSON: {"command":"ls"}
};

pub const StopReason = enum { end_turn, tool_use, max_tokens };

pub const LlmResponse = struct {
    stop_reason: StopReason,
    tool_calls: []ToolUseBlock,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *LlmResponse) void;
};
```

Updated `send` signature:

```zig
pub fn send(
    self: *Provider,
    allocator: std.mem.Allocator,
    messages: []const session.Message,
    on_chunk: StreamCallback,
) !LlmResponse
```

`on_chunk` is called for each streamed text delta (for display). `LlmResponse` carries `stop_reason` and any `tool_use` blocks.

---

## Section 2: `src/llm/anthropic.zig` — HTTP + SSE

### Request

```
POST {ANTHROPIC_BASE_URL}/v1/messages
Headers:
  x-api-key: {api_key}
  anthropic-version: 2023-06-01
  content-type: application/json
Body:
  {
    "model": "{MODEL_ID}",
    "system": "You are a coding agent at {cwd}. Use bash to solve tasks.",
    "messages": [...],
    "tools": [{ "name": "bash", "description": "...", "input_schema": {...} }],
    "max_tokens": 8000,
    "stream": true
  }
```

### Message Serialization

- `content_kind == .text` → `{"role":"user","content":"plain string"}`
- `content_kind == .json_array` → `{"role":"user","content":[...]}` (direct embed)

### SSE Stream Parsing

Read response body line by line. Lines starting with `data: ` carry JSON payloads:

| Event type | Action |
|------------|--------|
| `content_block_start` with `type=tool_use` | Record `id`, `name`; start accumulating `input_json` |
| `content_block_delta` with `type=text_delta` | Call `on_chunk(delta.text)` |
| `content_block_delta` with `type=input_json_delta` | Append to `input_json` buffer |
| `content_block_stop` | Finalize current block |
| `message_delta` | Capture `stop_reason` |
| `message_stop` | Break loop, return `LlmResponse` |

### Environment Variables

| Variable | Usage |
|----------|-------|
| `ANTHROPIC_BASE_URL` | Base URL (e.g. kimi endpoint) |
| `ANTHROPIC_API_KEY` | API key header |
| `MODEL_ID` | Model identifier |

---

## Section 3: `src/tools/shell.zig` + `src/repl/app.zig`

### `src/tools/shell.zig`

```
run(allocator, input: std.json.Value) !ToolResult
  1. Extract "command" field from input JSON
  2. Check against DANGEROUS list:
       ["rm -rf /", "sudo", "shutdown", "reboot", "> /dev/"]
     → return error ToolResult if matched
  3. std.process.Child("sh", &["-c", command])
     timeout: 120s
  4. Collect stdout + stderr, truncate to 50000 bytes
  5. Return ToolResult{ .output = combined, .is_error = exit_code != 0 }
```

### `src/repl/app.zig` — Agent Loop

Mirrors Python `agent_loop()`:

```
App.run():
  load config (ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY, MODEL_ID)
  history = []Message

  loop:
    print "jarvis >> ", read line from stdin
    if EOF or "q"/"exit" → break
    append Message{ .role=.user, .content=line, .content_kind=.text }

    agent_loop(history):
      while true:
        response = provider.send(history, on_chunk=printYellow)
        // append assistant text to history

        if response.stop_reason != .tool_use → break

        tool_results = []
        for each tool_call in response.tool_calls:
          print command in yellow
          result = tools.dispatch(tool_call.name, tool_call.input_json)
          print first 200 chars of result
          tool_results.append(tool_result JSON)

        // serialize tool_results to JSON array string
        append Message{
          .role = .user,
          .content = serialized_json,
          .content_kind = .json_array,
        }
```

---

## Files Changed

| File | Change |
|------|--------|
| `src/core/session.zig` | Add `ContentKind`, extend `Message` |
| `src/llm/provider.zig` | Add `ToolUseBlock`, `StopReason`, `LlmResponse`; update `send()` signature |
| `src/llm/anthropic.zig` | Implement HTTP POST + SSE parsing |
| `src/tools/shell.zig` | Implement bash execution |
| `src/repl/app.zig` | Implement REPL + agent loop |

`src/config.zig`, `src/tools/registry.zig`, `src/llm/openai.zig` unchanged.

---

## Testing

Per CLAUDE.md TDD convention — test blocks written before implementation:

- `session.zig`: test `content_kind` default; test `json_array` message append
- `shell.zig`: test dangerous command blocking; test successful command output
- `anthropic.zig`: test message serialization (text vs json_array); test SSE line parsing
- `repl/app.zig`: test agent loop with mock provider returning `.tool_use` then `.end_turn`
