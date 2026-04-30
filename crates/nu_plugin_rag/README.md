nu_plugin_rag (Rust)
---------------------

A Nushell plugin providing the chunk → embed → search primitives for nu-agent's RAG path. Heavy work (markdown parsing, tokenizer-aware splitting, batched HTTP, cosine scoring) lives in compiled Rust; orchestration and persistence stay in Nushell.

Built against `nu-plugin = "0.111"`.

Build and register
------------------

    cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
    plugin add ./crates/nu_plugin_rag/target/debug/nu_plugin_rag
    plugin use rag

Commands
--------

All three are stateless transforms over Nushell pipeline data — no internal index, no persistence. Persistence is the caller's job (`open` / `save` over msgpack).

- **`rag shred`** — string in → chunk records out.
  Tokenizer-aware splitting via the `tokenizers` + `text-splitter` crates; falls back to char-based 1500/100 if the tokenizer can't load.
  Flags: `--source <path-tag>`, `--max-tokens` (default 480), `--overlap-tokens` (default 50), `--tokenizer-path <local-json>` (preferred), `--tokenizer <hf-name>` (default `mixedbread-ai/mxbai-embed-large-v1`), `--prepend-passage`.
  Output record: `{id, source, title, text, embedding_input}`.

- **`rag embed`** — records with text → records with `embedding`.
  Calls an OpenAI-compatible `/v1/embeddings` endpoint (or computes deterministic mock embeddings).
  Flags: `--column <field>` (default `input`), `--mock`, `--batch-size` (default 16), `--dim` (mock only, default 768), `--url`, `--model`.

- **`rag similarity`** — records with `embedding` + a query vector → top-k records with `score`, sorted desc by cosine.
  Flags: `--query <vec>` (required), `--k` (default 5), `--field` (default `embedding`).

See the repo-root [README](../../README.md) for the full pipeline (`shred | embed | save msgpack` to build a corpus; `open | similarity` to query) and the config cascade that supplies URLs, models, and the tokenizer path.

Known wart
----------

`tokenizers = 0.19` has a URL-parser bug that breaks `Tokenizer::from_pretrained` against HuggingFace (`RelativeUrlWithoutBase`). Workaround: `--tokenizer-path` with a pre-downloaded `tokenizer.json`. Bumping to `tokenizers >= 0.20` should restore `--tokenizer`.
