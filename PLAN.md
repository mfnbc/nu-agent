# nu-agent Plan

## Current Status

Implemented:

- `mod.nu`
  - Builds tool schema from Nushell command signatures.
  - Parses and validates LLM JSON tool calls.
  - Enforces whitelist and executes calls serially.
- `api.nu`
  - Wraps `http post` for LLM calls.
  - Injects strict no-prose system prompt.
  - Rejects non-array responses.
- `tool-registry.nu`
  - Explicit whitelist of callable tools.
- `tools.nu` canonical tools:
  - `read-file`
  - `write-file`
  - `list-files`
  - `search` (pure Nushell pipeline)
  - `replace-in-file`
  - `propose-edit`
  - `apply-edit`

## Decisions Locked In

- Whitelist only; no arbitrary command execution.
- Serial execution only for now.
- Keep core stateless.
- No external processing tools like `jq`/`grep`/`patch`.
- Nushell-only helper model: agent work is expressed as Nushell tool calls.
- Rust is allowed only as `nu_plugin` extension exposed back through Nushell tools.

## Near-Term Next Steps

1. Tighten schema validation
- Validate unknown arguments per-tool.
- Enforce required args before invocation.
- Improve type mapping from Nushell signatures.

2. Add runtime self-check command
- Verify all whitelisted commands exist.
- Verify no blocked external command tokens in project `.nu` files.
- Print machine-readable results.

3. Improve edit ergonomics
- Prefer `propose-edit` -> `apply-edit` in planner prompts.
- Add optional preview/diff-friendly output shape for large files.

4. Stabilize CLI entrypoint
- Provide a single user-facing command (`nu-agent --task ...`).
- Ensure clean stdout table output for piping.
- Keep prompts and docs explicit that nu-agent is a Nushell helper, not a multi-language shell orchestrator.

## Mid-Term Options

- Add a Rust `nu_plugin` for high-performance file indexing/search.
- Add structured telemetry records for each executed tool call.
- Introduce optional parallel executor behind a flag once serial path is stable.

## Acceptance Criteria for Next Milestone

- End-to-end invocation from CLI with deterministic JSON-only model response.
- Strict whitelist enforcement with clear failures.
- No non-Nushell external tooling in core path.
- Consistent table output suitable for downstream Nushell pipelines.
