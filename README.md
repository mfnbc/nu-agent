# nu-agent

Deterministic Nushell tool orchestrator.

`nu-agent` is a helper for Nushell only. It is not a general-purpose coding assistant.

## Core Contract

- Input: prompt/task + Nushell tool schema
- Model output: JSON array of tool calls only
- Runtime output: Nushell table/records on stdout

Conceptually:

`(Prompt + ToolSchema) -> JSON Calls -> Nushell Tool Execution -> Table`

## Project Guarantees

- JSON-only LLM output (`[{ name, arguments }]`)
- No prose/explanations/markdown from the model
- System prompt defines the model as a Nushell expert
- System prompt defines the model as Nushell-only controller/developer
- Whitelist-only callable tools (`tool-registry.nu`)
- Serial execution (no parallel scheduler yet)
- Stateless core (state is controller/user owned)
- No external text-processing tool dependency in core path (`jq`, `grep`, `patch`, etc.)

## Files

- `mod.nu` - core pipeline (schema build, parse/validate, execution)
- `api.nu` - `http post` wrapper with strict no-prose system prompt
- `tools.nu` - canonical Nushell tools
- `tool-registry.nu` - explicit tool whitelist
- `RULES.md` - hard project constraints
- `PLAN.md` - current status and next steps

## Canonical Tools

- `read-file --path <string>`
- `write-file --path <string> --content <string>`
- `list-files --path <string>`
- `search --pattern <string> --path <string>`
- `replace-in-file --path <string> --pattern <string> --replacement <string>`
- `propose-edit --path <string> --pattern <string> --replacement <string>`
- `apply-edit --file <string> --after <string>`

## Usage

Example with Nushell:

```nu
use ./mod.nu *
airun --task "refactor"
```

Deterministic local execution test (no LLM):

```nu
use ./mod.nu *
run-json --calls '[{"name":"list-files","arguments":{"path":"."}}]'
```

Planned CLI form:

```bash
nu-agent --task "refactor"
```

## Notes

- Prefer `propose-edit` -> `apply-edit` for inspectable edits.
- For multi-step requests, the model must emit every requested tool call in order.
- For edit preview requests, `propose-edit` should be used so the preview is surfaced.
- Rust is allowed only as `nu_plugin` extensions exposed back as Nushell tools.

## LLM Backend Configuration

`api.nu` supports OpenAI-compatible endpoints via env vars:

- `NU_AGENT_CHAT_URL` (default: `https://api.openai.com/v1/chat/completions`)
- `NU_AGENT_MODEL` (default: `gpt-5.3-chat-latest`)
- `NU_AGENT_API_KEY` (optional; falls back to `OPENAI_API_KEY`)

Example for LM Studio:

```nu
$env.NU_AGENT_CHAT_URL = "http://127.0.0.1:1234/v1/chat/completions"
$env.NU_AGENT_MODEL = "qwen2.5-coder-7b-instruct"
```
