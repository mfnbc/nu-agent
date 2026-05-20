# Status

Snapshot of nu-agent's implementation state and known warts.

**Last updated:** 2026-05-18 (chess coach contract documented, nuchessdb DERIVE phase three-script pipeline verified)

## Implemented

### Engine

- **`llm.nu`** — thin LLM client. `call-llm-raw $body → string`, `call-llm $messages → string`, `call-llm-message $body → record`. Reads chat config (URL, model, timeout) from `config.nu`'s cascade.
- **`engine.nu`** — `run contract prompt` dispatches by `action.verb`:
  - **Enrich** — single-shot JSON fill-in. Engine sends `[system, user]` to the LLM and returns the raw response string (with a small JSON-parse retry/normalisation added in 2026-05). No corpus retrieval, no tool loop. The contract's system prompt declares which fields to fill in; the user message IS the JSON record; the caller parses and validates the response. Designed for structured enrichment pipelines (e.g. adding gloss and cognate data to a Hebrew root registry) where the output must be machine-readable, not prose.
  - **Consult** — single-shot. Engine pre-retrieves top-k chunks from the declared corpus, injects them as a system message, calls the LLM once.
  - **Investigate** — multi-turn tool loop. Engine sends `[system, user] + tools_array` to the LLM, dispatches whatever `tool_calls` come back, appends results as tool messages, repeats until a final answer (or `action.max_iterations` is hit). Tool dispatcher checks the contract's `action.tools` whitelist; current tools: `search_nu_docs` (RAG retrieval), `check_nu_syntax` (parse-check via `nu --ide-check`, output passed verbatim to the LLM), `find_files` (glob within cwd), `read_file` (line-numbered, default 2000-line cap, cwd-scoped). The two filesystem tools enforce a lexical cwd-containment check via `path expand`; paths that escape the working directory are rejected. Calls print to stderr for visibility.
  - **Enact** — same loop as Investigate, but additionally allows the contract to whitelist write-side tools. The `WRITE_TOOLS` constant lists tools that mutate (or propose to mutate) the user's project; `build-tools-array` strips them when verb ≠ Enact, and `dispatch-tool` rejects them with an error message as a backstop. Currently only proposal tools (no direct writes to the path itself). Tools added: `propose_edit(path, old_string, new_string, rationale)` — verifies `old_string` matches exactly once, applies the replacement, writes the result to `<path>.proposed` (the original is untouched); subsequent edits to the same path build cumulatively on `.proposed`. `propose_write(path, content, rationale)` — refuses if `<path>` already exists, writes the proposed content to `<path>.proposed`. Both tools echo a verbose preview to stderr (for the user reading the trace) and return a compact directive message to the LLM ("proposal recorded; do NOT call propose_X again on this path/old_string; next action: write the final answer"). User workflow: open `<path>.proposed` in editor to review; `mv <path>.proposed <path>` to accept, `rm <path>.proposed` to reject, or cherry-pick blocks. `*.proposed` is gitignored.

    **Retry-loop guards** (added 2026-04-30 after observing a small local model loop on identical proposals): (1) `propose_edit` detects when `old_string` is missing but `new_string` is already present in the source — returns `(already applied)` instead of an error so the model breaks out of the retry; (2) `run-investigate` tracks propose successes per-session and, on `max_iterations` exhaustion, returns a graceful summary listing the `.proposed` files written instead of erroring (so the user gets something usable even from a runaway loop); (3) tool-result messages are now compact and directive ("Next action: write the final answer") rather than echoing the full diff back to the LLM.
- **`config.nu`** — four-layer config cascade (env vars > local TOML > XDG TOML > committed TOML > fallback). Relative paths in a config file resolve against that file's directory.
- **`mod.nu`** — re-exports `run` from engine and `get-config` from config.
- **`nu-agent`** — repo-root CLI. `--prompt <string>`, optional `--contract <path>`. Default contract path comes from config.

### Contracts

- **`contracts/architect.toml`** — Nushell Data Architect. Domain `nushell+rust`; persona `Data Architect`; action `Investigate` with `tools = ["search_nu_docs", "check_nu_syntax", "find_files", "read_file"]`, `max_iterations = 10`, `corpus = "data/nu_docs.msgpack"`. System prompt mandates at least one `search_nu_docs` call before answering and a `check_nu_syntax` call on every drafted code block (max 4 retries per block; if still failing, finalise with a help note in Advice). Project-exploration mode (placed before the Workflow in the system prompt) instructs the architect to use `find_files`/`read_file` FIRST when the user asks about their own project/directory rather than a Nu-language question.
- **`contracts/developer.toml`** — Nushell Developer. Domain `nushell+rust`; persona `Nushell Developer`; action `Enact` with `tools = ["search_nu_docs", "check_nu_syntax", "find_files", "read_file", "propose_edit", "propose_write"]`, `max_iterations = 15`, `corpus = "data/nu_docs.msgpack"`. Read-only on the architect's side, write-side via proposals only — does NOT modify disk. System prompt's CRITICAL section establishes the proposal model (echo to stderr + return preview to LLM; user reviews and applies manually); the workflow is locate → verify-via-search → draft → check_nu_syntax until OK → propose with rationale → summarize all proposals in the final answer. Output Format mandates a Proposals bulleted list so the user can apply each deliberately.

### RAG plugin (`crates/nu_plugin_rag/`)

Built against `nu-plugin = "0.111"`. Plugin provides three primary command groups:

- **`rag shred`** — chunk markdown/doc text into tokenizer-aware pieces (tokenizers or char fallback). Use when building a corpus from raw markdown.
- **`rag embed`** — produce embeddings on records' text fields. Supports `--mock` (deterministic local embeddings for offline testing), or a production hosting endpoint via `--url`/`--model` flags. Also supports `--out <ndjson>` for ANN pipelines.
- **`rag similarity`** — exact cosine scoring on in-memory corpora (msgpack). Useful for smaller corpora and rapid experiments.

**ANN / HNSW support (used by consumer projects)**

- Commands: `rag ann-build`, `rag ann-query` (exact persisted binary index), and `rag ann-build-hnsw` / `rag ann-query-hnsw` (HNSW approximate nearest neighbor index).
- Typical flow for large corpora (example: biblexicon): export glosses → `rag embed --out <ndjson>` → `rag ann-build-hnsw` → `rag ann-query-hnsw` → exact rerank using `rag similarity` on top candidates.
- Consumer projects (e.g. biblexicon) orchestrate this flow in `bin/` scripts. nu-agent provides the tools; the domain repo documents the orchestration and provenance steps.

### Corpus

- **`data/nu_docs.msgpack`** — Nushell documentation corpus from `external/nushell.github.io`, English-only (BCP-47 language-tag exclusion regex), token-aware chunked at 480 tokens / 50 overlap. Architect grounding verified end-to-end 2026-04-27.
- **`tokenizers/mxbai.json`** — pre-downloaded mxbai-embed-large-v1 tokenizer JSON.

### Documentation

- `README.md` — quickstart and config.
- `docs/VISION.md` — ecosystem narrative.
- `docs/CONTRACTS.md` — Role × Action-Scope model.
- `docs/STATUS.md` — this file.

## Known warts

**`tokenizers = 0.19` URL parser bug.** `Tokenizer::from_pretrained` can't fetch from HuggingFace (`RelativeUrlWithoutBase`). Workaround in place: `--tokenizer-path` with a pre-downloaded `tokenizer.json`. Future fix: bump `tokenizers` to 0.20+ and the `--tokenizer` HF-name flag becomes usable again.

**`embed-one` previously read config but did not forward flags to the embedding plugin.** This caused some consumer scripts (audit scripts that call `embed-one`) to rely on environment variables (`NU_AGENT_EMBEDDING_URL` / `NU_AGENT_EMBEDDING_MODEL`) rather than `config.toml`. The engine now uses the config-aware `call-llm-embed` path by default; consumer scripts can still call `rag embed --url/--model` directly for fine-grained control or for `--mock` fallbacks.

**Plugin response sometimes leaks gemma reasoning tokens** (`thoughtthought<channel|>` etc.) into `content` instead of `reasoning_content`. Cosmetic; output is still readable but the prefix is noise. Either filter in `llm.nu` post-processing or wait for an LM Studio update.

**Archivability: two corpus formats.** NDJSON is used for ANN pipelines (streamable, appendable) while msgpack is used for in-memory similarity workloads. This dual-format approach is intentional; bridging tools exist in consumer projects (see biblexicon `bin/` scripts).

**Architect occasionally invents flag names** even after retrieving docs. Now mitigated by `check_nu_syntax` (added 2026-04-28) — the architect parses its own code before finalising. Verification of how often this catches errors in practice is pending.

## Deferred

- **Investigate action for personas other than the architect.** Engine supports it; just no other contracts written.
- **Enact action with direct writes.** Today the developer is proposal-only — `propose_edit` and `propose_write` print previews and return them to the LLM but never mutate disk. The user-stated next step is "force a new branch with PRs to main": same tools, but the engine creates a feature branch on entry, real `write_file` / `edit_file` writes happen there, and the LLM-driven session ends by opening a PR. Will need: branch-creation logic, real-write tools, PR-open integration, and a model-tier gate (per `project_persona_model_split.md`) so this doesn't run on a model that hallucinates code.

## See also

- [../README.md](../README.md) — quickstart.
- [VISION.md](VISION.md) — the ecosystem goal.
- [CONTRACTS.md](CONTRACTS.md) — the contract model.
