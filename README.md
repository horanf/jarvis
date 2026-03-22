# Jarvis

> An AI coding assistant CLI, inspired by Iron Man's J.A.R.V.I.S.

Jarvis is an interactive REPL harness similar to [Claude Code](https://github.com/anthropics/claude-code), built with [Zig](https://ziglang.org/) and [libvaxis](https://github.com/rockorager/libvaxis).

## What works today

- **Interactive REPL** with streaming LLM responses (stdin readline loop)
- **Anthropic provider** — SSE streaming via [anthropic-sdk-zig](https://github.com/horanf/anthropic-sdk-zig)
- **Bash tool** — shell execution with dangerous-command blocking
- **Multi-turn conversation** history (Session)
- **`.env` config** — API key, base URL, model ID loaded from environment or `.env` file

## Coming soon

- Full libvaxis TUI interface
- OpenAI-compatible streaming
- File tools (read / write / edit)
- Glob / Grep tools
- TOML config file (`~/.config/jarvis/config.toml`)

## Quick Start

**Prerequisites**: Zig 0.15.2+, and `anthropic-sdk-zig` checked out as a sibling directory:

```
parent/
  jarvis/
  anthropic-sdk-zig/
```

```bash
# Build
zig build

# Run
zig build run

# Test
zig build test
```

## Configuration

Copy `.env.example` to `.env` and fill in your values:

```bash
cp .env.example .env
```

```dotenv
ANTHROPIC_API_KEY=sk-ant-...
ANTHROPIC_BASE_URL=https://api.anthropic.com
MODEL_ID=claude-opus-4-5
```

Environment variables take precedence over `.env` values.

## Architecture

```
src/
  main.zig          ← CLI entry point
  config.zig        ← Config loading (.env + env vars)
  core/             ← Session & token management
  llm/              ← Provider abstraction + Anthropic SDK wrapper
  tools/            ← Tool registry & implementations (bash)
  repl/             ← Agent loop & stdin REPL
```

**Dependency direction** (one-way, no cycles):

```
main → config
main → repl → llm → core
            → tools
            → core
```

## Development

```bash
# Install pre-commit hooks
lefthook install

# Format check
zig fmt --check src/

# Run all tests
zig build test
```

## Roadmap

- [x] Anthropic SSE streaming
- [x] Agent loop (tool call → execute → feed result back)
- [x] Tool: bash execution (with dangerous-command guard)
- [x] Multi-turn conversation history
- [x] `.env` config loading
- [ ] Full libvaxis TUI loop
- [ ] OpenAI-compatible streaming
- [ ] Tool: file read / write / edit
- [ ] Tool: glob / grep
- [ ] TOML config file
