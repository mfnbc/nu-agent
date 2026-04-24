# Contracts

This document defines what a **contract** is, enumerates the core contracts nu-agent ships with, specifies the system-prompt template for each, and describes how contracts compose.

A contract narrows the aperture of a single nu-agent invocation so that the LLM's behaviour, the data it sees, the tools it can call, and the output it must produce are all specified up front. Every invocation of nu-agent chooses exactly one contract.

## The contract tuple

A contract is a specific tuple of four dimensions:

- **Role** — who the LLM *is*, right now. The role names the persona, the tone, and the expected discipline. Examples: Operator, Consultant-as-Nutritionist, Developer, Ingest-Operator.
- **Corpus** — which records the invocation is allowed to read. Each role is scoped to the corpora relevant to its purpose. A Nutritionist role reads food and workout streams; a Chess-Coach reads a PGN stream and an opening-book reference; they do not cross unless a composed role explicitly permits it.
- **Tool-set** — which Nushell commands the LLM is allowed to call. The default tool-set is a small whitelist (`TOOL_NAMES` in `tools.nu`); individual contracts may extend the whitelist with domain tools from a wing.
- **Output-shape** — what must come back from the LLM. Choices: a JSON array of tool-calls, a single validated record, a `.try` preview file, or prose.

## The popsicle-stick primitive

Every nu-agent invocation has the same atomic shape:

```
(prompt + contract) → LLM → JSON tool-calls → Nushell execution → records
```

One invocation is one query. The primitive is narrow on purpose — the narrowness is what makes invocations composable (see **Composition** below).

## Core contracts

nu-agent ships with a small set of core contracts. Wings may define additional contracts specialised to their domain (e.g. a Chess-Coach Consultant with RAG over a PGN corpus), but those specialisations are always instances of the core contract shapes listed here.

### 1. Operator — JSON tool-calls

- **Role:** Nushell-only controller. The model decides which whitelisted tools to call and in what order to satisfy a task.
- **Corpus:** whatever tools expose. Read/write is mediated by tool permissions, not by giving the LLM direct corpus access.
- **Tool-set:** the `TOOL_NAMES` whitelist, optionally extended per-invocation.
- **Output-shape:** a JSON array of `{ name, arguments }` objects. No prose, no markdown, no code fences.

**System prompt (shape):**

> You are a Nushell expert and Nushell-only controller. Given a task and a tool schema, emit EXACTLY one JSON array of tool calls. Each entry is an object with fields `name` (string, must match a whitelisted tool) and `arguments` (object matching the tool signature). Do not produce prose, logs, explanations, or markdown. Do not emit fenced code blocks. Temperature is 0.

**Failure modes:**

- Output is not a JSON array → rejected; one repair prompt issued.
- A tool name is not whitelisted → rejected; no execution.
- Arguments fail the tool's schema → rejected; one repair prompt issued.

### 2. Enrichment — single-record IO

Enrichment is a specialisation of Operator for the most common case: one structured record in, one validated JSON record out. It is the stable single-record entrypoint exposed as `enrich`.

- **Role:** Nushell-aware record annotator.
- **Corpus:** the single record supplied as input.
- **Tool-set:** usually none — the model produces the output record directly. May optionally call tools for lookup.
- **Output-shape:** a single JSON object that validates against the supplied schema (`allowed` keys, `required` keys, `non_null` keys).

**System prompt (shape):**

> You are a Nushell-aware enrichment model. Receive exactly one JSON record and a task prompt. Produce EXACTLY one JSON object as output, validated against the supplied schema. Do not produce prose or logs outside the JSON. On validation failure, return `{ "error": <string>, "details": <object> }`.

**Failure modes:**

- Output contains keys not in `allowed` → validation fails; one repair attempt; then error on stderr and non-zero exit.
- Required keys missing or null → same retry-then-error path.

**Runtime contract:**

- `stdout` is reserved for the final validated JSON only.
- `stderr` carries diagnostics and is free-form.
- Exit code is non-zero on failure. Callers use Nushell `try/catch`.

### 3. Consultant — prose synthesis

The Consultant reads deterministic output from prior Operator invocations and synthesises prose: interpretation, recommendation, context. **A Consultant never calls tools.**

- **Role:** a domain expert. The specific role is chosen at invocation time: Nutritionist, Ledger-Auditor, Chess-Coach, Lexicographer, and so on. Each domain role lives in the wing it belongs to and supplies its own system prompt.
- **Corpus:** the deterministic output of a prior Operator invocation. The Consultant does not have tool access and cannot consult external corpora except through RAG evidence that the Operator has already retrieved.
- **Tool-set:** empty.
- **Output-shape:** prose.

**System prompt (generic shape):**

> You are a {ROLE}. You will be given structured output from a deterministic Nushell query. Synthesise a human-facing response: interpretation, recommendation, pattern, or context. Do not propose actions the user has not asked for. Do not call tools. Do not fabricate data beyond what is in the structured input. Cite specific record fields when making a claim.

Domain roles define their own system prompt derived from this template. Those prompts live in the wing that owns the domain.

### 4. Developer — propose and apply

The Developer contract is the mechanism by which the mansion grows. It authors new Nushell tools, schemas, Consultant prompts, and orchestration scripts under user direction, always through a preview-and-confirm cycle.

- **Role:** Nushell developer assistant.
- **Corpus:** the code files in the working repository (read) and the tool registry (read).
- **Tool-set:** `propose-edit`, `apply-edit`, `read-file`, `list-files`, `check-nu-syntax`, `self-check`. Optionally `replace-in-file` for direct mutations when explicitly requested.
- **Output-shape:** a JSON object containing a `commands` array of Nushell command strings or a single `script` string. Default behaviour is **preview-only** — commands write to `<path>.try` and must not touch real files unless the caller supplies an explicit confirm flag.

**System prompt (shape):**

> You are a Nushell developer assistant. Respond with EXACTLY one JSON object containing a `commands` array of Nushell command strings or a single `script` string. Default behaviour: produce a preview only. Build the new content in memory and save it to `<path>.try`. Do NOT modify repository files unless the caller supplies `metadata.confirm == true` or an explicit `--apply`/`--confirm` directive. Prefer in-Nushell edits (`open --raw`, `lines`, `enumerate`, `upsert item`, `str replace`, `save -f`) over external patch tools. If a unified diff is more appropriate, return it under `{ "diff": "..." }`.

**Safe edit workflow:**

1. **Propose** — Developer re-reads the target file, constructs the new content, saves to `<path>.try`. No real file is modified.
2. **Inspect** — Human or automated reviewer inspects the `.try` preview.
3. **Apply** — On explicit confirm, Developer emits `save -f` commands that write the real file from the `.try` preview.

### 5. Ingest-Operator — data pipelines

The Ingest-Operator orchestrates long-running, idempotent data-pipeline steps: shredding, embedding, index-add, corpus rebuilds. Its work is meant to be resumable and checkpointed.

- **Role:** Nushell RAG pipeline operator.
- **Corpus:** source materials (Markdown, PGN, FITS, CSV, etc.) and intermediate artefacts (chunks, embeddings, indexes).
- **Tool-set:** ingestion scripts (`scripts/ingest-docs.nu`, `scripts/prep-nu-rag.nu`), `nu_plugin_rag` commands, binaries built from `crates/nu_plugin_rag` (`embed_runner`, `nu-search`, `import_nu_docs`).
- **Output-shape:** a JSON object with a `commands` array or `script`, plus optional `checkpoint` paths for resumability.

**System prompt (shape):**

> You are a Nushell RAG pipeline operator. For ingestion and indexing tasks, emit Nushell commands or scripts that orchestrate shredding, embedding, and index-add. For retrieval, emit a JSON object with a `query` string and optional control parameters (`k`, `source`). Prefer idempotent, resumable commands; write progress checkpoints to `./data/` or `/tmp/` so runs can resume.

## Role specialisation within a contract

A single contract shape (Operator, Consultant, etc.) is specialised by its **role**. A Consultant becomes a Nutritionist by taking the generic Consultant template and binding it to a domain-specific system prompt, corpus scope, and output conventions. Domain specialisations live in the wing that owns the domain — each wing typically ships its own role catalogue (e.g. a ledger wing ships Ledger-Auditor and Budget-Coach; a chess wing ships Chess-Coach and Opening-Analyst).

A wing's contracts are just data — system prompt strings plus corpus and tool references — and nu-agent's core runtime invokes them through the same popsicle-stick primitive it uses for its own core contracts.

## Corpus scope and RAG

Each contract names the corpora its role may read. Corpora fall into two categories:

- **User streams.** Append-only records the user accretes — workouts, transactions, games, journals. Stored per-wing, typically NUON or MessagePack files.
- **Reference corpora.** Ingested bodies of knowledge — Nushell documentation, Hebrew lexicons, opening books, chart-of-accounts templates. Prepared by an Ingest-Operator invocation; queried through `nu_plugin_rag`.

Retrieval is deterministic. The LLM does not "search"; it calls retrieval tools (`search-chunks`, `inspect-chunk`, `resolve-command-doc`, and wing-specific retrievers) which return evidence. **Retrieval tools return evidence, not conclusions.** Synthesis is the Consultant's job, not the retriever's.

## Tool whitelist

The canonical whitelist is `TOOL_NAMES` in `tools.nu`. Unknown tool names are rejected before execution. Wings extend the whitelist when they are loaded, always through Nushell `def` commands or `nu_plugin` crates — never through arbitrary shell invocation.

Hard rules the whitelist enforces:

- No external text-processing tools (`jq`, `grep`, `sed`, `awk`, `patch`) in the core path.
- No bash/sh/python fallbacks in runtime code. HTTP uses Nushell's `http` builtin or a vetted Rust `nu_plugin`.
- Rust is allowed only as `nu_plugin` extensions exposed back as Nushell commands.

## Output validation

Each contract has an enforced output shape:

| Contract        | Output                                                       | Validator                                 |
| --------------- | ------------------------------------------------------------ | ----------------------------------------- |
| Operator        | JSON array of `{name, arguments}`                            | `agent/runtime.nu`, per-tool schema check |
| Enrichment      | Single JSON record matching `{allowed, required, non_null}`  | `agent/enrichment.nu`                     |
| Consultant      | Prose string                                                 | None — output flows to the user           |
| Developer       | `{ "commands": [...] }` or `{ "script": ... }`               | Preview/apply routing; syntax check       |
| Ingest-Operator | `{ "commands": [...] }` or `{ "script": ... }` + checkpoints | Pipeline-specific                         |

Validation failures are handled with one repair prompt, then an error — nu-agent does not retry indefinitely.

## Safety rails

Four rails apply across all contracts:

1. **Whitelist discipline.** Unknown tool names are rejected. The whitelist is the coarse-grained RBAC: if a tool is not in the whitelist, no contract can call it.
2. **Propose-before-apply (Developer).** Repository mutations default to `.try` previews; applying requires an explicit confirm flag.
3. **Audit log.** Tool invocations can be logged as `(timestamp, run id, tool name, argument summary, status)`. Controlled by `AGENT_AUDIT_PATH`. Defaults to stderr; file logging is append-only.
4. **No shell drift.** The Nushell runtime is the only execution surface. Commands that would invoke `bash`, `sh`, `python`, or external shells are rejected. This rule holds even when the temptation is a one-liner fallback.

These rails together constitute an RBAC-adjacent access model: the contract specifies *what* a role may do; the rails enforce it at runtime.

## Composition

Contracts compose **externally**, not within a single invocation. One nu-agent call executes one contract and returns. Higher-level workflows are orchestrator scripts that chain multiple nu-agent calls:

- **A consultation session** — an Operator invocation fetches deterministic facts; a Consultant invocation synthesises over those facts.
- **A batch enrichment** — a Nushell script loops over records, calling nu-agent in Enrichment mode for each.
- **A cross-wing insight** — Operator against a user stream → Operator against a reference corpus → Consultant reasoning over the join.
- **A developer session** — Developer proposes a `.try`; human reviews; a second Developer call applies on confirm.

This is the UNIX pipe model applied to LLM queries. `psql` does not batch; its caller does. `cat` does not orchestrate; its caller does. nu-agent is the same: it executes one popsicle stick per invocation, and composition happens in whatever tool the caller uses to script the sticks together.

## Why strictness is the feature

The rules in this document — JSON-only output, whitelist, propose-before-apply, single-record enrichment, no shell drift, strict output validation — read as a pile of restrictions, but they are the opposite of that. They are what makes each invocation **narrow enough to stack**. UNIX `cat` stacks because it does one thing. If the nu-agent primitive tried to do two things, the skyscraper this ecosystem is trying to build would fall over. Every strict rule here is a narrowness decision that buys compositional power elsewhere.

## See also

- [VISION.md](VISION.md) — the ecosystem this contract model serves.
- [ARCHITECTURE.md](ARCHITECTURE.md) — where each contract is implemented in the code.
- [../RULES.md](../RULES.md) — the shortest-possible list of hard invariants.
- [RAG.md](RAG.md) — the retrieval pipeline Ingest-Operator maintains.
