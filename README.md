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

## Project Contracts

This project is organised around a small set of intersecting contracts that define scope, responsibilities, and the developer/operator surface:

1) Enrichment
 - Single-item structured enrichment is the primary runtime contract: one validated record in, one JSON result out. This is implemented by the `enrich` entrypoints and the validation/repair helpers under `agent/`.

2) Nushell + Rust Development (Developer Contract)
 - The developer contract is intentionally different from the single-item enrichment contract. It is oriented around code and repo changes and is best expressed as diffs/patches and / or Nushell `.try` preview files rather than a single JSON input/output.
 - Preferred exchange for developer tasks:
   - The agent (or human) proposes changes as unified diffs or Nushell-generated `.try` preview files. These artifacts are reviewable, auditable, and map cleanly to code-review workflows.
   - Apply is explicit: after review, a follow-up command or patch with an explicit `--apply`/`--confirm` flag performs the write. Default behavior should be dry-run / preview.
 - Nushell is still the canonical orchestrator: use `open --raw`, `lines`, `str replace`, and `.try` workflows to build previews. For larger multi-file edits a unified diff (patch) remains an acceptable, reviewable artifact; we grandfather `diff`/`patch` for developer use but prefer in-nu approaches where practical.
 - Rust plugins (for example `crates/nu_plugin_rag`) provide performant, auditable numeric and binary operations and can be used to apply patches reliably in environments that lack system patch/git binaries.

3) Data Pipelining
 - Ingestion, shredding, embedding, and retrieval are responsibility of the RAG tooling and supporting scripts. The `nu_plugin_rag` crate and `scripts/` orchestrate chunking, embedding generation, index building, and search. Treat these pipelines as project-level resources with their own lifecycle (plan, run, resume, audit).

Treat these contracts as first-class resources when designing prompts, workflows, and automation: they map responsibilities to project subsystems (architect/planner, Nushell orchestrator, Rust plugin implementer, and data pipeline operator).

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

- `scripts/ingest-docs.nu` — high-level ingestion helper: shred Markdown, normalise chunks and command maps, and prepare embedding inputs.
- `scripts/make-data-from-chunks.nu` — normalises shredder output into `data/` and `build/nu_ingest/`.
- `scripts/embed-and-stream.nu` — streaming embed helper; prefer using the repo plugin `rag` commands for in-shell workflows.
- `crates/nu_plugin_rag` — Rust plugin + helpers: exposes `rag` plugin commands for embedding, indexing, search, persistence, and management.

See `docs/RAG.md` for a concise, up-to-date walkthrough of the RAG pipeline and the `rag` plugin command set.

Reference docs:

- `RULES.md` — hard project constraints.
- `PLAN.md` — current status and next steps.

## Canonical Execution Model

The canonical executor for agent-driven actions in this repository is the Nushell runtime (`nu`). Rather than inventing a separate RPC-style tool API, the model should emit exact Nushell commands (or a small list of Nushell command strings) which the runtime will execute inside `nu` and return structured Nushell output.

Key points:
- The agent runs inside Nushell. If a command runs in `nu` (implemented as a Nushell function or a vetted Rust plugin), it is acceptable in the current environment.
- Do not assume the agent can run arbitrary system binaries. `nu` is the canonical execution layer and should be used for file I/O and transformations.
- For now the repository continues to implement many helper Nushell functions (tools in tools.nu) for developer convenience; however, the model should still emit Nushell commands (see examples below).

Safe edit workflow (recommended)
- Use a propose → apply pattern for any file-modifying operation:
  1. Propose: the LLM re-reads the file and emits Nushell commands that build the new content in memory and save a preview to `<path>.try`. This is a NO-WRITE preview step.
  2. Inspect: human or automated checks review `<path>.try`.
  3. Apply: on explicit confirmation, the LLM emits Nushell commands to read `<path>.try` and save the result to the real path (atomic/backup strategies recommended).

Example propose (write preview to .try):
{"commands":["$orig=(open --raw src/foo.nu)","$new=($orig | str replace \"OldTitle\" \"NewTitle\")","$new | save -f src/foo.nu.try"]}

Example apply (explicit):
{"commands":["$c=(open --raw src/foo.nu.try)","$c | save -f src/foo.nu"]}

LLM output contract
- The model should return EXACTLY one JSON object. Two supported shapes:
  - commands array:
    { "commands": ["open --raw README.md", "$c=(open --raw file | str replace 'a' 'b')", "$c | save -f file.try"] }
  - script:
    { "script": "open --raw README.md\n$c=(open --raw file | str replace 'a' 'b')\n$c | save -f file.try" }
- Each command is executed sequentially in a single `nu` session so variables persist across steps.
- The runtime returns a structured run-log with per-command status, stdout/stderr, and any serialisable Nushell value.

Grandfathered diff/patch (temporary)
- `diff` and `patch` are grandfathered and permitted for now, but runtime defaults MUST be dry-run:
  - If `patch` is used without an explicit `--apply` or `--confirm` flag, treat it as a preview and do not modify repository files.
  - Prefer in-nu edits (open/lines/str replace/take/drop/str join) when possible; resort to `diff`/`patch` only when necessary.

Audit and safety
- All agent-executed commands should be logged (timestamp, run id, command summary, status). By default logs are written to stderr; an env var (AGENT_AUDIT_PATH) may be used to write an append-only audit file.
- Lightweight validation may optionally reject obvious external-shell invocations (e.g., `bash`, `sh`, `python`, or use of $nu.current-exe). In your constrained runtime these checks are advisory.

Developer helpers
- Developer-only helper functions (search-chunks, inspect-chunk, resolve-command-doc, etc.) remain implemented in tools.nu for human and developer use; they are not required to be emitted by the model. The model should instead emit Nushell commands that use these helpers when helpful (e.g., `use ./tools.nu *; resolve-command-doc --name \"open\"`).

Why this change
- Aligns docs with the policy: the canonical tool is `nu`, not a separate RPC surface.
- Simplifies LLM behavior: it emits the actual Nushell commands it needs.
- Keeps edits auditable and safe by default (propose → apply, .try files, dry-run for patch).

See the "RAG Pipeline & nu_plugin_rag" and "Running the pipeline" sections for examples of how to author ingestion and retrieval workflows using `nu` and the repo plugins.

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
archived/removed from the active tree. The project now uses a remote embedding
service by default (configurable via EMBEDDING_REMOTE_URL and EMBEDDING_MODEL).

If you need a mock embedding server for CI or local testing, run a temporary
HTTP server that matches the provider contract (POST {"model":..., "input":[...]})
and returns either { "embeddings": [[...], ...] } or { "data": [{"embedding": [...]}, ...] }.

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
