# Architecture

Physical structure of the nu-agent core: where each piece lives, and how they fit together. For the *what* and *why*, see [VISION.md](VISION.md). For contract semantics, see [CONTRACTS.md](CONTRACTS.md). For current state (what works, what's broken, what's deferred), see [STATUS.md](STATUS.md).

## Overview

nu-agent is a query tool: natural-language prompt + contract → LLM → Nushell execution → records. Each invocation passes through a narrow primitive at the bottom (`llm.nu`) into one of three contract adapters (Enrichment, Consultant, Operator). The Operator adapter is supported by a runtime layer that builds tool schemas, validates calls, and dispatches them to whitelisted Nushell commands.

```
                         ┌────────────────────────────┐
                         │           mod.nu           │  aggregator / public surface
                         └────────────────────────────┘
                                        │
              ┌─────────────────────────┼─────────────────────────┐
              │                         │                         │
  ┌───────────▼─────────┐  ┌────────────▼───────┐  ┌─────────────▼─────────┐
  │ agent/enrichment.nu │  │ agent/consultant.nu│  │    agent/runtime.nu   │
  │  (single-record IO) │  │  (prose synthesis) │  │     (airun/run-json)  │
  └───────────┬─────────┘  └────────────┬───────┘  └─────────────┬─────────┘
              │                         │                        │
              │                         │           ┌────────────▼────────────┐
              │                         │           │    agent/operator.nu    │
              │                         │           │  + agent/schema.nu      │
              │                         │           │  + tools.nu             │
              │                         │           └────────────┬────────────┘
              │                         │                        │
              └─────────────────────────┴────────────────────────┘
                                        │
                                  ┌─────▼─────┐
                                  │   llm.nu  │  thin client
                                  └─────┬─────┘
                                        │
                                   HTTP POST
                                        │
                              ┌─────────▼─────────┐
                              │    LLM endpoint   │
                              └───────────────────┘
```

## Files

### Thin client — `llm.nu`

The LLM invocation primitive. Two exports:

- **`call-llm-raw $body → string`** — takes a chat-body record, merges default `model` / `temperature` / `top_p` / `reasoning_format` / `include_reasoning` fields, POSTs to the hardcoded endpoint, returns the content string. Normalises three response shapes: chat (`choices[].message.content`), native tool-call (`choices[].message.tool_calls` — serialised into a JSON-array-of-`{name, arguments}` string so the caller sees a single content shape), and completion (`choices[].text`). Errors on empty content or unknown response shapes.
- **`call-llm $messages → string`** — thin wrapper over `call-llm-raw` for callers that supply only messages.

Endpoint URL, model name, request timeout, and reasoning-suppression flags are hardcoded constants at the top of the file. No env-var reads. When configurability returns, it does so deliberately.

### Contract adapters

Each adapter is self-contained: own system prompt, own prompt construction, own output validation or repair loop. They share only the thin client.

- **`agent/enrichment.nu`** — single-record JSON in / validated JSON out. Exports `enrich --task --record --schema [--validate-only]` and `validate-enrichment-output`. Schema shape is `{allowed, required, non_null}`; the adapter enforces no-extra-keys, required-present, non-null-not-null. One repair retry on JSON-parse or validation failure.
- **`agent/consultant.nu`** — role-parameterised prose synthesis. Exports `consult --role --prompt → string`. Role is free-form; wings supply domain roles (Nutritionist, Chess-Coach, Ledger-Auditor, Lexicographer, etc.). No tools, no JSON parsing, no repair loop.
- **`agent/operator.nu`** — tool-call emission. Exports `call-operator $task $tools → parsed calls` and `parse-json-calls-safe`. Sends `tools` in the request body; parses the LLM's JSON-array response into `[{name, arguments}, ...]`. One repair retry on parse failure. Pattern-A (tool-call whitelist) semantics preserved; a future Pattern-B shift (raw Nushell command strings) is planned post-RAG — see [STATUS.md](STATUS.md) Deferred section.

### Operator runtime

Operator is supported by three files because tool-call dispatch is materially more work than the other contracts' post-processing:

- **`agent/runtime.nu`** — orchestration. Exports `airun --task` (full loop: build tool schema → call operator → validate calls → execute serially → one continuation if under-count) and `run-json --calls` (skip the LLM, execute pre-supplied calls — useful for testing and deterministic-pipeline callers).
- **`agent/schema.nu`** — tool-schema building from live Nushell `def` signatures, whitelist enforcement against `TOOL_NAMES`, argument validation.
- **`tools.nu`** — canonical whitelist (`TOOL_NAMES`, `TOOL_REGISTRY`) and the implementations: `read-file`, `write-file`, `list-files`, `search`, `replace-in-file`, `propose-edit`, `apply-edit`, `check-nu-syntax`, `self-check`, and the retrieval helpers `search-chunks`, `inspect-chunk`, `search-embedding-input`, `resolve-command-doc`, `search-nu-concepts`.

### Shared helpers

- **`agent/json.nu`** — `coerce-json` (string-or-already-parsed-record → record). Used by every adapter.
- **`seed-template.nu`** — Hebrew/UXLC token-seed helpers. Currently at the repo root alongside the core; flagged for migration to a bible wing repository — see [STATUS.md](STATUS.md).

### Module surface

- **`mod.nu`** — aggregates the public interface. Imports: `tools.nu`, `seed-template.nu`, `agent/enrichment.nu [enrich validate-enrichment-output]`, `agent/consultant.nu [consult]`, `agent/runtime.nu [run-json airun]`.

### CLI

- **`nu-agent`** (repo-root executable) — wrapper over `mod.nu`. Three modes:
  - Enrichment: `--task --record --schema [--validate-only]`
  - Consultant: `--consultant-role --consultant-prompt`
  - General tool-calling: `--task` (routes to `airun`)

  Requires `NU_AGENT_CHAT_URL` environment variable to be set as a guard. The actual endpoint URL is hardcoded in `llm.nu`; reconciling the two into one deliberate configuration path is part of the eventual config-return work.

### Retrieval pipeline (partial — currently broken)

Retrieval is broken at multiple layers; see [STATUS.md](STATUS.md) Known Warts for specifics. The pieces that exist on disk:

- **`shredder/`** — Rust binary converting Markdown to Nu Doc Chunk JSONL.
- **`crates/nu_plugin_rag/`** — Rust crate producing `embed_runner`, `import_nu_docs`, and `nu_plugin_rag` (the latter's plugin-loader handshake is currently broken — rejects `--stdio`).
- **`scripts/ingest-docs.nu`**, **`scripts/prep-nu-rag.nu`** — ingestion orchestration scripts.

See [RAG.md](RAG.md) for the intended pipeline and [STATUS.md](STATUS.md) for what currently works and what doesn't.

## Execution flow by contract

### Enrichment

```
./nu-agent --task ... --record ... --schema ...
  → mod.nu::enrich
  → agent/enrichment.nu::run-enrichment
    → build enrichment user prompt
    → call-llm ([system, user])              # llm.nu
    → coerce-json
    → validate-enrichment-output
    (on failure: one repair prompt → same pipeline)
  → stdout: JSON record
```

### Consultant

```
./nu-agent --consultant-role ... --consultant-prompt ...
  → mod.nu::consult
  → agent/consultant.nu::call-consultant
    → consultant-system-prompt($role)
    → call-llm ([system, user])              # llm.nu
  → stdout: prose
```

### Operator

```
./nu-agent --task ...
  → mod.nu::airun
  → agent/runtime.nu::airun
    → build-tool-schema                      # agent/schema.nu + tools.nu
    → call-operator $task $tools             # agent/operator.nu
      → messages + tools body
      → call-llm-raw                         # llm.nu
      → coerce-json
      (on parse failure: one repair → same pipeline)
    → validate-calls                         # agent/schema.nu
    → run-calls: per call, invoke-tool + validate-nu-output
    (if fewer calls than expected: one continuation prompt)
  → stdout: structured results
```

## Design rules

- **Determinism over cleverness.** Retrieval returns evidence, not conclusions. Tool dispatch is serial. LLM temperature is 0.
- **Explicit contracts over implicit behaviour.** Every invocation picks exactly one contract; the contract's shape (Role × Action-Scope) is stated up front.
- **The thin client does exactly one thing.** All contract semantics live in adapters. The thin client has no knowledge of tools, JSON shapes, or enrichment schemas.
- **Each adapter is independently smoke-tested.** Changes to a primitive or adapter re-run the relevant smoke (`scripts/smoke-*.nu`).
- **Chunking is independent from indexing.** Shredder produces chunks regardless of what indexes consume them.
- **Vector and graph systems are downstream consumers.** Retrieval pipelines hang off the substrate, not the other way around.

## See also

- [VISION.md](VISION.md) — ecosystem goal and north star.
- [CONTRACTS.md](CONTRACTS.md) — contract catalogue, system-prompt templates, safety rails.
- [STATUS.md](STATUS.md) — what's implemented, in flight, deferred, or broken.
- [RAG.md](RAG.md) — retrieval pipeline (currently partially broken).
- [DEVELOPER.md](DEVELOPER.md) — build, run, smoke-test.
- [../RULES.md](../RULES.md) — hard invariants.
