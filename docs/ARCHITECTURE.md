# nu-agent Architecture

## Overview

`nu-agent` is a deterministic Nushell tool orchestrator. It turns a prompt into a JSON array of tool calls, validates the calls, executes only whitelisted Nushell commands, and returns structured output.

Retrieval is a separate deterministic pipeline:
- Rust shredding
- Nushell ingestion routing
- Rig embeddings
- Kùzu graph retrieval
- `nu-agent` synthesis

## Layers

### 1. LLM API layer (`api.nu`)
- Builds chat requests
- Injects strict no-prose system prompts
- Normalizes model responses

### 2. Core orchestration layer (`mod.nu`)
- Builds tool schemas from Nushell signatures
- Validates tool call JSON
- Executes tool calls serially
- Handles enrichment validation and repair

### 3. Tool layer (`tools.nu`)
- Whitelisted Nushell commands only
- File operations, syntax checks, self-checks
- Retrieval helpers: `search-chunks`, `inspect-chunk`, `search-embedding-input`, plan inspectors for Rig/LanceDB + Kùzu
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

### 8. Graph ingestion planning (`kuzu_plan.nu`)
- Reads chunk manifests and prepares Kùzu-ready CSV exports
- Emits deterministic chunk node and hierarchy edge files
- Provides JSON plan metadata for downstream Kùzu import scripts

### 9. Graph execution harness (`kuzu_run.nu`)
- Converts node/edge plans into deterministic Kùzu CLI commands
- Supports dry-run metadata inspection and optional execution
- Optional validation checks ensure the target database path exists after import

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
