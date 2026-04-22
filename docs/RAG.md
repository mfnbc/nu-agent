RAG Pipeline Guide
===================

This guide describes the **single supported path** for producing a
deterministic Retrieval-Augmented Generation (RAG) bundle from a Markdown
corpus. The implementation follows a design principle: use Nushell for
structured data orchestration and small Rust binaries (under
`crates/nu_plugin_rag`) for binary-safe, numeric, or performance-sensitive
operations. This keeps parsing, streaming, and object handling in Nushell
while delegating the binary crunching (vector storage, dot-products,
indexing) to Rust.

Overview
--------

Running the pipeline produces:

- `data/nu_docs.msgpack` and `data/nu_docs_vectors.nuon` – canonical chunk
  stores used by the agent runtime.
- `data/command_map.{nuon,msgpack}` – lowercase command → `{ id, display }`
  records consumed by `resolve-command-doc`.
- `build/nu_ingest/embedding_input.{nuon,msgpack,json}` – embedding-input
  tables.
- `<out-dir>/embeddings/corpus.embeddings.msgpack` – deterministic embeddings
  written as MessagePack arrays (when the embedding helper is available).

Quick start (local checkout)
----------------------------

```bash
# 1. Build the Rust helpers (embed_runner + nu-search)
cargo build --manifest-path crates/nu_plugin_rag/Cargo.toml

# 2. Run the ingestion script over Markdown (README shown here)
nu scripts/ingest-docs.nu --path README.md --out-dir build/rag/demo --force

# 3. Optional smoke search
printf '[{"embedding_input":"how to list files"}]' > build/rag/demo/query.embed.nuon
./target/debug/embed_runner --input build/rag/demo/query.embed.nuon --vector-out build/rag/demo/query.msgpack
./target/debug/nu-search --input build/rag/demo/embeddings/corpus.embeddings.msgpack \
  --query-vec build/rag/demo/query.msgpack --top-k 3 --out-format json
```

The ingestion script:

1. Runs `nu-shredder` over every Markdown file under `--path`.
2. Normalises the chunk/command data via `scripts/make-data-from-chunks.nu`.
3. Writes canonical artefacts under `data/` and `build/nu_ingest/`.
4. Copies those artefacts into `--out-dir`.
5. Runs `embed_runner` when it can find the compiled binary.

Git sources / remote docs
-------------------------

To ingest a git repository (e.g., the Nushell docs) without cloning it
nowhere else, use the wrapper:

```bash
nu scripts/prep-nu-rag.nu \
  --input https://github.com/nushell/nushell.github.io.git \
  --out-dir build/rag/nu-docs --force
```

`prep-nu-rag.nu` ensures the Rust helpers exist, clones the repo into
`<out-dir>/sources/<name>/`, and hands control to `scripts/ingest-docs.nu`.
Use `--force` to wipe existing `build/nu_ingest/`/`data/` directories before
the run.

Detailed pipeline
-----------------

The orchestration script is a thin wrapper around the following steps:

1. **Shredding (`nu-shredder`)** – Streams Markdown with `pulldown-cmark` and
   appends deterministic chunk records to `build/nu_ingest/chunks.msgpack` and
   embedding-input records to `build/nu_ingest/embedding_input.msgpack`.
2. **Normalisation (`scripts/make-data-from-chunks.nu`)** –
   - Writes `data/nu_docs.msgpack`, `data/nu_docs_vectors.nuon`, and
     `data/command_map.{nuon,msgpack}`.
   - Emits embedding-input tables in NUON, MsgPack, and JSON (the JSON file is
     what the embedding runner consumes directly).
3. **Embedding (`embed-and-stream.nu` / `embed_runner`)** – The embedding step
   is orchestration-first: Nushell scripts (e.g., `scripts/embed-and-stream.nu`)
   stream embedding inputs to the configured remote provider and write out a
   MessagePack stream of maps as the embeddings become available. For binary
   numeric work (index build / search), the Rust `flat_index` tool in
   `crates/nu_plugin_rag` is used.
4. **Packaging** – Copies all artefacts into the requested `--out-dir` so the
   consumer has an isolated bundle (`chunks/`, `embedding_input/`, `embeddings/`,
   `data/`).

Tool reference
--------------

| Tool / Script | Purpose |
|---------------|---------|
| `nu-shredder` | Rust binary that shreds Markdown into deterministic chunk records. |
| `scripts/ingest-docs.nu` | Preferred entry point; walks a directory, runs the shredder, normalises outputs, writes artefacts, and runs embeddings. |
| `scripts/make-data-from-chunks.nu` | Normalises shredder output; invoked automatically by `ingest-docs`. |
| `scripts/prep-nu-rag.nu` | Helper that builds the Rust binaries (if necessary), clones git sources, and calls `ingest-docs`. |
| `scripts/embed-and-stream.nu` | Nushell streaming embed runner (preferred). |
| `crates/nu_plugin_rag/flat_index` | Rust binary: build/query a flat vector index (binary-safe). |
| `test-ingest.nu` | Smoke test that exercises `scripts/ingest-docs.nu` against `README.md`. |

Artefact layout (`--out-dir`)
-----------------------------

```
<out-dir>/
  chunks/
    corpus.chunks.msgpack
    corpus.chunks.nuon              (present when shredder emits NUON)
  embedding_input/
    corpus.embedding_input.nuon
    corpus.embedding_input.msgpack  (currently a placeholder; use JSON for embeddings)
    corpus.embedding_input.embed.nuon  # JSON ready for embed_runner
  embeddings/
    corpus.embeddings.msgpack       # created when embed_runner is available
  data/
    nu_docs.msgpack
    nu_docs_vectors.nuon
    command_map.nuon
    command_map.msgpack
  sources/                          # only when using prep-nu-rag
    <clone>/ ...
```

Known gaps / TODOs
------------------

- **Manifest & caching** – Runs always shred every Markdown file; emit a
  manifest (chunk count, command coverage, embedding metadata) and skip
  unchanged files via checksums.
- **Embedding input MsgPack** – The generated MessagePack file is a placeholder.
  Either teach `embed_runner` to read NUON directly or emit a proper binary
  representation.
- **Integration tests** – Extend `test-ingest.nu` (or add a new fixture) to
  cover a small multi-file corpus and assert embeddings + search results.
- **Optional adapters** – Graph/LanceDB imports remain external. Document the
  expected artefacts clearly when building an adapter.

See also
--------

- `README.md` – high-level project overview and agent usage.
- `docs/DEVELOPER.md` – notes for contributors (build/test commands).
- `docs/NEXT_SESSION_PROMPT.md` – canonical “resume work” prompt.
