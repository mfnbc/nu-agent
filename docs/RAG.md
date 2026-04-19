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
- Offer a single `rag.build` workflow that performs: clone -> shred -> ingest -> embed
  -> rig plan -> optional rig run -> kuzu CSV export -> manifest.
- Default to producing auditable artifacts (chunks JSONL, embedding inputs, embeddings,
  Rig plan, Kùzu CSVs). Importing into Kùzu or populating a LanceDB is opt-in.
- Remain extensible to additional corpora (StarLing, chess, etc.) via source adapters.

User-facing commands (nu_plugin_rag)
----------------------------------

- rag.prepare-deps [--out-dir <dir>] [--model mixedbread]
  - Downloads verified model files and Rust-built helper binaries (if required).
  - Writes paths and checksums into the local cache and prints a JSON manifest.

- rag.build --input <path-or-git-url> --out-dir <dir> [--attach-code-blocks] [--emb-provider local-fastembed] [--force] [--execute-rig false] [--execute-kuzu false]
  - Full pipeline orchestration. Produces the artifact layout under <out-dir>.
  - By default, does not execute rig_run or kuzu import; use flags to opt in.

- rag.status --out-dir <dir>
  - Validate presence and checksums of artifacts and report a structured status.

- rag.rebuild --parts <shred|ingest|embed|rig|kuzu> --input --out-dir
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
- chunks/*.chunks.jsonl
- embedding_input/*.embedding_input.nuon (preferred) and embeddings/*.embeddings.msgpack for embeddings
- embeddings/*.embeddings.jsonl (fallback)
- rig/rig-plan.json
- rig/lancedb/ (if executed)
- kuzu/nodes.csv
- kuzu/edges.csv
- rag-manifest.json

Kùzu import policy
------------------

The pipeline emits node and edge CSVs suitable for Kùzu import. CSVs are the
portable, auditable artifacts; importing into a local Kùzu instance (which creates
binary DB files) is optional and must be explicitly requested using
`--execute-kuzu` or the `rag.import-kuzu`/`scripts/kuzu-import.nu` helper.

Caching & idempotency
---------------------

- Use blake3 checksums of source files, chunk outputs, and embedding inputs to
  determine whether a step can be skipped.
- Embeddings are keyed by embedding_input checksums; existing embeddings are reused
  unless `--force` is specified.
- rig_run and kuzu import are opt-in and will be skipped unless requested.

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
  or a vetted Rust binary distribution if a native crate is not available.
- See `scripts/prep-nu-rag.nu` for a convenience Nushell wrapper that calls the
  prepare and build steps.
