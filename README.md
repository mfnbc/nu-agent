# nu-agent

Deterministic Nushell tool orchestrator.

`nu-agent` is a helper for Nushell only. It is not a general-purpose coding assistant.
It is also the single-item primitive for deterministic data enrichment: one structured record in, one validated JSON result out.

## Core Contract

- Input: prompt/task + Nushell tool schema
- Model output: JSON array of tool calls only
- Runtime output: structured results; enrichment mode emits validated JSON on stdout

Conceptually:

`(Prompt + ToolSchema) -> JSON Calls -> Nushell Tool Execution -> Table`

## Project Guarantees

- JSON-only LLM output (`[{ name, arguments }]`)
- No prose/explanations/markdown from the model
- System prompt defines the model as a Nushell expert
- System prompt defines the model as Nushell-only controller/developer
- Whitelist-only callable tools (`TOOL_NAMES` in `tools.nu`)
- Serial execution (no parallel scheduler yet)
- Stateless core (state is controller/user owned)
- No external text-processing tool dependency in core path (`jq`, `grep`, `patch`, etc.)
- Single-item execution only; batching lives outside `nu-agent`
- Enrichment output is strict JSON only on stdout after validation and retry
- Schema validation rejects extra keys and enforces required/non-null keys

## Files

Core agent surface:

- `mod.nu` — thin aggregator that re-exports the public commands (`airun`, `run-json`, `enrich`) and canonical tools.
- `agent/runtime.nu` — builds tool schemas at runtime, validates model output, and executes whitelisted commands.
- `agent/schema.nu` — inspects Nushell command signatures and enforces the whitelist/argument contract.
- `agent/llm.nu` — JSON-only response parsing and repair around the LLM API.
- `agent/enrichment.nu` — single-record enrichment entrypoint and schema validation.
- `agent/json.nu` — shared JSON helpers used by multiple layers.
- `api.nu` — `http post` wrapper with strict no-prose system prompt.
- `tools.nu` — canonical Nushell tools plus the single-source `TOOL_REGISTRY` metadata.

Optional retrieval tooling (not required for the agent runtime):

- `scripts/ingest-docs.nu` — wraps shredding, command-map generation, and embedding production into a single command.
- `scripts/make-data-from-chunks.nu` — normalises shredder output into the `data/` and `build/nu_ingest/` stores used by the tools.
  (Note: `make-data-from-chunks.nu` will automatically aggregate per-file `.chunks.msgpack`
  outputs from `build/nu_ingest/` into a consolidated `chunks.msgpack` if the consolidated
  corpus is missing.)
- `target/debug/embed_runner`, `target/debug/nu-search` — binaries built from `crates/nu_plugin_rag` that generate deterministic embeddings and let you smoke-test similarity search.

See `docs/RAG.md` for an end-to-end walkthrough of the pipeline.

Reference docs:

- `RULES.md` — hard project constraints.
- `PLAN.md` — current status and next steps.

## Canonical Tools

- `read-file --path <string>`
- `write-file --path <string> --content <string>`
- `list-files --path <string>`
- `search --pattern <string> --path <string>`
- `search-chunks --path <string> --pattern <string>`
- `replace-in-file --path <string> --pattern <string> --replacement <string>`
- `inspect-rig-plan --path <string> [--table <string>] [--limit <int>]`
- `inspect-chunk --path <string> --id <string> [--neighbors]`
- `search-embedding-input --path <string> --pattern <string> [--limit <int>]`
- `propose-edit --path <string> --pattern <string> --replacement <string>`
- `apply-edit --file <string> --after <string>`
- `check-nu-syntax --path <string>`
- `self-check`

Schema is strict: unsupported argument types are rejected early, and invalid JSON output from the model is wrapped with a project-specific error.

## Module Exports

- `enrich --task <string> --record <json> --schema <json>` — single-item structured enrichment; validates output against a schema

## Usage

Example with Nushell:

```nu
use ./mod.nu *
airun --task "refactor"
```

Single-item enrichment example:

```nu
use ./mod.nu *
enrich --task "annotate workout" --record '{"exercise":"squat","reps":5}' --schema '{"allowed":["label","notes"],"required":["label"],"non_null":["label"]}'
```

Repo-local CLI wrapper for enrichment:

```bash
NU_AGENT_CHAT_URL=http://127.0.0.1:1234/v1/chat/completions ./nu-agent --task "annotate workout" --record '{"exercise":"squat","reps":5}' --schema '{"allowed":["label"],"required":["label"],"non_null":["label"]}'
```

Deterministic local execution test (no LLM):

```nu
use ./mod.nu *
run-json --calls '[{"name":"list-files","arguments":{"path":"."}}]'
```

RAG pipeline quick start:

```bash
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force
```

The script shreds the Markdown, normalises chunk/command data, emits embedding
inputs, and (when the compiled `embed_runner` binary is available) writes
deterministic embeddings. See `docs/RAG.md` for the full walkthrough, including
commands for git sources (`scripts/prep-nu-rag.nu`) and optional smoke-search
steps.

Repo-local CLI wrapper:

```bash
NU_AGENT_CHAT_URL=http://127.0.0.1:1234/v1/chat/completions ./nu-agent --task "refactor"
```

The CLI requires `NU_AGENT_CHAT_URL` so it points at your local or test LLM endpoint.
It prints a short notice before calling the model, since some local models can take several minutes to respond.

## Notes

- Prefer `propose-edit` -> `apply-edit` for inspectable edits.
- For multi-step requests, the model must emit every requested tool call in order.
- For edit preview requests, `propose-edit` should be used so the preview is surfaced.
- Rust is allowed only as `nu_plugin` extensions exposed back as Nushell tools.

## LLM Backend Configuration

`api.nu` supports OpenAI-compatible endpoints via env vars:

- `NU_AGENT_CHAT_URL` (default: `https://api.openai.com/v1/chat/completions`)
- `NU_AGENT_MODEL` (default: `gpt-4o`)
- `NU_AGENT_API_KEY` (optional; falls back to `OPENAI_API_KEY`)

Example for LM Studio:

```nu
$env.NU_AGENT_CHAT_URL = "http://127.0.0.1:1234/v1/chat/completions"
$env.NU_AGENT_MODEL = "qwen2.5-coder-7b-instruct"
```

## Enrichment Contract

`nu-agent` is designed to enrich one record at a time.

- Input: one structured record plus a target schema and prompt
- Output: one validated JSON result on stdout
- Errors: diagnostics on stderr and non-zero exit code
- Batch iteration, retries across a dataset, and persistence live in a separate batch tool
- `enrich` is the stable single-item entrypoint

Recommended caller pattern:

```nu
let result = (try {
  ./nu-agent --task "annotate workout" --record '{"exercise":"squat"}' --schema '{"allowed":["exercise"],"required":["exercise"],"non_null":["exercise"]}' --validate-only
} catch { |err|
  error make { msg: ($err.msg? | default "nu-agent enrichment failed") }
})
```

For now, keep stderr free-form and let Nushell `try/catch` handle failures. Do not depend on parsing stderr as JSON.

## Token Seed Pass

The first seed pass can turn a normalized Hebrew token into a structured record:

```nu
use ./mod.nu *

let token = {
  surface: "אַ֥שְֽׁרֵי־"
  volume: "Ketuvim"
  book: "Tehillim"
  chapter: 1
  verse: 1
}

let seed = (token-seed-input $token)
let prompt = (seed-prompt $seed)
let schema = (token-seed-schema)
```

That seed record is then sent to the LLM, which fills in the missing fields while
preserving the same JSON object shape.

## RAG Pipeline & nu_plugin_rag

This repository now includes a documented plan and Nushell-first tooling for building
a Retrieval-Augmented Generation (RAG) artifact from Nushell documentation and other
corpora. The goals and orchestration are described in docs/RAG.md.

Key points:

- The preferred workflow is Nushell + Rust only. No Python or other scripting languages
  are required by the core pipeline.
- A repo-local plugin called `nu_plugin_rag` is planned to expose commands such as
  `rag.prepare-deps`, `rag.build`, `rag.status`, and `rag.rebuild` as Nushell commands.
- The pipeline is intentionally idempotent and safe-by-default: ingestion writes chunk, command, and embedding artefacts to disk; database imports remain opt-in and external.
- See `docs/RAG.md` for the canonical walkthrough, artefact layout, and contributor notes.

Note: The repository previously contained a vendored FAISS tree under
`build/faiss_local` (FAISS demos and C/Python bindings). That directory has been
archived/removed from the active tree in favor of the Rust `fastembed`-based
embedding path used by the `nu_plugin_rag` crate. FAISS remains available in
history if needed, but it is not part of the default build or runtime path.

### Running the pipeline

1. **Build the Rust helpers once**

   ```bash
   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
   ```

   This produces `target/debug/embed_runner` and `target/debug/nu-search`, which
the scripts rely on when generating embeddings and running smoke searches.

2. **Ingest Markdown and generate embeddings**

   ```bash
   nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force
   # or: nu scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs --force
   ```

   This runs the shredder, normalises chunk/command data, emits embedding inputs,
   and (when `embed_runner` is available) writes deterministic embeddings into
   `--out-dir/embeddings/`.

3. **Querying the artefacts**

   ```nu
   use ./tools.nu *
   resolve-command-doc --name "open"
   search-nu-concepts --query "pipeline" --limit 3
   ```

   You can also run `target/debug/nu-search` directly against the generated
embeddings for quick similarity checks.
