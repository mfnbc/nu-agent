# Nu-Agent Architectural Manifest

## 1. Core Philosophy

### The Covenant of Purity
- Retrieval is deterministic only.
- No LLM-based searching.
- LLMs are for synthesis, not discovery.

### Stack
- Rust: performance and parsing/shredding
- Nushell: routing, validation, and pipeline control
 - Rig: local embeddings were previously implemented with `rig-fastembed`; this repository now uses a remote embedding service by default
- External adapters: optional structural/graph retrieval maintained outside this repository

### Execution model
- One local binary family
- Local-first
- Zero API dependency for retrieval

## 2. The 3-Tier Retrieval Engine

### Tier 1: Semantic
 - Remote embedding service (configurable via EMBEDDING_REMOTE_URL and EMBEDDING_MODEL)
- Fuzzy topical recall from Nu documentation and other corpora

### Tier 2: Structural (external adapter)
- Optional graph or relational stores maintained outside this repository
- Exact command signatures
- Hierarchy
- Linguistic cognate trees / Semitic relations

### Tier 3: Reasoning
- `nu-agent` synthesizes evidence into code or structured actions
- Reasoning consumes evidence from tiers 1 and 2

## 3. Ingestion Pipeline

### Status
- Rust shredder binary is implemented
- Nushell ingestion script is implemented

### Input corpora
- Markdown: Nu Book / Cookbook
- UXLC: Leningrad Codex, NFC-normalized
- StarLing: Semitic `.dbf` sources

### Output
- Nu Doc Chunk JSONL
- Embedding-input JSONL jobs for Rig/FastEmbed -> LanceDB
- Stable chunk IDs derived from path + heading path + order
- Command tokens extracted from backticks and code fences

## 4. Linguistic Specialization

### Data
- UXLC (normalized)
- StarLing PAA / Semitic etymology data

### Goal
- Use structured graph/topology (when available) to resolve contradictions in rough notes
- Traverse linkage such as:
  - Surface Form -> Lemma -> Root -> Cognates

## 5. Current Task

- Active: LanceDB execution harness (`rig_plan.nu` + `rig_run.nu`). Graph planning/execution harnesses are intentionally external.
- Next: add validation checks around generated artifacts once external graph adapters exist.
- Next: hydrate LanceDB tables with actual vectors and expose retrieval tools over the merged stores
- Retrieval helpers now available: chunk inspection and Rig plan inspectors
