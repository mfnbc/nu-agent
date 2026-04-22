Edifice: RAG Pipeline (concise)
================================

This repository's RAG tooling now centers on a single, Nushell-first edifice:

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

Testing
-------

- scripts/test-integrity.nu performs a smoke round-trip test (save → remove → load → search).
- crates/nu_plugin_rag/src/bin/integrity_test.rs provides a programmatic round-trip check.

See also: README.md and crates/nu_plugin_rag/README.md for command reference and examples.
