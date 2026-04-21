RAG Pipeline (nu_plugin_rag)
=================================

Overview
--------

This document describes the Nushell-first Retrieval-Augmented Generation (RAG)
preparation pipeline planned for this repository. The implementation is Rust + Nushell
only: the orchestration and lightweight shims are Nushell scripts; heavy work and
model/runtime tools are Rust binaries or downloaded Rust-built artifacts. No Python
or other languages are required.

Goals
-----

- Provide an idempotent `prep` step that downloads and verifies required artifacts
  (models, helper binaries) into a configurable cache directory.
 - Offer a single `rag.build` workflow that performs: clone -> shred -> ingest -> embed -> rig plan -> optional rig run -> manifest.
- Default to producing auditable artifacts (chunks JSONL, embedding inputs, embeddings,
  Rig plan, Kùzu CSVs). Importing into Kùzu or populating a LanceDB is opt-in.
- Remain extensible to additional corpora (StarLing, chess, etc.) via source adapters.

User-facing commands (nu_plugin_rag)
----------------------------------

- rag.prepare-deps [--out-dir <dir>] [--model mixedbread]
  - Downloads verified model files and Rust-built helper binaries (if required).
  - Writes paths and checksums into the local cache and prints a JSON manifest.

 - rag.build --input <path-or-git-url> --out-dir <dir> [--attach-code-blocks] [--emb-provider local-fastembed] [--force] [--execute-rig false]
  - Full pipeline orchestration. Produces the artifact layout under <out-dir>.
  - By default, does not execute rig_run; graph DB import tools (Kùzu/LanceDB) are opt-in and external adapters.

- rag.status --out-dir <dir>
  - Validate presence and checksums of artifacts and report a structured status.

 - rag.rebuild --parts <shred|ingest|embed|rig> --input --out-dir
  - Partial rebuild of specified pipeline stages.

Preferred artifact formats
-------------------------

For Nushell-native tooling we prefer NUON (Nushell Object Notation) or MessagePack
for persisted corpus artifacts. These formats preserve structured types, are
efficient to parse from Nushell, and avoid brittle newline-delimited JSON parsing.

Special cases: when a database binary is the most appropriate backing store
(for example `sqlite` files, LanceDB/Parquet-backed indexes, or other local DB
engines like SurrealDB), treat those as optional, opt-in artifacts. Importing
into a binary database is allowed only when the import can be performed as a
one-off command (e.g., a single sqlite3 invocation that loads a CSV or executes
an import SQL script). This keeps the pipeline reproducible and avoids long-
running services during ingestion. The pipeline will emit portable intermediary
artifacts (NUON/MsgPack/CSV) that can be imported into these databases when the
user explicitly requests it.

Artifact layout
---------------

Default structure under <out-dir>:

- sources/<name>/ (git clone or local path)
 - chunks/*.chunks.nuon
- embedding_input/*.embedding_input.nuon (preferred) and embeddings/*.embeddings.msgpack for embeddings
 - embeddings/*.embeddings.msgpack (fallback)
- rig/rig-plan.json
- rig/lancedb/ (if executed)
  (Kùzu CSV exports removed from default flow; implement outside this repo if needed.)
- rag-manifest.json

Kùzu import policy
------------------

The pipeline emits node and edge CSVs suitable for Kùzu import. CSVs are the
portable, auditable artifacts; importing into a local Kùzu instance (which creates
binary DB files) is optional and must be explicitly requested using
 Graph DB imports (Kùzu/LanceDB) are considered external adapters and are not part of the default pipeline.

Caching & idempotency
---------------------

- Use blake3 checksums of source files, chunk outputs, and embedding inputs to
  determine whether a step can be skipped.
- Embeddings are keyed by embedding_input checksums; existing embeddings are reused
  unless `--force` is specified.
 - rig_run is opt-in and will be skipped unless requested. Graph DB imports are external.

Security & downloads
--------------------

- All downloads must use HTTPS and are verified against expected blake3/sha256 sums.
- The `rag.prepare-deps` step performs downloads only when explicitly invoked by the
  user.

Extensibility
-------------

Source adapters can be added as Rust modules that convert domain-specific inputs
(StarLing export, PGN chess collections) into Markdown or directly into chunk JSONL
and embedding inputs. Adapters are small Rust binaries or library modules that
conform to the SourceProvider interface.

Developer notes
---------------

- The plugin is expected to live in `crates/nu_plugin_rag` and expose Nushell commands
  via the `nu_plugin` crate.
- The embedding runner is Rust-only; it will attempt to use a Rust-native FastEmbed
 - The embedding runner is Rust-only; it will attempt to use a Rust-native FastEmbed
  or a vetted Rust binary distribution if a native crate is not available.
- The embed_runner binary writes two kinds of outputs:
  - Full document embeddings: a MessagePack array of DocRecord objects written with --output (each record contains id, text, embedding, metadata).
  - Query vector: a MessagePack array of f32 written with --vector-out (useful for passing to nu-search or other consumers that expect a single vector).

Minimal Example
---------------

Quick, copy-paste example that runs the minimal three-step flow locally (build -> embed docs -> generate query vector -> search):

1. Build the plugin binaries:

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

2. Produce document embeddings (full DocRecord MessagePack array):

   ./crates/nu_plugin_rag/target/debug/embed_runner --input examples/embedding_input_example.nuon --output build/embeddings.msgpack

3. Produce a query vector (raw MessagePack array of f32):

   printf '[{"embedding_input":"how to filter tables"}]' > build/query.nuon
   cat build/query.nuon | ./crates/nu_plugin_rag/target/debug/embed_runner --input - --vector-out build/query.msgpack

4. Run nu-search against the produced artifacts:

   ./crates/nu_plugin_rag/target/debug/nu-search --input build/embeddings.msgpack --query-vec build/query.msgpack --top-k 3 --out-format json

This produces a JSON array of top-k hits. Use --out-format nuon or msgpack if you prefer those formats.

Using Nu Documentation
-----------------------

The primary corpus we target is the Nushell documentation (the `nushell.github.io` site). You can point the build command at the repo URL and the plugin will clone it, shred Markdown files, generate embedding inputs, and attempt to run the embedding step when possible.

1. Build the plugin binaries:

   cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

2. Run the build step against the nushell docs repository (the CLI will clone the repo):

   ./crates/nu_plugin_rag/target/debug/nu_plugin_rag build --input https://github.com/nushell/nushell.github.io.git --out-dir build/rag/nu-docs

   This will create `build/rag/nu-docs/sources/<repo>` and emit `chunks/`, `embedding_input/`, and `*.embeddings.msgpack` files under the out-dir when possible.

3. If the embedding step did not run automatically (for example `embed_runner` not found), run it over the generated embedding inputs:

   for f in build/rag/nu-docs/embedding_input/*.embedding_input.nuon; do
     out=build/rag/nu-docs/embeddings/$(basename "$f" .embedding_input.nuon).embeddings.msgpack
     ./crates/nu_plugin_rag/target/debug/embed_runner --input "$f" --output "$out"
   done

4. Produce a query vector and run nu-search as in the Minimal Example above, pointing `--input` at the produced embeddings file and `--query-vec` at the query MessagePack file.

This workflow gives nu-agent access to the canonical Nushell docs so it can produce idiomatic Nushell suggestions and code. You can run the same pipeline against a local clone by passing a filesystem path instead of a git URL to `--input`.
- See `scripts/prep-nu-rag.nu` for a convenience Nushell wrapper that calls the
  prepare and build steps.
