# Jarvis

> An AI coding assistant CLI, inspired by Iron Man's J.A.R.V.I.S.

Jarvis is an interactive REPL harness similar to [Claude Code](https://github.com/anthropics/claude-code), built with [Zig](https://ziglang.org/) and [libvaxis](https://github.com/rockorager/libvaxis).

## Features (planned)

- Interactive REPL with streaming LLM responses
- Multi-provider support (Anthropic, OpenAI-compatible)
- Built-in tools: shell execution, file read/write/edit, glob, grep
- Configurable via `~/.config/jarvis/config.toml`

## Quick Start

```bash
# Build
zig build

# Run
zig build run

# Test
zig build test
```

## Configuration

Create `~/.config/jarvis/config.toml`:

```toml
[default]
provider = "anthropic"

[anthropic]
api_key = "sk-ant-..."
model = "claude-opus-4-5"

[openai]
api_key = "sk-..."
base_url = "https://api.openai.com/v1"
model = "gpt-4o"
```

## Architecture

```
src/
  main.zig          ← CLI entry point
  config.zig        ← Config loading
  core/             ← Session & token management
  llm/              ← Provider abstraction + HTTP streaming
  tools/            ← Tool registry & implementations
  repl/             ← libvaxis TUI loop & rendering
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

- [ ] libvaxis REPL loop
- [ ] Anthropic SSE streaming
- [ ] OpenAI-compatible streaming
- [ ] Tool: shell execution
- [ ] Tool: file read/write/edit
- [ ] Tool: glob/grep
- [ ] Config file parsing (TOML)
- [ ] Multi-turn conversation history
