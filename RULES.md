# nu-agent Rules

This project is intentionally strict. The goal is deterministic tool-calling from Nushell with no conversational behavior and no shell drift.

nu-agent is a helper for Nushell only. It is not a general-purpose coding assistant.

## Product Rules

- LLM output must be a valid JSON array only.
- No prose, no explanations, no markdown, no code fences.
- System prompt must frame the model as a Nushell expert.
- System prompt must frame the model as a Nushell-only controller/developer.
- JSON call shape:
  - `name: string`
  - `arguments: object`
- Execution model is serial (no parallel execution yet).
- Interface is CLI-first (example: `nu-agent --task "refactor"`).
- Runtime output must stay structured; enrichment mode emits validated JSON on stdout.

## Tooling and Language Boundary

- Only whitelisted Nushell `def` commands are callable.
- No arbitrary command execution.
- No external text-processing tools (`jq`, `grep`, `sed`, `awk`, `patch`, etc.).
- Primary implementation language is Nushell.
- Optional extension path is Rust via `nu_plugin` only, exposed back as Nushell commands.
- The agent must plan and act through Nushell tools; it must not generate workflows in other shells/languages.
- Prefer pure Nushell pipelines and `where`-driven filtering where possible.

## RAG plugin constraint

- Any RAG-related automation must follow the same rule: implementation languages are Nushell for orchestration and Rust for heavy lifting (nu_plugin crates or Rust-built binaries). No other languages (Python, Node, etc.) are permitted in the core pipeline.
- The `nu_plugin_rag` is the sanctioned extension point for RAG tasks and must expose Nushell commands that implement the pipeline steps described in docs/RAG.md.

## Architecture Rules

- Core contract: `(Prompt + ToolSchema) -> JSON Calls`.
- Keep runtime state outside the agent core (controller/user-owned state).
- No conversational UI in the agent runtime.
- Tools are discovered from an explicit whitelist (`TOOL_NAMES` const in `tools.nu`).
- Unknown tool names are rejected.
- The runtime is a Nushell tool orchestrator only; all capabilities must be represented as Nushell-callable tools.
- Document shredding must remain independent from vector or graph indexing.
- Retrieval tools must return evidence, not conclusions.
- Retrieval is deterministic; no LLM-based searching.
- Durable contracts should live in `docs/` so they survive context resets.
- The canonical long-lived architecture statement lives in `docs/ARCHITECTURAL_MANIFEST.md`.

## Editing Rules

- Prefer non-mutating flow when possible:
  - `propose-edit` first
  - `apply-edit` second
- `replace-in-file` exists for direct mutation, but proposal/apply split is preferred.

## API Rules

- API wrapper must enforce strict no-prose system prompt.
- Temperature should stay deterministic (`0`).
- Returned content must parse as JSON array before execution.

## Runtime Contract

- `nu-agent` is single-item only; batching belongs in external tooling.
- Successful enrichment emits only validated JSON on stdout.
- Failures report via stderr and a non-zero exit code.
- Callers should use Nushell `try/catch` for failures; stderr remains free-form for humans.
- Schema validation rejects extra keys.
- Schema validation enforces required keys and non-null keys.

## Current Non-Goals

- No parallel tool scheduling yet.
- No long-term memory/state layer in core.
