# Next Session Prompt

Copy and paste this into a new session to continue work:

---

You are helping on `nu-agent`, a strict Nushell-only orchestrator.

Important contracts:
- Do not break JSON-only tool call behavior.
- Do not introduce arbitrary shell execution.
- Keep Rust for document shredding / plugins only; keep orchestration in Nushell.
- Keep the retrieval pipeline deterministic and inspectable.
- Chunking must remain independent of embeddings or graph indexing.
- Retrieval tools should return evidence, not conclusions.

Current architecture:
- `mod.nu`: core tool-call validation and execution
- `api.nu`: LLM API wrapper
- `tools.nu`: whitelist + tool implementations
- `shredder/`: Rust `nu-shredder` semantic Markdown splitter
- `nu-ingest.nu` / `nu-ingest`: legacy per-file ingestion script (still available for focused runs)
- `scripts/ingest-docs.nu`: directory walker that runs `nu-shredder`, normalises chunk outputs, and generates embeddings
- `scripts/prep-nu-rag.nu`: convenience wrapper that clones sources (when needed) and delegates to `scripts/ingest-docs.nu`
- Retrieval helpers: `search-chunks`, `inspect-chunk`, `search-embedding-input`, `resolve-command-doc`

Refer to `docs/RAG.md` for the canonical pipeline walkthrough and contributor notes.

Current retrieval contracts:
- `nu-shredder` emits Nu Doc Chunk JSONL
- `nu-ingest` validates and persists chunk and embedding-input outputs
- Nu Doc Chunk fields: `id`, `identity`, `hierarchy`, `taxonomy`, `data`, `embedding_input`
- `embedding_input` is derived
- chunk IDs must be stable
- command extraction must be conservative
- retrieval is deterministic; no LLM-based searching

Current architectural priorities:
- Tier 1: Rig/FastEmbed semantic recall
- Tier 2: Optional structural graph adapters maintained outside this repo
- Tier 3: `nu-agent` synthesis from evidence
- support additional corpora such as UXLC and StarLing as separate ingestion targets

What I likely want next:
- Emit a manifest summarising chunk/command/embedding counts for each ingestion run
- Add caching so unchanged Markdown files are skipped on repeat runs
- Expand integration tests to cover the ingestion + embedding + `nu-search` happy path

Please inspect existing docs first, then implement the smallest deterministic change.
---
