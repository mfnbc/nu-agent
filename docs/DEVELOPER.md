# Developer notes

Build, run, and smoke-test the nu-agent core.

**Current state (2026-04-24):** the core (thin client + three contract adapters + Operator runtime) is working and covered by four smoke tests. The RAG retrieval layer is broken at multiple levels — see [STATUS.md](STATUS.md) Known Warts. This document covers what actually runs today.

## Prerequisites

- **Nushell.** The `nu-agent` wrapper's shebang points at `~/.cargo/bin/nu`; any recent Nushell works if invoked via `nu scripts/…`.
- **An OpenAI-compatible LLM endpoint.** The thin client (`llm.nu`) hardcodes `http://172.19.224.1:1234/v1/chat/completions` and a Gemma-family model. To point elsewhere, edit the constants at the top of `llm.nu`. The `NU_AGENT_CHAT_URL` env var is currently a CLI-wrapper guard only; reconciling the two into one config path is future work.
- **For the RAG tooling** (optional, currently partial): Rust toolchain + `cargo`.

## Build the Rust helpers

The nu-agent core is pure Nushell — no build step. The RAG pipeline's Rust components do:

```bash
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
```

Produces `target/debug/embed_runner`, `target/debug/nu-search`, `target/debug/import_nu_docs`, and `target/debug/nu_plugin_rag`. See [RAG.md](RAG.md) for the intended pipeline and [STATUS.md](STATUS.md) for what currently works.

## Run the CLI

`./nu-agent` is the repo-root wrapper over `mod.nu`. Three modes:

```bash
export NU_AGENT_CHAT_URL="http://127.0.0.1:1234/v1/chat/completions"   # any non-empty value works as a guard

# Enrichment — one record in, one validated JSON record out
./nu-agent \
  --task "annotate workout" \
  --record '{"exercise":"squat","reps":5}' \
  --schema '{"allowed":["label","notes"],"required":["label"],"non_null":["label"]}'

# Consultant — role + prompt → prose synthesis over supplied context
./nu-agent \
  --consultant-role "Nutritionist" \
  --consultant-prompt "What patterns do you see in this week's food log: ..."

# Operator — natural-language task → tool calls → executed
./nu-agent --task "list files in the current directory"
```

## Smoke tests

Four scripts under `scripts/` cover the core paths end-to-end. Run from the repo root.

```bash
nu scripts/smoke-call-llm.nu        # thin client: messages → response
nu scripts/smoke-enrich.nu          # Enrichment adapter
nu scripts/smoke-consultant.nu      # Consultant adapter
nu scripts/smoke-operator.nu        # Operator adapter + runtime dispatch end-to-end
```

Each prints its test inputs, the LLM response, and a final `smoke: OK` / `smoke: FAIL` line. Exit status is non-zero on failure. Typical runtime is 5–30 seconds per smoke depending on model latency.

These smokes are the repo's executable documentation — if you change a primitive or adapter, re-run the relevant smoke (and any that might regress across the thin-client boundary).

## Module structure

The public surface is re-exported through `mod.nu`:

- `enrich`, `validate-enrichment-output` (from `agent/enrichment.nu`)
- `consult` (from `agent/consultant.nu`)
- `airun`, `run-json` (from `agent/runtime.nu`)
- Everything exported by `tools.nu` and `seed-template.nu`

Import in your own scripts with `use ./mod.nu *` from the repo root (or the appropriate relative path).

## Adding a new contract adapter

Pattern used by Enrichment, Consultant, and Operator:

1. Create `agent/<adapter>.nu`.
2. Define a `const SYSTEM_PROMPT = "..."` at the top of the file.
3. Write a private `call-<adapter>` function that builds `[{system}, {user}]` messages and dispatches through `call-llm` (or `call-llm-raw` if you need `tools` or other body fields).
4. Add a public entrypoint with flag-based arguments (`--task`, `--prompt`, etc.).
5. Add a `scripts/smoke-<adapter>.nu` that exercises the adapter end-to-end.
6. Export through `mod.nu` if the adapter should be a first-class public command.

Safety rules from [RULES.md](../RULES.md): no bash/curl fallbacks; no external text-processing tools (`jq`, `grep`, `sed`, `awk`, `patch`) in the core path; Rust allowed only as `nu_plugin` extensions.

## See also

- [ARCHITECTURE.md](ARCHITECTURE.md) — how the pieces fit together.
- [CONTRACTS.md](CONTRACTS.md) — contract semantics and system-prompt templates.
- [STATUS.md](STATUS.md) — current state, known warts, deferred work.
- [RAG.md](RAG.md) — retrieval pipeline (currently partially broken).
- [../RULES.md](../RULES.md) — hard invariants.
