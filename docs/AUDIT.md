Audit: repo structure, purpose, and capabilities
=================================================

This audit summarizes the current repository state, evaluates how well the code
and documentation express the intended purpose, and gives focused recommendations
for practical, high-impact improvements. It is intended for maintainers and
contributors to quickly understand the repo health and next steps.

1) High-level purpose alignment
--------------------------------

- The README, PLAN.md, ARCHITECTURE.md, and PROJECT_CONTRACTS.md collectively
  express a clear, consistent intent: a deterministic Nushell-first agent that
  acts via JSON tool calls and a deterministic ingestion pipeline for Nushell
  docs.
- The newly added docs/RAG.md and RULES.md updates bring the RAG goal into the
  same style and constraints: Nushell orchestration + Rust helper binaries.

Recommendation: Keep these documents as the canonical, human-readable contract
for the project. Treat docs/ as the single source of truth.

2) Repo layout & buildability
-----------------------------

- Rust shredder crate: `shredder/` with Cargo.toml and src/ (main.rs, parser.rs,
  types.rs). This crate is functional and compiled in CI.
- New nu_plugin_rag crate: `crates/nu_plugin_rag/` provides a scaffold for the
  RAG plugin and a deterministic embed runner placeholder.
- Nushell scripts live at top-level: `mod.nu`, `tools.nu`, `nu-ingest.nu`, etc.
- Helpers and wrappers added under `scripts/` provide a coherent UX.

Recommendation: Make the workspace Cargo.toml the canonical cargo entry so
developers can `cargo build` across crates. This was added.

3) Determinism & caching
-------------------------

- Deterministic hashing uses `blake3` in Rust (good choice). The embed runner
  placeholder is deterministic and helpful for testing the pipeline without
  heavy model downloads.
- The pipeline plan outlines caching rules; however there is not yet an
  implemented manifest-driven cache invalidation (this is planned in the
  nu_plugin_rag manifest writer).

Recommendation: Implement rag-manifest.json early as the authoritative state
for incremental builds. Use blake3 of sources and intermediate artifacts.

4) Nushell integration & safety
-------------------------------

- Tools are encapsulated as Nushell functions (`tools.nu`) with explicit
  signatures. `mod.nu` builds tool-schema and validates LLM outputs. Good
  defensive design.
- Repair/LLM-retry logic exists but is intentionally conservative.

Recommendation: Expand `self-check` (tools.nu) into an automated preflight for
`rag.build` to avoid executing dangerous commands. Keep `apply-edit` guarded.

5) Embeddings & external dependencies
-------------------------------------

- Current embedding path is a Rust deterministic placeholder. This is a practical
  bootstrap. The plan to support FastEmbed/MixedBread must respect the
  Rust-only constraint: either find a Rust-native implementation or vendor a
  vetted Rust-built binary and verify checksums.

Recommendation: Add `rag.prepare-deps` to fetch prebuilt Rust FastEmbed and
model artifacts into a cache dir and avoid any runtime execution unless user
explicitly runs the prep step.

6) Kùzu & Rig handling
----------------------

- The repo emits plan files and expects Kùzu import and LanceDB population to be
  opt-in. This is correct for safe, auditable behavior. Use CSVs as canonical
  exports for Kùzu.

Recommendation: Emit kuzu-plan.json with CSV paths, header schema, and a small
  `scripts/kuzu-import.nu` utility (added) for opt-in imports.

7) Tests & CI
-------------

- Added a focused Rust CI workflow that runs unit tests for shredder and the
  new plugin crate. This is sufficient for now but expand to integration steps
  when embeddings and orchestration are implemented.

Recommendation: Add an integration test that runs `rag.build` on the small
example corpus using the deterministic embed runner.

8) Next developer tasks (prioritized)
-------------------------------------

1. Implement rag-manifest.json writer and use it for cache decisions.
2. Implement rag.prepare-deps to download and verify vetted Rust helper
   binaries + model artifacts.
3. Replace deterministic embed runner with a connector to a vetted Rust FastEmbed
   binary or a Rust-native embedding crate.
4. Implement the full rag.build orchestrator in nu_plugin_rag, honoring caching
   and writing manifest.
5. Add an integration test that runs the full pipeline on examples/ (deterministic mode).
