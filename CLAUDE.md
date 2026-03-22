# Jarvis — Claude Code Instructions

## Project

Zig CLI harness for AI-assisted coding, similar to Claude Code. Interactive REPL backed by libvaxis.

## Architecture

Module dependency direction is **strictly one-way**:

```
main → config
main → repl → llm → core
            → tools
            → core
```

Never import `repl` from `llm` or `tools`. Never import `llm` from `tools`.

## Key Files

| File | Purpose |
|------|---------|
| `src/llm/provider.zig` | Provider interface (tagged union) — edit here to add a new LLM backend |
| `src/tools/registry.zig` | Tool dispatch entry point — register new tools here |
| `src/repl/app.zig` | libvaxis main loop — TUI event handling |
| `src/config.zig` | Config struct — all provider settings live here |

## Conventions

**Memory**: Always pass `allocator` as a parameter. No global allocators.

**Error handling**: Propagate errors upward with `!`. `main.zig` is responsible for user-facing error messages.

**Logging**: Use scoped loggers per module:
```zig
const log = std.log.scoped(.module_name);
```
All logs go to stderr. Control level via `JARVIS_LOG=debug`.

**Testing (TDD)**:
- Write the `test` block before the implementation
- Test files live alongside source (`src/core/session.zig` has its own tests)
- Test fixtures go in `testdata/`
- Pure logic (parsing, token counting) must have tests
- I/O boundaries (HTTP, filesystem) are stubbed via function parameters

**Provider interface**: Use the `Provider` tagged union in `llm/provider.zig`. Callers must not switch on provider type outside of `provider.zig`.

**Tool dispatch**: All tool calls go through `tools/registry.zig dispatch()`. The `repl` layer never imports specific tool modules directly.

## Adding a New LLM Provider

1. Create `src/llm/<name>.zig` with a struct implementing `send(allocator, messages, on_chunk)`
2. Add the variant to the `Provider` union in `src/llm/provider.zig`
3. Add config fields in `src/config.zig`

## Adding a New Tool

1. Create `src/tools/<name>.zig` with a `run(allocator, input)` function returning `ToolResult`
2. Register in `src/tools/registry.zig dispatch()`
