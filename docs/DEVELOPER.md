Developer notes: build, run, test
================================

Quickstart (local)
-------------------

1. Build the Rust workspace (produces `target/debug/embed_runner` and `target/debug/nu-search`):

   cargo build --workspace

2. Run unit tests for the plugin crate:

   cargo test --manifest-path crates/nu_plugin_rag/Cargo.toml

3. Run the deterministic embedding runner on the example input:

   ./target/debug/embed_runner --input examples/embedding_input_example.msgpack --output build/embeddings_example.msgpack

4. Use the ingestion script to build a RAG bundle (see `docs/RAG.md` for details):

   nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force
   # or: nu scripts/prep-nu-rag.nu --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs --force

Quick Start (concise)
---------------------

1) Build the helper binaries:

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

2) Shred & ingest Markdown:

   nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/readme --force

3) Generate a query vector and run a search:

   printf '[{"embedding_input":"how to list files"}]' > build/rag/readme/query.embed.nuon
   ./target/debug/embed_runner --input build/rag/readme/query.embed.nuon --vector-out build/rag/readme/query.msgpack
    ./target/debug/nu-search --input build/rag/readme/embeddings/corpus.embeddings.msgpack --query-vec build/rag/readme/query.msgpack --top-k 3 --out-format json


Notes about nu_plugin integration
--------------------------------

- The plugin crate currently exposes binaries (`embed_runner`, `nu-search`) consumed by the Nushell scripts.
 - The plugin crate currently exposes binaries (`embed_runner`, `nu-search`, `import_nu_docs`, `shredder`) consumed by the Nushell scripts.
- Converting the ingestion pipeline into a first-class `nu_plugin` remains future work once the scripts stabilise.

Where to extend
---------------

- Emit a manifest during ingestion (chunk counts, command coverage, embedding metadata).
- Add checksum-based caching so reruns skip unchanged Markdown files.
- Package the ingestion pipeline as an optional `nu_plugin` when ready.
- Replace the placeholder deterministic embeddings with a vetted FastEmbed path once the dependency story is locked.

Importer notes
 - The `import_nu_docs` binary performs resumable ingestion with a partial
   checkpoint at /tmp/partial_nu_wiki.msgpack and writes the final index to
   ./data/nu_wiki.msgpack. It embeds in batches of 64 and flushes the partial
   checkpoint every 500 chunks by default. Environment variables control the
   embedding and chat endpoints (EMBEDDING_REMOTE_URL, EMBEDDING_MODEL,
   NU_AGENT_CHAT_URL, NU_AGENT_MODEL).

Shredder tokens
 - The shredder binary defaults were adjusted to favor tokenizer-aware splitting
   for Mixedbread (`mixedbread-ai/mxbai-embed-large-v1`) with max_tokens=480 and
   overlap_tokens=50 to avoid exceeding 512 token limits when using that model.
