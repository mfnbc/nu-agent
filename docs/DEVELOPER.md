Developer notes: build, run, test
================================

Quickstart (local)
-------------------

1. Build Rust crates (workspace):

   cargo build --workspace

2. Run unit tests for the plugin crate:

   cargo test --manifest-path crates/nu_plugin_rag/Cargo.toml

3. Run the deterministic embedding runner on the example input:

   ./crates/nu_plugin_rag/target/debug/embed_runner --input examples/embedding_input_example.jsonl --output build/embeddings_example.jsonl --dim 16

4. Use the Nushell helper scripts to run the prep/build steps (requires `nu`):

   nu scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs

Quick Start (concise)
---------------------

1) Build and run CLI orchestrator (no Nushell):

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml
   ./crates/nu_plugin_rag/target/debug/nu_plugin_rag build --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs

2) Test deterministic embedding runner:

   ./crates/nu_plugin_rag/target/debug/embed_runner --input examples/embedding_input_example.jsonl --output build/embeddings_example.jsonl --dim 16

3) Nushell interactive path (preferred for Nushell users):

   nu scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs


Notes about nu_plugin integration
--------------------------------

- The current nu_plugin exposure is a CLI stub in `crates/nu_plugin_rag/src/bin/nu_plugin_rag.rs`.
- `scripts/rag.shim.nu` provides Nushell functions that call the binary for local development.
- Converting the CLI into a real nu_plugin involves implementing the nu_plugin ABI and exporting
  Nushell commands directly; that work is planned after the orchestrator and embedding runner are
  stabilized.

Where to extend
---------------

- Add the manifest writer in `crates/nu_plugin_rag/src/manifest.rs` and call it from the build
  orchestrator.
- Implement actual dependency preparation in `crates/nu_plugin_rag/src/prepare_deps.rs`.
- Replace the placeholder deterministic embeddings with a real embedding path in `crates/nu_plugin_rag/src/embeddings.rs`.
