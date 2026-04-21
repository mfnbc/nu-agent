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
- `tools.nu`
  - Canonical whitelist of callable tools via `TOOL_NAMES`.
- `tools.nu` canonical tools:
  - `read-file`
  - `write-file`
  - `list-files`
  - `search` (pure Nushell pipeline)
  - `replace-in-file`
  - `propose-edit`
  - `apply-edit`
  - `check-nu-syntax`
  - `self-check`
- `shredder/`
  - Rust semantic Markdown splitter that emits Nu Doc Chunk JSONL.
- `nu-ingest.nu` / `nu-ingest`
  - Nushell routing script that runs the splitter, validates chunks, and writes chunk JSONL + embedding-input jobs + manifest outputs.
- `docs/ARCHITECTURE.md`
  - Durable architecture summary.
- `docs/PROJECT_CONTRACTS.md`
  - Durable contracts for chunking, ingestion, and agent behavior.
- `docs/NEXT_SESSION_PROMPT.md`
  - Copy/paste prompt for resuming work after a context reset.

## Product Direction

Primary use cases, in order:

1. Enrichment
- Single-item JSON enrichment for structured local data.
- `nu-agent` handles one record at a time.
- Batch orchestration lives outside `nu-agent`.
- Implement `enrich` as the stable single-item entrypoint.
- Add a direct CLI path for enrichment records and schemas.
- Add a smoke test for enrichment entrypoint behavior.

2. Retrieval / knowledge base
- Deterministic ingestion from Markdown, UXLC, and StarLing.
- Rig for local embeddings only.
- Kùzu for exact structural/linguistic graph lookup.
- `nu-agent` consumes evidence, not raw corpus search.

3. Automation
- Generate Nu/Rust tooling to ingest, transform, and analyze data.

4. General data operations
- Keep the actual data operations user-driven in Nu.

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
- Implemented as `self-check`.
- Verifies all whitelisted commands exist.
- Verifies no blocked external command tokens in project `.nu` files.
- Prints machine-readable results.

3. Improve edit ergonomics
- Prefer `propose-edit` -> `apply-edit` in planner prompts.
- Add optional preview/diff-friendly output shape for large files.

4. Stabilize CLI entrypoint
- Implemented as repo-local `./nu-agent` wrapper.
- Ensure clean stdout table output for piping.
- Keep prompts and docs explicit that nu-agent is a Nushell helper, not a multi-language shell orchestrator.

5. Enrichment engine contract
- One record in, one validated JSON result out.
- stdout is reserved for the final JSON result after validation/retry.
- stderr is reserved for diagnostics and failures.
- Schema validation rejects extra keys and enforces required/non-null keys.
- Callers should use Nu `try/catch`; stderr stays free-form for humans.

## Mid-Term Options

- Add a Rust `nu_plugin` for high-performance file indexing/search.
- Add structured telemetry records for each executed tool call.
- Introduce optional parallel executor behind a flag once serial path is stable.

## Acceptance Criteria for Next Milestone

- End-to-end invocation from CLI with deterministic JSON-only model response.
- Strict whitelist enforcement with clear failures.
- No non-Nushell external tooling in core path.
- Consistent table output suitable for downstream Nushell pipelines.
