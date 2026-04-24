# Status

Snapshot of nu-agent's implementation state, known warts, and near-term direction.

**Last updated:** 2026-04-24

## Implemented and stable

### Core primitives (post-refactor)

- **`llm.nu`** — thin LLM client. `call-llm-raw $body → string` is the primitive; `call-llm $messages → string` is the common-case wrapper. Hardcoded endpoint, model, timeout, reasoning suppression. Handles chat-style, completion-style, and native tool-call response shapes.
- **`agent/enrichment.nu`** — Enrichment adapter. `enrich --task --record --schema [--validate-only]` + `validate-enrichment-output`. Single-record JSON in/out, schema-enforced.
- **`agent/consultant.nu`** — Consultant adapter. `consult --role --prompt → prose`. Role defaults to "Consultant"; wings override with domain roles.
- **`agent/operator.nu`** — Operator adapter. `call-operator $task $tools → parsed JSON calls` + `parse-json-calls-safe`. Pattern-A tool-call whitelist preserved.
- **`agent/runtime.nu`** — Operator orchestration. `airun --task` and `run-json --calls` build the tool schema, dispatch Operator, validate, execute serially.
- **`agent/schema.nu`** — tool-schema building, whitelist enforcement, argument validation.
- **`agent/json.nu`** — shared JSON coercion helper.
- **`mod.nu`** — module aggregator. Re-exports `enrich`, `consult`, `airun`, `run-json`, `validate-enrichment-output`, plus `tools.nu` and `seed-template.nu`.
- **`nu-agent`** — CLI wrapper over `mod.nu` supporting enrichment (`--task --record --schema`), consultant (`--consultant-role --consultant-prompt`), and general tool-calling (`--task`) modes.

### Tools

- **`tools.nu`** — canonical whitelist (`TOOL_NAMES`) plus the `TOOL_REGISTRY` metadata single source.
- Core tool implementations: `read-file`, `write-file`, `list-files`, `search`, `replace-in-file`, `propose-edit`, `apply-edit`, `check-nu-syntax`, `self-check`.
- Developer-contract retrieval helpers: `search-chunks`, `inspect-chunk`, `search-embedding-input`, `resolve-command-doc`, `search-nu-concepts`.

### CLI entrypoint

- **`./nu-agent`** — repo-local wrapper. Enrichment and general tool-call entry. Requires `NU_AGENT_CHAT_URL`; accepts `NU_AGENT_MODEL` and `NU_AGENT_API_KEY` overrides.

### RAG pipeline (partial — retrieval layer is broken; see Deferred + Known warts)

- **`shredder/`** — Rust `pulldown-cmark` semantic Markdown splitter producing Nu Doc Chunk JSONL. Independent binary, builds and runs.
- **`target/debug/embed_runner`** — produces query and corpus embeddings against a remote embedding endpoint. Confirmed working (2026-04-24): takes `--input <path>` (nuon list of `{embedding_input: "..."}`), writes a raw MessagePack vector to `--vector-out`.
- **`target/debug/import_nu_docs`** — ingests Markdown into `data/nu_wiki.msgpack`.
- **`scripts/ingest-docs.nu`** / **`scripts/prep-nu-rag.nu`** — ingestion orchestration. Not re-verified this session.

### Smoke tests

- **`scripts/smoke-call-llm.nu`** — thin client end-to-end.
- **`scripts/smoke-enrich.nu`** — Enrichment adapter.
- **`scripts/smoke-consultant.nu`** — Consultant adapter.
- **`scripts/smoke-operator.nu`** — Operator adapter + runtime dispatch.

### Documentation

- **`docs/VISION.md`** — ecosystem north star.
- **`docs/CONTRACTS.md`** — contract model and catalogue.
- **`docs/ARCHITECTURE.md`** — technical layers.
- **`docs/RAG.md`** — RAG pipeline walkthrough.
- **`docs/DEVELOPER.md`** — build/run/test.
- **`RULES.md`** — hard invariants.

## In flight

- **Ingestion manifest** — blake3 source checksums, chunk/command/embedding counts per run. Not yet implemented (practical once the RAG backend is repaired).
- **Incremental cache** — unchanged Markdown files should be skippable on repeat ingestion runs. Not yet wired (practical once the RAG backend is repaired).

## Deferred

- **RAG end-to-end smoke test.** Proving `query → retrieved context → LLM → grounded answer` is blocked on choosing and repairing a retrieval backend. Three paths were considered on 2026-04-24: (a) re-source or rebuild `nu-search` (source removed from tree), (b) repair the `nu_plugin_rag` plugin's `--stdio` handshake and use `rag index-search`, (c) implement similarity in pure Nushell against a rehydrated corpus. The user indicated cosine similarity belongs in Rust (plugin), so (b) is the preferred long-term path. Drafted `rag-prompt.nu` + `scripts/smoke-rag.nu` during investigation and removed them pending a deliberate backend choice. Revisit after the contract-adapter migration stabilises the core.
- **Operator pattern shift (major milestone, post-RAG).** Switch Operator from pattern-A (tool-call whitelist against `TOOL_NAMES`) to pattern-B (Nushell command strings executed in a sandboxed `nu` session). Rationale: hybrid tool+escape-hatch designs degrade into the escape hatch (the "bash-escape-hatch" argument); the right long-term shape is `nu` as the sole tool, with per-role/per-corpus RBAC enforced at the sandbox boundary. Prerequisite: RAG must be functional so the Operator can retrieve Nushell syntax at query time instead of relying on base-model fluency. In the meantime, the adapter migration preserves pattern A semantics.

## Known warts

**RAG retrieval layer is broken at three levels** (discovered 2026-04-24):

- `target/debug/nu-search` — the binary exists but its Rust source has been removed from the tree. Its expected corpus format (`[{id, embedding, value}, ...]` at top level) does not match either msgpack on disk.
- `data/nu_docs.msgpack` contains text records (`path`, `id`, `title`, `heading_path`, `text`, `taxonomy`) with **no embeddings**. `data/nu_wiki.msgpack` contains embeddings but in the `nu_plugin_rag` wrapped format (`{dimension, docs: [{id, vector, value}]}`), which neither `nu-search` nor any registered plugin can consume right now.
- `nu_plugin_rag` binary rejects the Nushell plugin `--stdio` handshake — its CLI parser expects a `<COMMAND>` subcommand and errors with `unexpected argument '--stdio'`. `docs/RAG.md` claims this was previously fixed but the current build regresses. Blocks `plugin add`.
- `scripts/rag-search.nu` (inherited) invokes `embed_runner --input -` (stdin), which the current binary rejects — it requires a file path. The script is therefore non-functional.

**Script sprawl in `scripts/`.** The directory mixes at least three kinds of work without organisation:

- Core ingestion helpers (`ingest-docs.nu`, `prep-nu-rag.nu`, `make-data-from-chunks.nu`).
- RAG search and tests (`rag-search.nu`, `smoke-test.nu`, `smoke-tokenize-and-dryrun.nu`, `test-pipeline.nu`, `test-edifice.nu`, `test-integrity.nu`).
- Debug one-offs (`_debug_post_chat.nu`, `run_airun.nu`, `build_body.nu`, `make_record.nu`).

The overlap between `embed-and-stream.nu` and `embed-stream.nu` suggests a copy that was never reconciled.

**`tools/` vs `crates/`.** `tools/` contains standalone Rust source (`hydrate_hits.rs`, `inspect_chunks/`, `flat_index/`, `make_golden/`, `nu_embedder/`, `agent_bridge/`). Some of this likely belongs under `crates/nu_plugin_rag/src/bin/` or a sibling crate; some may be abandoned experiments. Needs a per-item decision: keep / move / delete.

**Wing-specific artefacts in the core repo.** Hebrew token-seed helpers (`token-seed-input`, `seed-prompt`, `token-seed-schema`) are referenced in `README.md` and surface as a bible wing bleeding through into the core. These should eventually migrate to their own wing repository (see [VISION.md](VISION.md) on the core/wings split).

**Archive detritus.** `archive/external_nushell_repo_backup`, `archive/nu_ingest_rebuild_backup`, and a 34 MB file literally named `-` in the repo root are historical artefacts that should be audited and either removed or moved to a clearly-labelled `legacy/`.

**Root clutter.** Multiple `test-*.nu` files at the repo root (`test-enrich.nu`, `test-ingest.nu`, `test-malformed.nu`, `test-schema.nu`, `test-seed-template.nu`) would be easier to find and maintain under a single `tests/` directory.

## Near-term next steps

1. **Audit `scripts/`.** Split into something like `scripts/core/`, `scripts/tests/`; remove debug one-offs and duplicates.
2. **Audit `tools/`.** Per item: move into `crates/nu_plugin_rag/src/bin/`, promote to a sibling crate, or delete.
3. **Archive and root cleanup.** Remove `archive/` backups, the 34 MB `-` file at the root, and migrate `test-*.nu` to `tests/`.
4. **RAG backend repair.** Unblocks the deferred end-to-end smoke, the ingestion manifest, and the Operator pattern-B shift. Preferred path: repair the plugin's `--stdio` handshake and migrate retrieval to `rag index-search`. Cosine similarity stays in Rust.
5. **Bible-wing migration.** Identify Hebrew/UXLC-specific artefacts and plan their extraction into their own wing repository.

## See also

- [VISION.md](VISION.md) — the ecosystem goal.
- [CONTRACTS.md](CONTRACTS.md) — the contract model.
- [ARCHITECTURE.md](ARCHITECTURE.md) — where each piece lives in code.
- [../RULES.md](../RULES.md) — hard invariants.
