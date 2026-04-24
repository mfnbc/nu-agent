Edifice: RAG Pipeline (concise)
================================

> **Current state (2026-04-24):** the retrieval layer is broken at multiple levels — orphaned `nu-search` binary, incompatible corpus formats on disk, `nu_plugin_rag` plugin rejects the `--stdio` handshake during `plugin add`. See [STATUS.md](STATUS.md) Known Warts for specifics. The pipeline described below is the **intended** shape; repairing it is a deferred milestone.

This repository's RAG tooling is designed as a single, Nushell-first edifice:

- Lightweight Rust helpers for numeric work live in crates/nu_plugin_rag.
- A repo-local Nushell plugin (nu_plugin_rag) exposes in-shell RAG commands
  so you can ingest, search, persist, and manage indexes directly from Nushell.

Final Blueprint
---------------

- Ingest: rag shred | rag embed | rag index-add
- Search: rag index-search --with-doc -f <field> [--k N]
- Persist: rag index-save <name> --path <file>; rag index-load <name> --path <file>
- Manage: rag index-list; rag index-remove <name>

Quick start (build + register plugin)
------------------------------------

1. Build the plugin:

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

2. Register the plugin in Nushell (one-time):

   plugin add nu_plugin_rag "/absolute/path/to/target/debug/nu_plugin_rag"

3. Use the commands directly in Nushell. Example: create and save an index:

   [ { id: "a", text: "alpha beta" }, { id: "b", text: "beta yellow" } ] \
   | rag embed --mock --column text \
   | rag index-create demo_index \
   | rag index-add demo_index

   rag index-save demo_index --path /tmp/demo.msgpack

Notes and caveats
-----------------

- The plugin must be invoked by Nushell with the plugin loader flags (e.g. `--stdio`).
  The compiled binary now scans for `--stdio` and `--local-socket` early to ensure
  it doesn't reject the plugin handshake.
- Saved index files use MessagePack and include nu_protocol::Value data. These are
  compact and fast to load but are tied to Nushell's Value representation; for
  archive portability consider adding an `index-export --format json` command.
- `rag index-add` performs batched inserts (default batch-size=100) to reduce Mutex
  contention during mass ingestion. Use `--quiet` to suppress progress messages.

- Import helper: the repository includes a helper binary `import_nu_docs` that
  performs progressive ingestion, batching, and checkpointing. Build and run:

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
   ./target/debug/import_nu_docs

  Defaults used by `import_nu_docs` (can be overridden via env vars):
   - EMBEDDING_REMOTE_URL default: http://172.19.224.1:1234/v1/embeddings
   - EMBEDDING_MODEL default: text-embedding-mxbai-embed-large-v1
   - Partial checkpoint: /tmp/partial_nu_wiki.msgpack (flushed every 500 chunks)
   - Final index output: ./data/nu_wiki.msgpack
   - Embed batch size: 64
   - Shredder/tokenizer: controlled with SHREDDER_TOKENIZER (defaults to mixedbread tokenizer in shredder)

Testing
-------

- scripts/test-integrity.nu performs a smoke round-trip test (save → remove → load → search).
- crates/nu_plugin_rag/src/bin/integrity_test.rs provides a programmatic round-trip check.

See also: README.md and crates/nu_plugin_rag/README.md for command reference and examples.
