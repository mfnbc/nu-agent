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

- `mod.nu` - core pipeline (schema build, parse/validate, execution)
- `api.nu` - `http post` wrapper with strict no-prose system prompt
- `tools.nu` - canonical Nushell tools
- `rig_plan.nu` - deterministic LanceDB job manifest generator for Rig embedding input
- `rig_run.nu` - Rig FastEmbed execution harness (dry-run/execute/validate)
- `kuzu_plan.nu` - deterministic Kùzu node/edge export planner
- `RULES.md` - hard project constraints
- `PLAN.md` - current status and next steps

## Canonical Tools

- `read-file --path <string>`
- `write-file --path <string> --content <string>`
- `list-files --path <string>`
- `search --pattern <string> --path <string>`
- `search-chunks --path <string> --pattern <string>`
- `replace-in-file --path <string> --pattern <string> --replacement <string>`
- `inspect-rig-plan --path <string> [--table <string>] [--limit <int>]`
- `inspect-kuzu-plan --path <string> [--kind <string>] [--limit <int>]`
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

Deterministic Markdown ingestion:

```bash
./nu-ingest README.md --out-dir build/nu-ingest
```

This writes JSONL chunks, embedding-input jobs, and a manifest under the output directory. Each Markdown file produces both `<name>.chunks.jsonl` and `<name>.embedding_input.jsonl` so Rig/FastEmbed can index the derived inputs deterministically.

Generate a LanceDB ingestion plan for Rig/FastEmbed:

```nu
use ./rig_plan.nu *
rig-plan build/nu-ingest/manifest.json --lancedb-dir build/lancedb --out build/rig-plan.json
```

Inspect (or execute) the deterministic Rig FastEmbed commands:

```nu
use ./rig_run.nu *
rig-run build/rig-plan.json                    # dry-run (default)
rig-run build/rig-plan.json --validate         # add dataset presence check (skips if not executed)
# rig-run build/rig-plan.json --execute        # execute when Rig & LanceDB are available
# rig-run build/rig-plan.json --execute --validate   # execute and verify LanceDB dataset
```

Generate Kùzu node/edge exports:

```nu
use ./kuzu_plan.nu *
kuzu-plan build/nu-ingest/manifest.json --out-dir build/kuzu-plan --out build/kuzu-plan.json
```

Transform the plan into executable Kùzu commands (dry-run by default):

```nu
use ./kuzu_run.nu *
kuzu-run build/kuzu-plan.json --db build/kuzu/db            # dry-run
kuzu-run build/kuzu-plan.json --db build/kuzu/db --validate # dry-run + validation metadata
# kuzu-run build/kuzu-plan.json --db build/kuzu/db --execute        # execute when Kùzu binary is available
# kuzu-run build/kuzu-plan.json --db build/kuzu/db --execute --validate   # execute and verify database presence
```

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
