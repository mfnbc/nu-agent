# nu-agent Architecture

## Overview

`nu-agent` is a deterministic Nushell tool orchestrator. It turns a prompt into a JSON array of tool calls, validates the calls, executes only whitelisted Nushell commands, and returns structured output.

Retrieval is a separate deterministic pipeline:
- Rust shredding
- Nushell ingestion routing
- Rig embeddings
- Optional downstream graph systems (maintained externally)
- `nu-agent` synthesis

## Layers

### 1. LLM API layer (`api.nu`)
- Builds chat requests
- Injects strict no-prose system prompts
- Normalizes model responses

### 2. Agent core modules (`agent/`)
- `runtime.nu` builds tool schemas from live Nushell signatures, validates call JSON, and executes tools serially.
- `schema.nu` inspects command signatures and enforces the whitelist/argument contract derived from `tools.nu`.
- `llm.nu` normalizes JSON-only responses from the LLM API and performs repair prompts when needed.
- `enrichment.nu` validates single-record schemas and orchestrates enrichment retries.
- `json.nu` provides small shared helpers used by the other modules.
- `mod.nu` is now a thin aggregator that re-exports the public surface (`airun`, `run-json`, `enrich`).

### 3. Tool layer (`tools.nu`)
- Whitelisted Nushell commands only
- File operations, syntax checks, self-checks
- Retrieval helpers (optional): `search-chunks`, `inspect-chunk`, `search-embedding-input`, plan inspectors for Rig/LanceDB
- No arbitrary shell execution

### 4. Semantic document shredding (`shredder/`)
- Rust `pulldown-cmark` state machine
- Converts Markdown into Nu Doc Chunk JSONL
- Preserves hierarchy and code blocks

### 5. Nushell ingestion routing (`nu-ingest.nu` / `nu-ingest`)
- Runs the shredder
- Validates chunks
- Writes chunk JSONL, embedding-input jobs, and manifest outputs

### 6. Vector ingestion planning (`rig_plan.nu`)
- Reads ingestion manifest
- Produces LanceDB-ready job plan records for Rig/FastEmbed
- Keeps vector generation deterministic and inspectable

### 7. Vector execution harness (`rig_run.nu`)
- Converts plans into deterministic Rig FastEmbed command invocations
- Supports dry-run inspection and optional execution into LanceDB
- Optional validation step confirms LanceDB dataset presence after successful runs
- Future home for success/error aggregation

### 8. Graph ingestion planning (removed)
- Graph ingestion planning and execution harnesses have been removed from the default repository. If graph exports or database imports are required, implement them as separate adapter projects and invoke them as opt-in steps.

## Design rules

- Deterministic over clever
- Explicit contracts over implicit behavior
- Retrieval should surface evidence, not answers
- Chunking is independent from indexing
- Vector and graph systems are downstream consumers

## Current status

Step 1 is complete:
- semantic Markdown shredding exists
- Nu ingestion routing exists with deterministic chunk + embedding-input exports
- documented contracts exist for future retrieval layers
