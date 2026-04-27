# Status

Snapshot of nu-agent's implementation state, known warts, and near-term direction.

**Last updated:** 2026-04-27

## Implemented and stable

### Engine

- **`llm.nu`** — thin LLM client. `call-llm-raw $body → string`; `call-llm $messages → string`. Hardcoded endpoint, model, timeout, reasoning suppression. Handles chat, native tool-call, and completion response shapes.
- **`engine.nu`** — `consult contract prompt → prose`. Reads a contract TOML, dispatches by `action.verb` (only `Consult` implemented). When `action.corpus` is declared, runs a retrieval pre-step: embeds the prompt, opens the msgpack corpus, takes top-k via `rag similarity`, injects results as a second system message before the user turn.
- **`mod.nu`** — one-line aggregator: `export use ./engine.nu *`.
- **`nu-agent`** — repo-root CLI. Single mode: `--prompt <string>`, optional `--contract <path>` (defaults to `contracts/architect.toml` resolved relative to the script).

### Contracts

- **`contracts/architect.toml`** — Nushell Data Architect. Domain `nushell+rust`; persona `Data Architect`; action verb `Consult`; `corpus = "data/nu_docs.msgpack"`, `retrieval_k = 5`. System prompt enforces strict-Nushell-and-nu-plugin-Rust discipline, target version 0.111, output format Summary/Code(optional)/Advice.

### RAG plugin (`crates/nu_plugin_rag/`)

- Built against `nu-plugin = "0.111"`. Registered via `plugin add` and `plugin use rag`.
- **Three stateless plugin commands:**
  - **`rag shred`** — text in (pipeline) → chunk records out. Tokenizer-aware via mxbai (currently falling back to char-based — see Known warts). Flags: `--source`, `--max-tokens`, `--overlap-tokens`, `--tokenizer`, `--prepend-passage`.
  - **`rag embed`** — records with text → records with `embedding`. Flags: `--column`, `--mock`, `--url`, `--model`, `--batch-size`. Defaults match LM Studio mxbai-embed-large-v1.
  - **`rag similarity`** — records with `embedding` + `--query <vec>` → top-k records with `score`, sorted desc. Cosine similarity.
- **Two standalone binaries kept** alongside the plugin: `shredder` (CLI scripting fallback) and `embed_runner` (pre-plugin embedder utility).

### Corpus

- **`data/nu_docs.msgpack`** — full Nushell documentation corpus (~4233 chunks from `external/nushell.github.io`). Built via the canonical `ls **/*.md | rag shred | rag embed | save` pipeline. Architect grounding verified end-to-end 2026-04-27.

### Documentation

- `docs/VISION.md` — ecosystem north star.
- `docs/CONTRACTS.md` — two-dimensional contract model (Role × Action-Scope).
- `docs/RAG.md` — retrieval pipeline reference.
- `docs/DEVELOPER.md` — build/run/smoke.
- `docs/ARCHITECTURE.md` — file-level technical layer (currently stale; describes the deprecated 3-adapter shape and needs rewriting).
- `RULES.md` — hard invariants (currently stale; references the deprecated TOOL_NAMES whitelist and Operator-era rules).

## In flight

- **Tokenizer-aware chunking.** Currently falls back to char-based 1800/200 due to a `tokenizers = 0.19` URL parser bug. Fix planned: either bump `tokenizers` to 0.20+ or add a `--tokenizer-path` flag and pre-download `tokenizer.json`. See Known warts.
- **Doc reconciliation.** ARCHITECTURE.md and RULES.md still describe the pre-2026-04-27 architecture (3 contract adapters, tools.nu whitelist, 8-command index plugin). Need to be rewritten to match the engine + 3-command plugin reality.

## Deferred

- **Additional contracts beyond the architect.** The contract-as-data abstraction works; building a second Consult persona (e.g. for a wing) would validate composition. Not blocking.
- **Operator-action contracts.** The architect is Consult-only. `Investigate` (read+query) and `Enact` (read+write) action verbs are designed in CONTRACTS.md but not implemented in the engine. The engine errors on any non-`Consult` verb. Will need RBAC plumbing when revisited.
- **`plugin add` automation.** Currently a one-time manual step. Could be wrapped in a `setup.nu` helper or the README could include a check on missing-plugin error.

## Known warts

**Tokenizer URL bug.** `Tokenizer::from_pretrained` from `tokenizers = 0.19` (with `http` feature) fails with `RelativeUrlWithoutBase` when fetching the mxbai tokenizer from HuggingFace. The shred command catches the error and falls back to char-based chunking. Functional but suboptimal — chunk boundaries aren't token-aware, which can produce chunks that exceed the embedding model's 512-token context (truncated server-side). Fix paths: bump `tokenizers` to 0.20+, or add a `--tokenizer-path` flag and load via `Tokenizer::from_file` from a pre-downloaded `tokenizer.json`.

**Script sprawl in `scripts/`.** The directory mixes ingestion helpers, RAG search scripts, and debug one-offs without organisation. Some files (e.g. `rag-search.nu` invoking `embed_runner --input -`) are non-functional under the current binary contracts. Audit and prune pending.

**`tools/` vs `crates/`.** `tools/` contains standalone Rust source that overlaps with `crates/nu_plugin_rag/src/bin/`. Per-item decision needed: move, promote to sibling crate, or delete.

**Wing-specific artefacts in core.** Hebrew token-seed helpers (`token-seed-input`, `seed-prompt`, `token-seed-schema`) are bible-wing content that bleeds into the core. Should migrate to a separate wing repo per the VISION.md core/wings split.

**Archive detritus.** `archive/external_nushell_repo_backup`, `archive/nu_ingest_rebuild_backup`, and a 34 MB file literally named `-` at the repo root are historical artefacts that should be audited and removed or relocated to a clearly-labelled `legacy/`.

**Root clutter.** Multiple `test-*.nu` files at repo root (`test-enrich.nu`, `test-ingest.nu`, `test-malformed.nu`, `test-schema.nu`, `test-seed-template.nu`) are leftover from the previous architecture. Some import deleted modules and will fail. Should be removed or moved to a `tests/` directory.

## Near-term next steps

1. **Rewrite ARCHITECTURE.md and RULES.md** to match the post-refactor reality (engine + plugin + contracts).
2. **Fix the tokenizer URL bug** — preferred path: `--tokenizer-path` flag + pre-downloaded `tokenizer.json`.
3. **Audit `scripts/` and root `test-*.nu`** — remove cruft, organise survivors.
4. **Build a second contract** to validate the contract-as-data abstraction with more than one persona.
5. **Bible-wing migration.** Extract Hebrew/UXLC artefacts to their own repo.

## See also

- [VISION.md](VISION.md) — the ecosystem goal.
- [CONTRACTS.md](CONTRACTS.md) — the contract model.
- [DEVELOPER.md](DEVELOPER.md) — build/run.
- [RAG.md](RAG.md) — retrieval pipeline.
- [../RULES.md](../RULES.md) — hard invariants.
