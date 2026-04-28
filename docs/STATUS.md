# Status

Snapshot of nu-agent's implementation state and known warts.

**Last updated:** 2026-04-28 (config cascade + cleanup)

## Implemented

### Engine

- **`llm.nu`** — thin LLM client. `call-llm-raw $body → string`, `call-llm $messages → string`, `call-llm-message $body → record`. Reads chat config (URL, model, timeout) from `config.nu`'s cascade.
- **`engine.nu`** — `run contract prompt` dispatches by `action.verb`:
  - **Consult** — single-shot. Engine pre-retrieves top-k chunks from the declared corpus, injects them as a system message, calls the LLM once.
  - **Investigate** — multi-turn tool loop. Engine sends `[system, user] + tools_array` to the LLM, dispatches whatever `tool_calls` come back, appends results as tool messages, repeats until a final answer (or `action.max_iterations` is hit). Tool dispatcher checks the contract's `action.tools` whitelist; current tools: `search_nu_docs`. Calls print to stderr for visibility.
- **`config.nu`** — four-layer config cascade (env vars > local TOML > XDG TOML > committed TOML > fallback). Relative paths in a config file resolve against that file's directory.
- **`mod.nu`** — re-exports `run` from engine and `get-config` from config.
- **`nu-agent`** — repo-root CLI. `--prompt <string>`, optional `--contract <path>`. Default contract path comes from config.

### Contracts

- **`contracts/architect.toml`** — Nushell Data Architect. Domain `nushell+rust`; persona `Data Architect`; action `Investigate` with `tools = ["search_nu_docs"]`, `max_iterations = 5`, `corpus = "data/nu_docs.msgpack"`. System prompt mandates at least one search call before answering.

### RAG plugin (`crates/nu_plugin_rag/`)

Built against `nu-plugin = "0.111"`. Three stateless plugin commands:

- **`rag shred`** — text in (pipeline) → chunk records out. Tokenizer-aware via mxbai (`Tokenizer::from_file` against `--tokenizer-path`); falls back to char-based 1500/100 if the tokenizer can't load. Other flags: `--source`, `--max-tokens`, `--overlap-tokens`, `--prepend-passage`.
- **`rag embed`** — records with text → records with `embedding`. Flags: `--column`, `--mock`, `--url`, `--model`, `--batch-size`. Engine passes config-derived flags explicitly.
- **`rag similarity`** — records with `embedding` + `--query <vec>` → top-k records with `score`, sorted desc by cosine. Flags: `--k`, `--field`.

Two standalone binaries kept alongside: `shredder` (CLI fallback for the chunking logic), `embed_runner` (pre-plugin embedder utility).

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

**Plugin response sometimes leaks gemma reasoning tokens** (`thoughtthought<channel|>` etc.) into `content` instead of `reasoning_content`. Cosmetic; output is still readable but the prefix is noise. Either filter in `llm.nu` post-processing or wait for an LM Studio update.

**Architect occasionally invents flag names** even after retrieving docs (saw `polars sort-by (-descending mean_value)` once where the docs use a different form). Mitigation under consideration: add a second tool (`check_nu_syntax`) so the architect can verify code by parsing it before finalising.

## Deferred

- **Investigate action for personas other than the architect.** Engine supports it; just no other contracts written.
- **Enact action.** Engine errors on `verb = "Enact"` today; needs RBAC plumbing when revisited.
- **`check_nu_syntax` tool.** Mentioned above. Would let the architect iterate on its own code via the parser before claiming a final answer.

## See also

- [../README.md](../README.md) — quickstart.
- [VISION.md](VISION.md) — the ecosystem goal.
- [CONTRACTS.md](CONTRACTS.md) — the contract model.
