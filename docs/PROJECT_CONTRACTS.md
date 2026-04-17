# nu-agent / Nu Docs Retrieval Contracts

This repository is intentionally strict. These contracts are the stable reference for future sessions.

## Core nu-agent contract

- `nu-agent` is a Nushell-only orchestrator, not a general-purpose assistant.
- The model must return JSON array tool calls only.
- Tool calls are executed serially.
- Tools are discovered from the explicit whitelist in `tools.nu` (`TOOL_NAMES`).
- No arbitrary shell execution.
- No external text-processing dependencies in the core agent path.
- Runtime state stays outside the agent core.
- Enrichment mode is single-record only and emits validated JSON on stdout.

## Retrieval / ingestion contract

### Split responsibilities
- Rust performs document shredding / semantic chunking.
- Nushell performs routing, validation, and persistence.
- Vector indexing and graph indexing are downstream consumers.
- Chunk boundaries must not depend on embedding or graph model behavior.
- Retrieval remains deterministic; no LLM-based searching.

### Nu Doc Chunk contract
The Rust splitter emits one JSON object per chunk with the following shape:

- `id`
- `identity`
  - `source`
  - `path`
  - `checksum`
- `hierarchy`
  - `title`
  - `heading_path`
  - `order`
  - `parent_id`
- `taxonomy`
  - `chunk_type`
  - `commands`
  - `tags`
  - `complexity`
- `data`
  - `content`
  - `code_blocks`
  - `links`
- `embedding_input`

### Determinism rules
- Chunk IDs are derived from stable document location and chunk order.
- Checksums are content-based and support incremental rebuilds.
- `embedding_input` is derived from the chunk and may be regenerated.
- Code fences are preserved as explicit code block records.
- Command extraction must be conservative and exact.

## Current ingestion pipeline

1. `nu-shredder` parses Markdown into JSONL chunks.
2. `nu-ingest` validates chunks and writes:
   - `*.chunks.jsonl`
   - `*.embedding_input.jsonl`
   - `manifest.json`
3. `rig_plan.nu` converts ingestion manifests into LanceDB job plans for Rig/FastEmbed.
4. `rig_run.nu` derives deterministic Rig FastEmbed command invocations (dry-run by default, optional execution + LanceDB validation).
5. `kuzu_plan.nu` converts chunk manifests into deterministic node/edge CSV exports for Kùzu ingestion.
6. `kuzu_run.nu` converts node/edge plans into deterministic Kùzu CLI commands (dry-run by default, optional execution + validation).
7. Later layers will add:
   - deterministic vector indexing
   - keyword graph ingestion
   - hybrid retrieval tools for `nu-agent`
   - explicit chunk evidence lookup tools

## Planned retrieval tool layers

- vector search: semantic recall
- keyword graph: exact lookup and neighbor traversal
- reasoning LLM: synthesis from retrieved evidence
- explicit chunk lookup: return matching chunk evidence, not conclusions

## Domain specializations

- Nu docs are one ingestion corpus
- UXLC / Leningrad Codex can be ingested as a separate corpus
- StarLing / Semitic data can be ingested as graph-enriched lexical data
- Kùzu graph topology may represent surface form -> lemma -> root -> cognate relationships

## Golden rule

Retrieval tools must return evidence, not conclusions.
Canonical evidence commands: `search-chunks`, `inspect-chunk`, `search-embedding-input`, `inspect-rig-plan`, `inspect-kuzu-plan`.
